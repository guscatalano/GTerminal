//! Counters for the status bar.
//!
//! Two layers: a handful of cheap Win32 calls for the built-in items
//! (CPU, memory, disk, battery, uptime), and a generic PDH engine that
//! can read *any* performance counter Windows exposes — that one is what
//! makes the bar extensible without a rebuild. Nothing here is allowed to
//! be expensive: the bar samples on a timer while the user is typing.

use std::collections::HashMap;

#[derive(Default, Clone, serde::Serialize)]
pub struct SystemStats {
    pub cpu_pct: f64,
    pub mem_used: u64,
    pub mem_total: u64,
    pub page_used: u64,
    pub page_total: u64,
    pub disk_read_bps: f64,
    pub disk_write_bps: f64,
    pub disk_free: u64,
    pub disk_total: u64,
    pub battery_pct: Option<u32>,
    pub battery_charging: bool,
    /// Estimated minutes of battery left; None when unknown or on AC.
    pub battery_minutes: Option<u32>,
    pub uptime_s: u64,
}

#[derive(Default, Clone, serde::Serialize)]
pub struct PerfItems {
    pub counters: Vec<String>,
    pub instances: Vec<String>,
}

#[cfg(windows)]
mod imp {
    use super::{PerfItems, SystemStats};
    use std::collections::HashMap;
    use std::sync::{Mutex, OnceLock};
    use windows_sys::Win32::Foundation::FILETIME;
    use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
    use windows_sys::Win32::System::Performance::{
        PdhAddEnglishCounterW, PdhCollectQueryData, PdhEnumObjectItemsW, PdhEnumObjectsW,
        PdhGetFormattedCounterValue, PdhOpenQueryW, PDH_FMT_COUNTERVALUE, PDH_FMT_DOUBLE,
    };
    use windows_sys::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};
    use windows_sys::Win32::System::SystemInformation::{
        GetTickCount64, GlobalMemoryStatusEx, MEMORYSTATUSEX,
    };
    use windows_sys::Win32::System::Threading::GetSystemTimes;

    const PERF_DETAIL_WIZARD: u32 = 400;
    pub const DISK_READ: &str = "\\PhysicalDisk(_Total)\\Disk Read Bytes/sec";
    pub const DISK_WRITE: &str = "\\PhysicalDisk(_Total)\\Disk Write Bytes/sec";

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    /// Split a MULTI_SZ (null-separated, double-null-terminated) buffer.
    fn multi_sz(buf: &[u16]) -> Vec<String> {
        buf.split(|c| *c == 0)
            .filter(|s| !s.is_empty())
            .map(String::from_utf16_lossy)
            .collect()
    }

    fn ft(f: FILETIME) -> u64 {
        ((f.dwHighDateTime as u64) << 32) | f.dwLowDateTime as u64
    }

    /// Previous (idle, kernel, user) tick totals; CPU% is the delta between
    /// samples, so the first call after startup reports 0.
    static CPU_PREV: OnceLock<Mutex<(u64, u64, u64)>> = OnceLock::new();

    fn cpu_pct() -> f64 {
        let zero = FILETIME { dwLowDateTime: 0, dwHighDateTime: 0 };
        let (mut idle, mut kernel, mut user) = (zero, zero, zero);
        if unsafe { GetSystemTimes(&mut idle, &mut kernel, &mut user) } == 0 {
            return 0.0;
        }
        let (i, k, u) = (ft(idle), ft(kernel), ft(user));
        let cell = CPU_PREV.get_or_init(|| Mutex::new((0, 0, 0)));
        let mut prev = match cell.lock() {
            Ok(p) => p,
            Err(e) => e.into_inner(),
        };
        let (pi, pk, pu) = *prev;
        *prev = (i, k, u);
        if pk == 0 && pu == 0 {
            return 0.0; // first sample has nothing to diff against
        }
        // Kernel time already includes idle time, so total is kernel+user.
        let total = k.saturating_sub(pk) + u.saturating_sub(pu);
        let busy = total.saturating_sub(i.saturating_sub(pi));
        if total == 0 {
            0.0
        } else {
            ((busy as f64 / total as f64) * 100.0).clamp(0.0, 100.0)
        }
    }

    /// One PDH query holding every counter anyone has asked for, keyed by
    /// counter path. Rate counters need two collections before they read
    /// back a value, so a freshly added path yields None on its first tick.
    struct Counters {
        query: *mut std::ffi::c_void,
        handles: HashMap<String, *mut std::ffi::c_void>,
    }
    // PDH handles are opaque and owned solely by this mutex.
    unsafe impl Send for Counters {}
    static COUNTERS: OnceLock<Option<Mutex<Counters>>> = OnceLock::new();

    fn counters() -> &'static Option<Mutex<Counters>> {
        COUNTERS.get_or_init(|| unsafe {
            let mut query: *mut std::ffi::c_void = std::ptr::null_mut();
            if PdhOpenQueryW(std::ptr::null(), 0, &mut query) != 0 {
                return None;
            }
            Some(Mutex::new(Counters { query, handles: HashMap::new() }))
        })
    }

    /// Read every requested counter path in one PDH collection. Unknown or
    /// not-yet-primed paths are simply absent from the returned map.
    pub fn read_counters(paths: &[String]) -> HashMap<String, f64> {
        let mut out = HashMap::new();
        let Some(lock) = counters() else { return out };
        let Ok(mut c) = lock.lock() else { return out };
        let mut added = false;
        for p in paths {
            if c.handles.contains_key(p) {
                continue;
            }
            let mut handle: *mut std::ffi::c_void = std::ptr::null_mut();
            let wp = wide(p);
            let rc = unsafe { PdhAddEnglishCounterW(c.query, wp.as_ptr(), 0, &mut handle) };
            if rc == 0 {
                c.handles.insert(p.clone(), handle);
                added = true;
            }
        }
        // Prime newly added rate counters; they need a second collection.
        if added {
            unsafe { PdhCollectQueryData(c.query) };
        }
        if unsafe { PdhCollectQueryData(c.query) } != 0 {
            return out;
        }
        for p in paths {
            let Some(&h) = c.handles.get(p) else { continue };
            let mut val = PDH_FMT_COUNTERVALUE::default();
            let ok = unsafe {
                PdhGetFormattedCounterValue(h, PDH_FMT_DOUBLE, std::ptr::null_mut(), &mut val)
            };
            if ok != 0 {
                continue;
            }
            let d = unsafe { val.Anonymous.doubleValue };
            if d.is_finite() {
                out.insert(p.clone(), d);
            }
        }
        out
    }

    /// Every performance object Windows exposes (the "category" level).
    pub fn perf_objects() -> Result<Vec<String>, String> {
        let mut len: u32 = 0;
        unsafe {
            PdhEnumObjectsW(
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null_mut(),
                &mut len,
                PERF_DETAIL_WIZARD,
                1,
            );
        }
        if len == 0 {
            return Err("no performance objects".into());
        }
        let mut buf = vec![0u16; len as usize];
        let rc = unsafe {
            PdhEnumObjectsW(
                std::ptr::null(),
                std::ptr::null(),
                buf.as_mut_ptr(),
                &mut len,
                PERF_DETAIL_WIZARD,
                0,
            )
        };
        if rc != 0 {
            return Err(format!("PdhEnumObjects failed: 0x{rc:08x}"));
        }
        let mut list = multi_sz(&buf);
        list.sort();
        Ok(list)
    }

    /// The counters and instances available under one performance object.
    pub fn perf_items(object: &str) -> Result<PerfItems, String> {
        let obj = wide(object);
        let (mut clen, mut ilen) = (0u32, 0u32);
        unsafe {
            PdhEnumObjectItemsW(
                std::ptr::null(),
                std::ptr::null(),
                obj.as_ptr(),
                std::ptr::null_mut(),
                &mut clen,
                std::ptr::null_mut(),
                &mut ilen,
                PERF_DETAIL_WIZARD,
                0,
            );
        }
        if clen == 0 {
            return Err(format!("no counters under {object}"));
        }
        let mut cbuf = vec![0u16; clen as usize];
        let mut ibuf = vec![0u16; ilen.max(1) as usize];
        let rc = unsafe {
            PdhEnumObjectItemsW(
                std::ptr::null(),
                std::ptr::null(),
                obj.as_ptr(),
                cbuf.as_mut_ptr(),
                &mut clen,
                ibuf.as_mut_ptr(),
                &mut ilen,
                PERF_DETAIL_WIZARD,
                0,
            )
        };
        if rc != 0 {
            return Err(format!("PdhEnumObjectItems failed: 0x{rc:08x}"));
        }
        let mut counters = multi_sz(&cbuf);
        let mut instances = multi_sz(&ibuf);
        counters.sort();
        instances.sort();
        Ok(PerfItems { counters, instances })
    }

    pub fn sample() -> SystemStats {
        let mut s = SystemStats {
            cpu_pct: cpu_pct(),
            uptime_s: unsafe { GetTickCount64() } / 1000,
            ..Default::default()
        };

        let mut mem: MEMORYSTATUSEX = unsafe { std::mem::zeroed() };
        mem.dwLength = std::mem::size_of::<MEMORYSTATUSEX>() as u32;
        if unsafe { GlobalMemoryStatusEx(&mut mem) } != 0 {
            s.mem_total = mem.ullTotalPhys;
            s.mem_used = mem.ullTotalPhys.saturating_sub(mem.ullAvailPhys);
            s.page_total = mem.ullTotalPageFile;
            s.page_used = mem.ullTotalPageFile.saturating_sub(mem.ullAvailPageFile);
        }

        let root = wide("C:\\");
        let (mut free, mut total) = (0u64, 0u64);
        if unsafe {
            GetDiskFreeSpaceExW(root.as_ptr(), std::ptr::null_mut(), &mut total, &mut free)
        } != 0
        {
            s.disk_free = free;
            s.disk_total = total;
        }

        let io = read_counters(&[DISK_READ.to_string(), DISK_WRITE.to_string()]);
        s.disk_read_bps = io.get(DISK_READ).copied().unwrap_or(0.0);
        s.disk_write_bps = io.get(DISK_WRITE).copied().unwrap_or(0.0);

        let mut power: SYSTEM_POWER_STATUS = unsafe { std::mem::zeroed() };
        if unsafe { GetSystemPowerStatus(&mut power) } != 0 {
            // 255 means "unknown"; bit 7 of BatteryFlag means "no battery".
            if power.BatteryLifePercent != 255 && power.BatteryFlag & 128 == 0 {
                s.battery_pct = Some(power.BatteryLifePercent as u32);
            }
            s.battery_charging = power.ACLineStatus == 1;
            if power.BatteryLifeTime != u32::MAX {
                s.battery_minutes = Some(power.BatteryLifeTime / 60);
            }
        }
        s
    }
}

#[cfg(not(windows))]
mod imp {
    use super::{PerfItems, SystemStats};
    use std::collections::HashMap;
    pub fn sample() -> SystemStats {
        SystemStats::default()
    }
    pub fn read_counters(_: &[String]) -> HashMap<String, f64> {
        HashMap::new()
    }
    pub fn perf_objects() -> Result<Vec<String>, String> {
        Err("performance counters are Windows-only".into())
    }
    pub fn perf_items(_: &str) -> Result<PerfItems, String> {
        Err("performance counters are Windows-only".into())
    }
}

/// Sampled counters behind the built-in status-bar items.
#[tauri::command]
pub fn system_stats() -> SystemStats {
    imp::sample()
}

/// Read arbitrary Windows performance counters by path, all in one
/// collection. A path that was just added reads back on the next call —
/// PDH rate counters need two samples before they produce a value.
#[tauri::command]
pub fn perf_counters(paths: Vec<String>) -> HashMap<String, f64> {
    imp::read_counters(&paths)
}

/// Every performance object on this machine, for the counter picker.
#[tauri::command]
pub fn perf_objects() -> Result<Vec<String>, String> {
    imp::perf_objects()
}

/// Counters and instances under one performance object.
#[tauri::command]
pub fn perf_items(object: String) -> Result<PerfItems, String> {
    imp::perf_items(&object)
}

/// Run a user-configured status-bar command and return its trimmed first
/// line. Custom command items are the other way the bar extends without a
/// rebuild, so this stays deliberately plain: PowerShell, no profile,
/// output capped so a chatty command can't bloat the bar.
#[tauri::command]
pub fn status_command(command: String, cwd: Option<String>) -> Result<String, String> {
    if command.trim().is_empty() {
        return Ok(String::new());
    }
    let mut cmd = std::process::Command::new("powershell");
    cmd.args(["-NoProfile", "-NonInteractive", "-Command", &command]);
    if let Some(dir) = cwd
        .as_deref()
        .filter(|d| !d.is_empty() && std::path::Path::new(d).is_dir())
    {
        cmd.current_dir(dir);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    let out = cmd.output().map_err(|e| e.to_string())?;
    let text = String::from_utf8_lossy(&out.stdout);
    Ok(text
        .lines()
        .next()
        .unwrap_or("")
        .trim()
        .chars()
        .take(120)
        .collect())
}
