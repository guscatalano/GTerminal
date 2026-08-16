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
    pub processes: f64,
    pub threads: f64,
    /// Filled only when the caller asks for the "input" group.
    pub input: Option<InputDelay>,
    /// Filled only when the caller asks for the "gfx" group.
    pub gpu: Option<GpuStats>,
    /// Filled only when the caller asks for the "net" group.
    pub net: Option<NetStats>,
    /// Filled only when the caller asks for the "remote" group.
    pub remote: Option<RemoteStats>,
}

#[derive(Default, Clone, serde::Serialize)]
pub struct GpuStats {
    /// Busiest single engine type — the figure Task Manager's GPU column
    /// tracks. Summing every engine instead would exceed 100% routinely.
    pub busy_pct: f64,
    /// Utilization per engine type (3D, Copy, VideoDecode, ...).
    pub engines: Vec<EngineUse>,
    pub vram_used: u64,
    pub shared_used: u64,
    pub adapters: Vec<AdapterInfo>,
}

/// Windows' own "how long did the desktop take to react" counters — the
/// same ones RDS/VDI deployments watch. Present on Windows 10 1809+.
#[derive(Default, Clone, serde::Serialize)]
pub struct InputDelay {
    /// Worst input delay across sessions, in milliseconds.
    pub session_max_ms: f64,
    /// Worst single process, and its instance name.
    pub process_max_ms: f64,
    pub worst_process: String,
    /// False when the counter object returns no data.
    pub available: bool,
}

#[derive(Default, Clone, serde::Serialize)]
pub struct EngineUse {
    pub kind: String,
    pub pct: f64,
}

#[derive(Default, Clone, serde::Serialize)]
pub struct AdapterInfo {
    pub name: String,
    pub driver: String,
    pub memory: u64,
}

#[derive(Default, Clone, serde::Serialize)]
pub struct NetStats {
    pub rx_bps: f64,
    pub tx_bps: f64,
    /// Interface carrying the most traffic right now.
    pub iface: String,
    pub iface_count: u32,
}

#[derive(Default, Clone, serde::Serialize)]
pub struct RemoteStats {
    /// True when this process is running inside a remote session.
    pub is_remote: bool,
    pub active_sessions: f64,
    pub total_sessions: f64,
    /// RemoteFX transport, when the counters exist.
    pub rtt_ms: f64,
    pub bandwidth_kbps: f64,
    pub loss_pct: f64,
    /// RemoteFX graphics.
    pub fps: f64,
    pub encode_ms: f64,
    pub frames_skipped: f64,
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
    use super::{AdapterInfo, EngineUse, GpuStats, InputDelay, NetStats, RemoteStats};
    use windows_sys::Win32::System::Performance::{
        PdhAddEnglishCounterW, PdhCollectQueryData, PdhEnumObjectItemsW, PdhEnumObjectsW,
        PdhGetFormattedCounterArrayW, PdhGetFormattedCounterValue, PdhOpenQueryW,
        PDH_FMT_COUNTERVALUE, PDH_FMT_COUNTERVALUE_ITEM_W, PDH_FMT_DOUBLE,
    };
    use windows_sys::Win32::System::Registry::{
        RegGetValueW, HKEY_LOCAL_MACHINE, RRF_RT_REG_QWORD, RRF_RT_REG_SZ,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::{GetSystemMetrics, SM_REMOTESESSION};
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

    /// Read a wildcard counter path, returning every instance and value.
    /// PDH needs the same two-collection priming as a single counter, so
    /// the first call for a path comes back empty.
    pub fn counter_array(path: &str) -> Vec<(String, f64)> {
        let mut out = Vec::new();
        let Some(lock) = counters() else { return out };
        let Ok(mut c) = lock.lock() else { return out };
        let handle = match c.handles.get(path) {
            Some(&h) => h,
            None => {
                let mut h: *mut std::ffi::c_void = std::ptr::null_mut();
                let wp = wide(path);
                if unsafe { PdhAddEnglishCounterW(c.query, wp.as_ptr(), 0, &mut h) } != 0 {
                    return out;
                }
                c.handles.insert(path.to_string(), h);
                unsafe { PdhCollectQueryData(c.query) };
                h
            }
        };
        if unsafe { PdhCollectQueryData(c.query) } != 0 {
            return out;
        }
        let mut size: u32 = 0;
        let mut count: u32 = 0;
        unsafe {
            PdhGetFormattedCounterArrayW(
                handle,
                PDH_FMT_DOUBLE,
                &mut size,
                &mut count,
                std::ptr::null_mut(),
            );
        }
        if size == 0 || count == 0 {
            return out;
        }
        // Allocate as items so the buffer is correctly aligned for them.
        let item = std::mem::size_of::<PDH_FMT_COUNTERVALUE_ITEM_W>();
        let mut buf: Vec<PDH_FMT_COUNTERVALUE_ITEM_W> =
            Vec::with_capacity(size as usize / item + 2);
        let rc = unsafe {
            PdhGetFormattedCounterArrayW(
                handle,
                PDH_FMT_DOUBLE,
                &mut size,
                &mut count,
                buf.as_mut_ptr(),
            )
        };
        if rc != 0 {
            return out;
        }
        unsafe { buf.set_len(count as usize) };
        for it in buf.iter() {
            let name = if it.szName.is_null() {
                String::new()
            } else {
                let mut len = 0usize;
                while unsafe { *it.szName.add(len) } != 0 {
                    len += 1;
                }
                String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(it.szName, len) })
            };
            let v = unsafe { it.FmtValue.Anonymous.doubleValue };
            if v.is_finite() {
                out.push((name, v));
            }
        }
        out
    }

    fn reg_str(path: &str, value: &str) -> Option<String> {
        let mut buf = [0u16; 512];
        let mut size = (buf.len() * 2) as u32;
        let rc = unsafe {
            RegGetValueW(
                HKEY_LOCAL_MACHINE,
                wide(path).as_ptr(),
                wide(value).as_ptr(),
                RRF_RT_REG_SZ,
                std::ptr::null_mut(),
                buf.as_mut_ptr() as *mut _,
                &mut size,
            )
        };
        if rc != 0 {
            return None;
        }
        let len = buf.iter().position(|c| *c == 0).unwrap_or(0);
        if len == 0 {
            None
        } else {
            Some(String::from_utf16_lossy(&buf[..len]))
        }
    }

    fn reg_qword(path: &str, value: &str) -> Option<u64> {
        let mut out: u64 = 0;
        let mut size = std::mem::size_of::<u64>() as u32;
        let rc = unsafe {
            RegGetValueW(
                HKEY_LOCAL_MACHINE,
                wide(path).as_ptr(),
                wide(value).as_ptr(),
                RRF_RT_REG_QWORD,
                std::ptr::null_mut(),
                &mut out as *mut u64 as *mut _,
                &mut size,
            )
        };
        if rc == 0 {
            Some(out)
        } else {
            None
        }
    }

    /// Display adapters straight out of the driver class key — no WMI and
    /// no COM, just what the display class stores per adapter.
    fn adapters() -> Vec<AdapterInfo> {
        const CLASS: &str =
            "SYSTEM\\CurrentControlSet\\Control\\Class\\{4d36e968-e325-11ce-bfc1-08002be10318}";
        let mut out = Vec::new();
        for i in 0..8u32 {
            let sub = format!("{CLASS}\\{i:04}");
            let Some(name) = reg_str(&sub, "DriverDesc") else { continue };
            out.push(AdapterInfo {
                name,
                driver: reg_str(&sub, "DriverVersion").unwrap_or_default(),
                memory: reg_qword(&sub, "HardwareInformation.qwMemorySize").unwrap_or(0),
            });
        }
        out
    }

    /// Engine instances are named
    /// `pid_1234_luid_0x…_phys_0_eng_0_engtype_3D`; the tail is the type.
    fn engine_kind(instance: &str) -> String {
        instance
            .rsplit_once("engtype_")
            .map(|(_, k)| k.to_string())
            .unwrap_or_else(|| "Other".into())
    }

    pub fn gpu() -> GpuStats {
        let mut by_kind: std::collections::BTreeMap<String, f64> = Default::default();
        for (inst, v) in counter_array("\\GPU Engine(*)\\Utilization Percentage") {
            *by_kind.entry(engine_kind(&inst)).or_insert(0.0) += v;
        }
        let mut engines: Vec<EngineUse> = by_kind
            .into_iter()
            .map(|(kind, pct)| EngineUse { kind, pct: pct.min(100.0) })
            .collect();
        engines.sort_by(|a, b| b.pct.partial_cmp(&a.pct).unwrap_or(std::cmp::Ordering::Equal));
        let busy_pct = engines.first().map(|e| e.pct).unwrap_or(0.0);
        let sum = |p: &str| -> f64 { counter_array(p).iter().map(|(_, v)| *v).sum() };
        GpuStats {
            busy_pct,
            engines,
            vram_used: sum("\\GPU Adapter Memory(*)\\Dedicated Usage") as u64,
            shared_used: sum("\\GPU Adapter Memory(*)\\Shared Usage") as u64,
            adapters: adapters(),
        }
    }

    /// Interfaces that only carry tunnelled or loopback traffic would
    /// otherwise drown out the real adapter in the totals.
    fn real_iface(name: &str) -> bool {
        let n = name.to_ascii_lowercase();
        !(n.contains("loopback")
            || n.contains("isatap")
            || n.contains("teredo")
            || n.contains("pseudo"))
    }

    /// Last adapter that actually carried traffic. On an idle tick nothing
    /// "wins", and recomputing from scratch would blank the name out and
    /// then bring it back — so the last known one is kept instead.
    static LAST_IFACE: OnceLock<Mutex<String>> = OnceLock::new();

    pub fn net() -> NetStats {
        let rx = counter_array("\\Network Interface(*)\\Bytes Received/sec");
        let tx = counter_array("\\Network Interface(*)\\Bytes Sent/sec");
        let mut s = NetStats::default();
        let mut best = 0.0f64;
        for (name, v) in rx.iter().filter(|(n, _)| real_iface(n)) {
            s.rx_bps += v;
            s.iface_count += 1;
            let sent = tx.iter().find(|(n, _)| n == name).map(|(_, v)| *v).unwrap_or(0.0);
            if v + sent > best {
                best = v + sent;
                s.iface = name.clone();
            }
        }
        s.tx_bps = tx.iter().filter(|(n, _)| real_iface(n)).map(|(_, v)| *v).sum();

        let cell = LAST_IFACE.get_or_init(|| Mutex::new(String::new()));
        if let Ok(mut last) = cell.lock() {
            if s.iface.is_empty() {
                // Idle: reuse the last busy adapter, or name any real one
                // so the field is never blank once interfaces are known.
                s.iface = if last.is_empty() {
                    rx.iter()
                        .map(|(n, _)| n)
                        .find(|n| real_iface(n))
                        .cloned()
                        .unwrap_or_default()
                } else {
                    last.clone()
                };
            }
            if !s.iface.is_empty() {
                *last = s.iface.clone();
            }
        }
        s
    }

    pub fn input_delay() -> InputDelay {
        let sessions = counter_array("\\User Input Delay per Session(*)\\Max Input Delay");
        let procs = counter_array("\\User Input Delay per Process(*)\\Max Input Delay");
        let worst = procs
            .iter()
            .max_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));
        InputDelay {
            session_max_ms: sessions.iter().map(|(_, v)| *v).fold(0.0, f64::max),
            process_max_ms: worst.map(|(_, v)| *v).unwrap_or(0.0),
            // Instances read like "1234:notepad"; the tail is the friendlier half.
            worst_process: worst
                .map(|(n, _)| n.rsplit_once(':').map(|(_, p)| p.to_string()).unwrap_or_else(|| n.clone()))
                .unwrap_or_default(),
            available: !sessions.is_empty() || !procs.is_empty(),
        }
    }

    pub fn remote() -> RemoteStats {
        let mut r = RemoteStats {
            is_remote: unsafe { GetSystemMetrics(SM_REMOTESESSION) } != 0,
            ..Default::default()
        };
        let ts = read_counters(&[
            "\\Terminal Services\\Active Sessions".to_string(),
            "\\Terminal Services\\Total Sessions".to_string(),
        ]);
        r.active_sessions = ts.get("\\Terminal Services\\Active Sessions").copied().unwrap_or(0.0);
        r.total_sessions = ts.get("\\Terminal Services\\Total Sessions").copied().unwrap_or(0.0);
        // RemoteFX counters exist only inside an RDP session; a missing
        // path just yields nothing rather than failing the whole sample.
        let first = |path: &str| counter_array(path).first().map(|(_, v)| *v).unwrap_or(0.0);
        r.rtt_ms = first("\\RemoteFX Network(*)\\Current TCP RTT") / 1000.0;
        r.bandwidth_kbps = first("\\RemoteFX Network(*)\\Current TCP Bandwidth");
        r.loss_pct = first("\\RemoteFX Network(*)\\Current UDP Packet Loss Rate");
        r.fps = first("\\RemoteFX Graphics(*)\\Output Frames/Second");
        r.encode_ms = first("\\RemoteFX Graphics(*)\\Average Encoding Time");
        r.frames_skipped =
            first("\\RemoteFX Graphics(*)\\Frames Skipped/Second - Insufficient Client Resources");
        r
    }

    pub fn sample(groups: &[String]) -> SystemStats {
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

        // All the scalar counters ride along in one collection.
        let base = read_counters(&[
            DISK_READ.to_string(),
            DISK_WRITE.to_string(),
            "\\System\\Processes".to_string(),
            "\\System\\Threads".to_string(),
        ]);
        s.disk_read_bps = base.get(DISK_READ).copied().unwrap_or(0.0);
        s.disk_write_bps = base.get(DISK_WRITE).copied().unwrap_or(0.0);
        s.processes = base.get("\\System\\Processes").copied().unwrap_or(0.0);
        s.threads = base.get("\\System\\Threads").copied().unwrap_or(0.0);

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

        // Wildcard groups cost noticeably more than the scalar counters
        // above, so they are sampled only when an item actually wants them.
        let want = |g: &str| groups.iter().any(|x| x == g);
        if want("gfx") {
            s.gpu = Some(gpu());
        }
        if want("net") {
            s.net = Some(net());
        }
        if want("remote") {
            s.remote = Some(remote());
        }
        if want("input") {
            s.input = Some(input_delay());
        }
        s
    }
}

#[cfg(not(windows))]
mod imp {
    use super::{PerfItems, SystemStats};
    use std::collections::HashMap;
    pub fn sample(_: &[String]) -> SystemStats {
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

/// Sampled counters behind the built-in status-bar items. `groups` opts
/// into the costlier wildcard families: "gfx", "net", "remote".
#[tauri::command]
pub fn system_stats(groups: Option<Vec<String>>) -> SystemStats {
    imp::sample(&groups.unwrap_or_default())
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
