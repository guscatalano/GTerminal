mod mux;
mod stats;

use mux::Request;
use serde_json::Value;
use std::collections::HashMap;
use std::io::BufRead;
use std::io::BufReader;
use std::net::TcpStream;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager, State};

#[derive(Clone, serde::Serialize)]
struct PtyOutput {
    id: u32,
    data: String,
}

#[derive(Clone, serde::Serialize)]
struct PtyExit {
    id: u32,
}

/// Write halves of the attach connections for sessions shown in this window.
#[derive(Clone, Default)]
struct PtyManager {
    attached: Arc<Mutex<HashMap<u32, TcpStream>>>,
    /// Which window each session is open in.
    ///
    /// The attach connections belong to the process, not to a window, so
    /// closing a window used to leave its sessions attached for as long
    /// as the app ran: the daemon believed they were in use, and no other
    /// window would adopt one, because adopting a session someone else
    /// has open is exactly what must not happen. They were stranded.
    owners: Arc<Mutex<HashMap<u32, String>>>,
}

fn attach_internal(app: &AppHandle, state: &PtyManager, id: u32, owner: Option<&str>) -> Result<(), String> {
    if let Some(owner) = owner {
        state.owners.lock().unwrap().insert(id, owner.to_string());
    }
    let mut stream = mux::client::ensure()?;
    mux::write_line(&mut stream, &serde_json::to_value(Request::Attach { id }).unwrap())
        .map_err(|e| e.to_string())?;
    let mut reader = BufReader::new(stream.try_clone().map_err(|e| e.to_string())?);
    let mut line = String::new();
    reader.read_line(&mut line).map_err(|e| e.to_string())?;
    let v: Value = serde_json::from_str(line.trim()).map_err(|e| e.to_string())?;
    if v.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err(v
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("attach failed")
            .to_string());
    }
    state.attached.lock().unwrap().insert(id, stream);

    let app = app.clone();
    let attached = state.attached.clone();
    std::thread::spawn(move || {
        let mut line = String::new();
        loop {
            line.clear();
            match reader.read_line(&mut line) {
                Ok(0) | Err(_) => break,
                Ok(_) => {
                    let Ok(v) = serde_json::from_str::<Value>(line.trim()) else {
                        continue;
                    };
                    match v.get("ev").and_then(Value::as_str) {
                        Some("data") => {
                            let data = v
                                .get("data")
                                .and_then(Value::as_str)
                                .unwrap_or_default()
                                .to_string();
                            let _ = app.emit("pty-output", PtyOutput { id, data });
                        }
                        Some("exit") => {
                            attached.lock().unwrap().remove(&id);
                            let _ = app.emit("pty-exit", PtyExit { id });
                            return;
                        }
                        // Another window took this session. It is alive
                        // and well somewhere else, so this is not an
                        // exit: the tab goes, the session does not.
                        Some("taken") => {
                            attached.lock().unwrap().remove(&id);
                            let _ = app.emit("pty-taken", PtyExit { id });
                            return;
                        }
                        _ => {}
                    }
                }
            }
        }
        // Connection dropped without an exit event (daemon died, or we
        // detached — in which case the map entry is already gone).
        if attached.lock().unwrap().remove(&id).is_some() {
            let _ = app.emit("pty-exit", PtyExit { id });
        }
    });
    Ok(())
}

fn send_to(state: &PtyManager, id: u32, req: Request) -> Result<(), String> {
    let mut map = state.attached.lock().unwrap();
    let stream = map.get_mut(&id).ok_or("no such session")?;
    mux::write_line(stream, &serde_json::to_value(req).unwrap()).map_err(|e| e.to_string())
}

#[tauri::command]
fn list_sessions() -> Result<Vec<mux::SessionInfo>, String> {
    // Without a daemon there are no sessions to list — unless checkpointed
    // sessions exist on disk (e.g. after a reboot), in which case a daemon
    // must be started to offer them for resurrection.
    let stream = match mux::client::connect() {
        Ok(s) => s,
        Err(_) if mux::client::has_persisted_sessions() => mux::client::ensure()?,
        Err(_) => return Ok(vec![]),
    };
    let v = mux::client::request(stream, &Request::List)?;
    serde_json::from_value(v.get("sessions").cloned().unwrap_or_default())
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn create_session(
    app: AppHandle,
    window: tauri::Window,
    state: State<PtyManager>,
    cols: u16,
    rows: u16,
    shell: Option<String>,
    cwd: Option<String>,
) -> Result<u32, String> {
    let v = mux::client::control(&Request::Create { cols, rows, shell, cwd })?;
    let id = v.get("id").and_then(Value::as_u64).ok_or("bad response")? as u32;
    attach_internal(&app, &state, id, Some(window.label()))?;
    Ok(id)
}

#[tauri::command]
fn attach_session(
    app: AppHandle,
    window: tauri::Window,
    state: State<PtyManager>,
    id: u32,
    cols: u16,
    rows: u16,
) -> Result<(), String> {
    attach_internal(&app, &state, id, Some(window.label()))?;
    send_to(&state, id, Request::Resize { cols, rows })
}

/// Where the logs live, so the window can offer to open the folder.
#[tauri::command]
fn logs_path() -> String {
    mux::state_dir_path().to_string_lossy().into_owned()
}

/// Append one line to the UI event log.
///
/// The transcripts record what the *shell* printed. Nothing recorded what
/// the window did — which menu opened, what was chosen, where a paste
/// came from — so a report like "hovering Paste pastes" could not be
/// checked against anything: the shell sees identical text whether it was
/// clicked, hovered, or typed. This is that missing half.
///
/// Never the clipboard's contents: a log people are asked to send should
/// not carry what they copied. Sizes and counts only.
#[tauri::command]
fn log_ui(line: String) -> Result<(), String> {
    use std::io::Write;
    let dir = mux::state_dir_path();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let path = dir.join("ui.log");
    // Bounded, and trimmed to its newest half rather than deleted, so a
    // long session cannot grow it without limit and a trim cannot throw
    // away the entry someone is looking for.
    if std::fs::metadata(&path).is_ok_and(|m| m.len() > UI_LOG_MAX) {
        if let Ok(bytes) = std::fs::read(&path) {
            let tail = &bytes[bytes.len() - (UI_LOG_MAX as usize) / 2..];
            let start = tail.iter().position(|&b| b == b'\n').map(|p| p + 1).unwrap_or(0);
            let _ = std::fs::write(&path, &tail[start..]);
        }
    }
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .map_err(|e| e.to_string())?;
    writeln!(f, "{line}").map_err(|e| e.to_string())
}

const UI_LOG_MAX: u64 = 2 * 1024 * 1024;

/// Who the daemon is: protocol, version, pid. Empty fields mean a daemon
/// old enough not to report them, which is itself the answer.
#[tauri::command]
fn daemon_info() -> Result<Value, String> {
    let stream = match mux::client::connect() {
        Ok(s) => s,
        Err(_) => return Ok(serde_json::json!({})),
    };
    let v = mux::client::request(stream, &Request::List)?;
    Ok(serde_json::json!({
        "protocol": v.get("protocol"),
        "version": v.get("version"),
        "pid": v.get("pid"),
        // What the *window* needs, so the comparison is not duplicated in
        // two languages that can drift apart.
        "required": mux::PROTOCOL,
    }))
}

/// Stop the running daemon so the next request starts a fresh one.
///
/// Killing rather than asking: the daemon this exists for is by
/// definition too old to know a shutdown request. Its sessions are
/// checkpointed as it goes — they come back as ended sessions with their
/// scrollback — but the shells themselves end, which is why this is only
/// ever reached by someone pressing a button that says so.
#[tauri::command]
fn restart_daemon() -> Result<(), String> {
    let pid = match mux::client::connect() {
        Ok(stream) => mux::client::request(stream, &Request::List)
            .ok()
            .and_then(|v| v.get("pid").and_then(Value::as_u64)),
        Err(_) => None,
    };
    let Some(pid) = pid else {
        // Nothing running, or too old to say which process it is. Either
        // way the next request will start one.
        mux::client::ensure()?;
        return Ok(());
    };
    {
        use std::os::windows::process::CommandExt;
        let _ = std::process::Command::new("taskkill")
            .args(["/PID", &pid.to_string(), "/F"])
            .creation_flags(0x0800_0000) // CREATE_NO_WINDOW
            .output();
    }
    // Wait for it to actually go before starting another, or the new one
    // finds the port still held and gives up.
    for _ in 0..40 {
        std::thread::sleep(std::time::Duration::from_millis(100));
        if mux::client::connect().is_err() {
            break;
        }
    }
    mux::client::ensure()?;
    Ok(())
}

/// A session's saved output, without starting anything.
///
/// Deliberately not an attach: attaching to a session whose shell has
/// ended spawns a replacement, so a window that attached in order to show
/// you the history would be starting processes on your behalf every time
/// you glanced at one.
#[tauri::command]
fn peek_session(id: u32) -> Result<String, String> {
    let stream = match mux::client::connect() {
        Ok(s) => s,
        Err(_) => mux::client::ensure()?,
    };
    let v = mux::client::request(stream, &Request::Peek { id })?;
    Ok(v.get("data").and_then(Value::as_str).unwrap_or("").to_string())
}

#[tauri::command]
fn write_session(state: State<PtyManager>, id: u32, data: String) -> Result<(), String> {
    send_to(&state, id, Request::Write { data })
}

#[tauri::command]
fn resize_session(state: State<PtyManager>, id: u32, cols: u16, rows: u16) -> Result<(), String> {
    send_to(&state, id, Request::Resize { cols, rows })
}

#[tauri::command]
fn detach_session(state: State<PtyManager>, id: u32) -> Result<(), String> {
    state.owners.lock().unwrap().remove(&id);
    let stream = state.attached.lock().unwrap().remove(&id);
    if let Some(mut stream) = stream {
        let _ = mux::write_line(&mut stream, &serde_json::to_value(Request::Detach).unwrap());
    }
    Ok(())
}

#[tauri::command]
fn kill_session(id: u32) -> Result<(), String> {
    mux::client::control(&Request::Kill { id })?;
    Ok(())
}

#[tauri::command]
fn get_config() -> serde_json::Value {
    mux::read_config()
}

#[tauri::command]
fn set_config(value: serde_json::Value) -> Result<(), String> {
    mux::write_config(&value)
}

/// A history transcript row for the History page. `stem` names the
/// transcript file pair; `bytes` is the transcript's size on disk.
#[derive(serde::Serialize)]
struct HistoryEntry {
    stem: String,
    id: u32,
    created_ms: u64,
    ended_ms: Option<u64>,
    cwd: String,
    shell: String,
    bytes: u64,
}

#[tauri::command]
fn history_list() -> Result<Vec<HistoryEntry>, String> {
    let dir = mux::history_dir();
    let mut out = Vec::new();
    if let Ok(rd) = std::fs::read_dir(&dir) {
        for e in rd.flatten() {
            let p = e.path();
            if p.extension().and_then(|s| s.to_str()) != Some("json") {
                continue;
            }
            let Some(meta) = std::fs::read_to_string(&p)
                .ok()
                .and_then(|t| serde_json::from_str::<mux::HistoryMeta>(&t).ok())
            else {
                continue;
            };
            let stem = p
                .file_stem()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default();
            let bytes = std::fs::metadata(dir.join(format!("{stem}.log")))
                .map(|m| m.len())
                .unwrap_or(0);
            out.push(HistoryEntry {
                stem,
                id: meta.id,
                created_ms: meta.created_ms,
                ended_ms: meta.ended_ms,
                cwd: meta.cwd,
                shell: meta.shell,
                bytes,
            });
        }
    }
    out.sort_by(|a, b| b.created_ms.cmp(&a.created_ms));
    Ok(out)
}

#[tauri::command]
fn history_read(stem: String) -> Result<String, String> {
    // Stems are "{created_ms}-{id}" — digits and dashes only, so the
    // path below can't escape the history directory.
    if stem.is_empty() || !stem.chars().all(|c| c.is_ascii_digit() || c == '-') {
        return Err("bad stem".into());
    }
    let bytes = std::fs::read(mux::history_dir().join(format!("{stem}.log")))
        .map_err(|e| e.to_string())?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

#[derive(serde::Serialize)]
struct LaunchInfo {
    args: Vec<String>,
    exe: String,
}

/// CLI args + exe path, so the frontend can honor launch flags like
/// `--workspace <name>` and build shortcut command lines.
#[tauri::command]
fn launch_info() -> LaunchInfo {
    LaunchInfo {
        args: std::env::args().skip(1).collect(),
        exe: std::env::current_exe()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_default(),
    }
}

/// Write a Windows .lnk at `path` that launches this exe with
/// `--workspace "<workspace>"`. Uses the WScript.Shell COM object via
/// PowerShell — no extra crate, and it produces a real shell link.
#[tauri::command]
fn create_shortcut(path: String, workspace: String) -> Result<(), String> {
    let exe = std::env::current_exe()
        .map_err(|e| e.to_string())?
        .to_string_lossy()
        .into_owned();
    // Values land inside PowerShell single-quoted strings, where the only
    // metacharacter is the single quote itself (escaped by doubling).
    let esc = |s: &str| s.replace('\'', "''");
    let script = format!(
        "$ws = New-Object -ComObject WScript.Shell; \
         $s = $ws.CreateShortcut('{}'); \
         $s.TargetPath = '{}'; \
         $s.Arguments = '--workspace \"{}\"'; \
         $s.IconLocation = '{},0'; \
         $s.Save()",
        esc(&path),
        esc(&exe),
        esc(&workspace).replace('"', ""),
        esc(&exe)
    );
    let out = {
        use std::os::windows::process::CommandExt;
        std::process::Command::new("powershell")
            .args(["-NoProfile", "-NonInteractive", "-Command", &script])
            .creation_flags(0x0800_0000) // CREATE_NO_WINDOW
            .output()
            .map_err(|e| e.to_string())?
    };
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).into_owned());
    }
    Ok(())
}

/// The window fades, rather than moving or being animated in the page.
///
/// It used to slide: ten `set_position` calls with the UI thread asleep
/// between them, each forcing WebView2 to re-composite the whole window.
/// You saw ten discrete positions rather than motion — the jankiest thing
/// in the app. Animating the *content* instead is smooth but wrong: the
/// window stays put and opaque, so the terminal dissolves and leaves a
/// dark rectangle sitting there until the window finally goes.
///
/// Layered-window alpha fades the window itself, chrome and all, and DWM
/// does the compositing — no repaint per step, and nothing for the page
/// to be involved in. The layered style is set once on first use and left
/// alone; alpha 255 is indistinguishable from a plain window.
const FADE_MS: u64 = 140;
const FADE_STEPS: u32 = 16;

/// Alpha at step `i`, eased so most of the change happens early — quick
/// rather than slow, at the same duration.
fn fade_alpha(i: u32, steps: u32, appearing: bool) -> u8 {
    let t = (i as f64 / steps as f64).clamp(0.0, 1.0);
    let eased = 1.0 - (1.0 - t) * (1.0 - t);
    let level = if appearing { eased } else { 1.0 - eased };
    (level * 255.0).round() as u8
}

#[cfg(windows)]
fn set_window_alpha(win: &tauri::WebviewWindow, alpha: u8) {
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        GetWindowLongPtrW, SetLayeredWindowAttributes, SetWindowLongPtrW, GWL_EXSTYLE, LWA_ALPHA,
        WS_EX_LAYERED,
    };
    let Ok(hwnd) = win.hwnd() else { return };
    let h = hwnd.0 as *mut core::ffi::c_void;
    unsafe {
        let ex = GetWindowLongPtrW(h, GWL_EXSTYLE);
        if ex & (WS_EX_LAYERED as isize) == 0 {
            SetWindowLongPtrW(h, GWL_EXSTYLE, ex | WS_EX_LAYERED as isize);
        }
        SetLayeredWindowAttributes(h, 0, alpha, LWA_ALPHA);
    }
}

/// Stop the window being layered.
///
/// WS_EX_LAYERED is how the fade works, and it is not free: a layered
/// window is composited down a different path, which for a WebView2
/// window showing a terminal means redraws that were free are no longer
/// free. Left set — which is what happened, since the style was applied
/// on the first fade and never removed — every keystroke after the first
/// summon pays for an animation that finished long ago.
///
/// So it goes back off the moment the fade is done. The window spends
/// microseconds layered per hide, instead of the rest of its life.
#[cfg(windows)]
fn clear_window_layer(win: &tauri::WebviewWindow) {
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        GetWindowLongPtrW, SetWindowLongPtrW, SetWindowPos, GWL_EXSTYLE, SWP_FRAMECHANGED,
        SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SWP_NOZORDER, WS_EX_LAYERED,
    };
    let Ok(hwnd) = win.hwnd() else { return };
    let h = hwnd.0 as *mut core::ffi::c_void;
    unsafe {
        let ex = GetWindowLongPtrW(h, GWL_EXSTYLE);
        if ex & (WS_EX_LAYERED as isize) == 0 {
            return;
        }
        SetWindowLongPtrW(h, GWL_EXSTYLE, ex & !(WS_EX_LAYERED as isize));
        // The style change needs a frame change to be picked up.
        SetWindowPos(
            h,
            std::ptr::null_mut(),
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED,
        );
    }
}

#[cfg(windows)]
fn fade(win: &tauri::WebviewWindow, appearing: bool) {
    for i in 0..=FADE_STEPS {
        set_window_alpha(win, fade_alpha(i, FADE_STEPS, appearing));
        std::thread::sleep(std::time::Duration::from_millis(
            FADE_MS / (FADE_STEPS as u64 + 1),
        ));
    }
}

/// Bumped every time the window is summoned. A fade-out that finds it
/// changed knows someone asked for the window back mid-fade and leaves it
/// alone — otherwise a quick press-press-press would hide a window that
/// had just been summoned, a hundred milliseconds after it appeared.
static SUMMON_GEN: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Fade out, then hide. Off the UI thread: sleeping on it would freeze
/// the window for exactly the span the fade needs to be drawn in.
fn leave(win: &tauri::WebviewWindow, app: &AppHandle) {
    use std::sync::atomic::Ordering;
    let win = win.clone();
    let handle = app.clone();
    let gen = SUMMON_GEN.load(Ordering::SeqCst);
    std::thread::spawn(move || {
        #[cfg(windows)]
        fade(&win, false);
        if SUMMON_GEN.load(Ordering::SeqCst) != gen {
            // Summoned while it was on its way out. Undo the fade rather
            // than the summon.
            #[cfg(windows)]
            {
                set_window_alpha(&win, 255);
                clear_window_layer(&win);
            }
            return;
        }
        let _ = win.hide();
        // Opaque again while hidden. Whatever shows it next — the tray,
        // a second instance, the hotkey with the animation since turned
        // off — must never get a window that is still transparent.
        #[cfg(windows)]
        {
            set_window_alpha(&win, 255);
            clear_window_layer(&win);
        }
        let _ = apply_tray_text(&handle);
    });
}

fn animate() -> bool {
    mux::read_config()
        .get("summon_animation")
        .and_then(|v| v.as_str())
        .unwrap_or("slide")
        != "none"
}

/// Bring the window back from wherever it went — hidden, minimized, or
/// merely buried. Focus, not visibility, is what decides: a window you
/// can see but cannot type into still needs raising.
fn summon(app: &AppHandle) {
    SUMMON_GEN.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    if let Some(win) = focused_window(app) {
        if win.is_minimized().unwrap_or(false) {
            let _ = win.unminimize();
        }
        let hidden = !win.is_visible().unwrap_or(true);
        let fading = hidden && animate();
        // Transparent *before* the show, so the window never appears at
        // full strength for a frame and then restarts the fade — which is
        // what made the old arrival read as a jerk rather than a fade.
        //
        // The window is still never moved: sliding it on the way in races
        // the show that was just requested and it can fail to appear at
        // all, measured at zero successes in six attempts. Alpha does not
        // touch position or size, so it has nothing to race.
        #[cfg(windows)]
        if fading {
            set_window_alpha(&win, 0);
        }
        let _ = win.show();
        let _ = win.set_focus();
        #[cfg(windows)]
        if fading {
            let w = win.clone();
            std::thread::spawn(move || {
                fade(&w, true);
                // Land exactly on opaque, whatever the arithmetic did,
                // and then stop paying for the layer.
                set_window_alpha(&w, 255);
                clear_window_layer(&w);
            });
        }
    }
}

/// The window the summon hotkey and the tray mean.
///
/// With more than one window open, "the window" stops being a fact and
/// becomes a choice. The last one focused is the answer that needs no
/// explaining - it is the one you were just using - and it degrades
/// correctly: with a single window it is always that window.
static LAST_FOCUSED: Mutex<Option<String>> = Mutex::new(None);

fn focused_window(app: &AppHandle) -> Option<tauri::WebviewWindow> {
    let label = LAST_FOCUSED.lock().unwrap().clone();
    label
        .and_then(|l| app.get_webview_window(&l))
        .or_else(|| app.get_webview_window("main"))
        .or_else(|| app.webview_windows().into_values().next())
}

/// The labels already in use, so the frontend can pick a free one.
#[tauri::command]
fn window_labels(app: AppHandle) -> Vec<String> {
    app.webview_windows().keys().cloned().collect()
}

/// Everything that must happen to a window, whichever window it is.
///
/// Attached by the builder rather than per window, because windows are
/// created by the page now and a per-window hook only ever covered the
/// first one - which is how a closed window went on owning its sessions.
fn on_any_window_event(win: &tauri::Window, event: &tauri::WindowEvent) {
    let handle = win.app_handle().clone();
    let label = win.label().to_string();
    match event {
        tauri::WindowEvent::Focused(true) => {
            *LAST_FOCUSED.lock().unwrap() = Some(label);
        }
        // A window that has gone cannot own a session. Released here
        // rather than from the page, because a window can also be
        // destroyed without its JavaScript getting a say.
        tauri::WindowEvent::Destroyed => {
            if let Some(state) = handle.try_state::<PtyManager>() {
                let mine: Vec<u32> = state
                    .owners
                    .lock()
                    .unwrap()
                    .iter()
                    .filter(|(_, owner)| *owner == &label)
                    .map(|(id, _)| *id)
                    .collect();
                for id in mine {
                    state.owners.lock().unwrap().remove(&id);
                    let stream = state.attached.lock().unwrap().remove(&id);
                    if let Some(mut stream) = stream {
                        let _ = mux::write_line(
                            &mut stream,
                            &serde_json::to_value(Request::Detach).unwrap(),
                        );
                    }
                }
            }
        }
        // Closing the last window hides it to the tray, which is what
        // keeps the summon hotkey worth having. Closing any other simply
        // closes it.
        tauri::WindowEvent::CloseRequested { api, .. } => {
            let last = handle.webview_windows().len() <= 1;
            if last && close_hides() {
                api.prevent_close();
                if let Some(w) = handle.get_webview_window(&win.label().to_string()) {
                    if animate() {
                        leave(&w, &handle);
                    } else {
                        let _ = w.hide();
                        let _ = apply_tray_text(&handle);
                    }
                }
            }
        }
        _ => {}
    }
}

/// Is this window the one the user is looking at?
///
/// Asked of the OS rather than of Tauri's `is_focused`, which answers for
/// the *window* while the keyboard focus sits in the WebView2 child. A
/// window plainly in front then reports itself unfocused, and the summon
/// hotkey — which hides only when it is already in front — did nothing on
/// the first press and worked on the second.
#[cfg(windows)]
fn is_foreground(win: &tauri::WebviewWindow) -> bool {
    use windows_sys::Win32::UI::WindowsAndMessaging::GetForegroundWindow;
    let Ok(hwnd) = win.hwnd() else { return false };
    let fg = unsafe { GetForegroundWindow() };
    !fg.is_null() && fg == hwnd.0 as *mut core::ffi::c_void
}

/// One key, both directions: in front, put it away; anywhere else, bring
/// it here. Deliberately keyed on being in front rather than on being
/// visible — a window you can see but is buried behind three others
/// should come forward, not disappear, which is what a naive show/hide
/// gets wrong.
#[tauri::command]
fn summon_toggle(app: AppHandle) {
    let Some(win) = focused_window(&app) else {
        return;
    };
    let visible = win.is_visible().unwrap_or(false);
    let minimized = win.is_minimized().unwrap_or(false);
    #[cfg(windows)]
    let in_front = is_foreground(&win);
    #[cfg(not(windows))]
    let in_front = win.is_focused().unwrap_or(false);
    if visible && !minimized && in_front {
        if animate() {
            leave(&win, &app);
        } else {
            let _ = win.hide();
            let _ = apply_tray_text(&app);
        }
    } else {
        summon(&app);
    }
}

/// The close button hides to the tray by default, so the summon hotkey
/// keeps working once the window is out of the way — a hotkey that stops
/// working when you close the window is not much of a hotkey. Read fresh
/// from config each time so the setting takes effect without a restart.
fn close_hides() -> bool {
    mux::read_config()
        .get("close_action")
        .and_then(|v| v.as_str())
        .unwrap_or("hide")
        == "hide"
}

/// Spell an accelerator the way a person reads it. "Control" and
/// "Backquote" are how the shortcut has to be written for registration;
/// they are not what anyone calls those keys.
fn pretty_hotkey(accel: &str) -> String {
    accel
        .replace("Control", "Ctrl")
        .replace("Super", "Win")
        .replace("Backquote", "`")
        .replace("BracketLeft", "[")
        .replace("BracketRight", "]")
        .replace("Backslash", "\\")
        .replace("Semicolon", ";")
        .replace("Quote", "'")
        .replace("Comma", ",")
        .replace("Period", ".")
        .replace("Slash", "/")
        .replace("Minus", "-")
        .replace("Equal", "=")
}

fn summon_label() -> Option<String> {
    mux::read_config()
        .get("summon_hotkey")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(pretty_hotkey)
}

/// Tooltip and menu text for the tray. Once the window is hidden the tray
/// is the only place left to ask "how do I get it back", so the answer
/// lives there permanently rather than in a notice shown once, at the one
/// moment nobody is looking at the tray.
fn tray_strings(key: Option<&str>) -> (String, String) {
    match key {
        Some(k) => (
            format!("GTerminal — press {k} to show"),
            format!("Show GTerminal\t{k}"),
        ),
        None => (
            "GTerminal — no summon hotkey set".into(),
            "Show GTerminal".into(),
        ),
    }
}

fn tray_text() -> (String, String) {
    tray_strings(summon_label().as_deref())
}

fn apply_tray_text(app: &AppHandle) -> Result<(), String> {
    use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
    let Some(tray) = app.tray_by_id("main") else {
        return Ok(());
    };
    let (tip, show_label) = tray_text();
    let show = MenuItem::with_id(app, "show", show_label, true, None::<&str>)
        .map_err(|e| e.to_string())?;
    let quit = MenuItem::with_id(app, "quit", "Quit GTerminal", true, None::<&str>)
        .map_err(|e| e.to_string())?;
    let sep = PredefinedMenuItem::separator(app).map_err(|e| e.to_string())?;
    let menu = Menu::with_items(app, &[&show, &sep, &quit]).map_err(|e| e.to_string())?;
    tray.set_menu(Some(menu)).map_err(|e| e.to_string())?;
    tray.set_tooltip(Some(&tip)).map_err(|e| e.to_string())?;
    Ok(())
}

/// Called by the frontend whenever the hotkey setting changes, so the
/// tray never advertises a key that is no longer bound.
#[tauri::command]
fn refresh_tray(app: AppHandle) -> Result<(), String> {
    apply_tray_text(&app)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    if std::env::args().any(|a| a == "--daemon") {
        mux::run_daemon();
        return;
    }
    // Single-instance is machine-wide: the plugin keys its mutex on the
    // app identifier, so *any* copy of GTerminal claims it - a Store
    // install, a development build, and every app a test suite starts.
    // One escape hatch, for the cases where more than one really is
    // wanted: a test driving several, or a build being compared against
    // an installed copy. Not a setting, because a user who launches the
    // app twice wants the window they already have.
    let allow_many = std::env::var("GTERMINAL_ALLOW_MULTI").is_ok();
    let mut builder = tauri::Builder::default();
    if !allow_many {
        builder = builder
        // First, per the plugin's own requirement. Launching the app again
        // - from the Store tile, a shortcut, a workspace link - used to
        // start a second copy: two windows, two tray icons, and two
        // claimants for one summon hotkey. The sessions were never at
        // stake (they live in the daemon), but the tray was, and a tray
        // icon that does not answer is worse than no tray icon.
        //
        // The second launch hands its arguments over and exits, so a
        // workspace shortcut still opens its workspace - in the window
        // that is already there.
        .plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            summon(app);
            let _ = app.emit("second-instance", argv);
        }));
    }
    builder
        .on_window_event(|win, event| on_any_window_event(win, event))
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        // The summon hotkey is registered from the frontend, which owns the
        // config; this only installs the machinery.
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .setup(|app| {
            // The window is created hidden (visible:false) so the webview's
            // white pre-paint never flashes; the frontend shows it once the
            // theme is applied. Backstop: if the frontend never boots (dead
            // dev server, JS error), reveal the window after 5s anyway.
            // Tray icon: the app's only face once the window is hidden,
            // and the thing that makes a hidden window discoverable at all.
            {
                use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
                use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
                let (tip, show_label) = tray_text();
                let show = MenuItem::with_id(app, "show", show_label, true, None::<&str>)?;
                let quit = MenuItem::with_id(app, "quit", "Quit GTerminal", true, None::<&str>)?;
                let menu = Menu::with_items(
                    app,
                    &[&show, &PredefinedMenuItem::separator(app)?, &quit],
                )?;
                let mut tray = TrayIconBuilder::with_id("main")
                    .tooltip(&tip)
                    .menu(&menu)
                    // Left-click summons; the menu is the right-click job,
                    // or the left click could never do anything else.
                    .show_menu_on_left_click(false)
                    .on_menu_event(|app, event| match event.id.as_ref() {
                        "show" => summon(app),
                        "quit" => app.exit(0),
                        _ => {}
                    })
                    .on_tray_icon_event(|tray, event| {
                        if let TrayIconEvent::Click {
                            button: MouseButton::Left,
                            button_state: MouseButtonState::Up,
                            ..
                        } = event
                        {
                            summon(tray.app_handle());
                        }
                    });
                if let Some(icon) = app.default_window_icon() {
                    tray = tray.icon(icon.clone());
                }
                tray.build(app)?;
            }

            if let Some(win) = app.get_webview_window("main") {
                // Closing hides by default rather than ending the process,
                // which is what keeps the summon hotkey alive. Sessions were
                // never at stake either way — they live in the daemon.
                // Turn off Edge's accelerator keys. WebView2 leaves them on
                // by default, which in a terminal means Ctrl+F opens
                // find-on-page over ours, Ctrl+P offers to print the app,
                // and Ctrl+R / F5 reload it out from under live sessions.
                // The frontend cancels these per-event too, but that only
                // works where a handler of ours has focus — this closes the
                // whole class regardless of focus.
                #[cfg(windows)]
                let _ = win.with_webview(|webview| unsafe {
                    use webview2_com::Microsoft::Web::WebView2::Win32::ICoreWebView2Settings3;
                    use windows::core::Interface;
                    if let Ok(settings) = webview
                        .controller()
                        .CoreWebView2()
                        .and_then(|core| core.Settings())
                        .and_then(|s| s.cast::<ICoreWebView2Settings3>())
                    {
                        let _ = settings.SetAreBrowserAcceleratorKeysEnabled(false);
                    }
                    // Reading the clipboard makes WebView2 ask permission,
                    // the way a web page would. In a terminal it is not a
                    // web page asking: the user pressed Ctrl+V, or chose
                    // Paste from a menu they opened. A dialog in front of
                    // that is a bug, and it appears on every copy or paste
                    // until someone notices the "remember" box.
                    //
                    // Clipboard read is granted; everything else is left
                    // to the default, so a page that somehow asks for the
                    // camera still has to ask.
                    if let Ok(core) = webview.controller().CoreWebView2() {
                        use webview2_com::Microsoft::Web::WebView2::Win32::{
                            COREWEBVIEW2_PERMISSION_KIND_CLIPBOARD_READ,
                            COREWEBVIEW2_PERMISSION_STATE_ALLOW,
                        };
                        use webview2_com::PermissionRequestedEventHandler;
                        let mut token = Default::default();
                        let _ = core.add_PermissionRequested(
                            &PermissionRequestedEventHandler::create(Box::new(|_, args| {
                                let Some(args) = args else { return Ok(()) };
                                let mut kind = Default::default();
                                args.PermissionKind(&mut kind)?;
                                if kind == COREWEBVIEW2_PERMISSION_KIND_CLIPBOARD_READ {
                                    args.SetState(COREWEBVIEW2_PERMISSION_STATE_ALLOW)?;
                                }
                                Ok(())
                            })),
                            &mut token,
                        );
                    }
                });
                std::thread::spawn(move || {
                    std::thread::sleep(std::time::Duration::from_secs(5));
                    if !win.is_visible().unwrap_or(true) {
                        let _ = win.show();
                    }
                });
            }
            Ok(())
        })
        .manage(PtyManager::default())
        .invoke_handler(tauri::generate_handler![
            list_sessions,
            create_session,
            attach_session,
            peek_session,
            daemon_info,
            restart_daemon,
            logs_path,
            log_ui,
            summon_toggle,
            window_labels,
            write_session,
            resize_session,
            detach_session,
            kill_session,
            get_config,
            set_config,
            history_list,
            history_read,
            launch_info,
            create_shortcut,
            refresh_tray,
            stats::system_stats,
            stats::perf_counters,
            stats::perf_objects,
            stats::perf_items,
            stats::status_command
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
    use super::{fade_alpha, pretty_hotkey, tray_strings, FADE_STEPS};

    /// A fade that does not reach both ends is worse than none: stopping
    /// short of 0 leaves a ghost of the window on screen after it should
    /// be gone, and stopping short of 255 leaves the one you summoned
    /// permanently see-through.
    #[test]
    fn a_fade_starts_and_ends_where_it_should() {
        assert_eq!(fade_alpha(0, FADE_STEPS, false), 255, "leaving starts opaque");
        assert_eq!(fade_alpha(FADE_STEPS, FADE_STEPS, false), 0, "and ends invisible");
        assert_eq!(fade_alpha(0, FADE_STEPS, true), 0, "arriving starts invisible");
        assert_eq!(fade_alpha(FADE_STEPS, FADE_STEPS, true), 255, "and ends opaque");
    }

    /// Monotonic, or the window flickers back the way it came.
    #[test]
    fn a_fade_only_moves_one_way() {
        let mut last = 256i32;
        for i in 0..=FADE_STEPS {
            let a = fade_alpha(i, FADE_STEPS, false) as i32;
            assert!(a <= last, "alpha went back up at step {i}: {a} after {last}");
            last = a;
        }
        // Eased: past halfway, most of the fade is already done.
        let half = fade_alpha(FADE_STEPS / 2, FADE_STEPS, false);
        assert!(half < 128, "the fade should be more than half gone by halfway: {half}");
    }

    /// Once the window is hidden the tray is the only place left to ask
    /// how to get it back, so it has to answer — and say so plainly when
    /// there is no answer, rather than implying a key that does nothing.
    #[test]
    fn the_tray_says_how_to_get_the_window_back() {
        let (tip, item) = tray_strings(Some("Alt+Space"));
        assert!(tip.contains("Alt+Space"), "tooltip must name the key: {tip}");
        assert!(item.contains("Alt+Space"), "menu item must name the key: {item}");
        assert!(item.starts_with("Show GTerminal"), "menu item is still an action: {item}");
        // A tab between label and key is what puts the key in the
        // accelerator column rather than in the middle of the label.
        assert!(item.contains('\t'), "key belongs in its own column: {item:?}");
    }

    #[test]
    fn with_no_hotkey_it_says_so() {
        let (tip, item) = tray_strings(None);
        assert!(tip.contains("no summon hotkey"), "{tip}");
        assert_eq!(item, "Show GTerminal");
        assert!(!item.contains('\t'), "no key means no accelerator column: {item:?}");
    }

    /// Once the window is hidden the tray is the only place left to ask
    /// how to get it back, so the key it names has to be the key people
    /// see on their keyboard — not the accelerator spelling.
    #[test]
    fn hotkeys_are_spelled_for_humans() {
        assert_eq!(pretty_hotkey("Alt+Space"), "Alt+Space");
        assert_eq!(pretty_hotkey("Control+Backquote"), "Ctrl+`");
        assert_eq!(pretty_hotkey("Control+Shift+Backquote"), "Ctrl+Shift+`");
        assert_eq!(pretty_hotkey("Super+Backquote"), "Win+`");
        assert_eq!(pretty_hotkey("Control+Alt+T"), "Ctrl+Alt+T");
        assert_eq!(pretty_hotkey("F12"), "F12");
        assert_eq!(pretty_hotkey("Alt+BracketLeft"), "Alt+[");
        assert_eq!(pretty_hotkey("Control+Minus"), "Ctrl+-");
    }

    /// "Control" is a substring of nothing else here, but "Quote" is a
    /// substring of "Backquote" — replacing in the wrong order turns
    /// Backquote into Back'.
    #[test]
    fn backquote_survives_the_quote_rule() {
        assert_eq!(pretty_hotkey("Alt+Backquote"), "Alt+`");
        assert_eq!(pretty_hotkey("Alt+Quote"), "Alt+'");
    }
}
