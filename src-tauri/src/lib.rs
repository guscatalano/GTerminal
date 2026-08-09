mod mux;

use mux::Request;
use serde_json::Value;
use std::collections::HashMap;
use std::io::BufRead;
use std::io::BufReader;
use std::net::TcpStream;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, State};

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
}

fn attach_internal(app: &AppHandle, state: &PtyManager, id: u32) -> Result<(), String> {
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
    state: State<PtyManager>,
    cols: u16,
    rows: u16,
    shell: Option<String>,
    cwd: Option<String>,
) -> Result<u32, String> {
    let v = mux::client::control(&Request::Create { cols, rows, shell, cwd })?;
    let id = v.get("id").and_then(Value::as_u64).ok_or("bad response")? as u32;
    attach_internal(&app, &state, id)?;
    Ok(id)
}

#[tauri::command]
fn attach_session(
    app: AppHandle,
    state: State<PtyManager>,
    id: u32,
    cols: u16,
    rows: u16,
) -> Result<(), String> {
    attach_internal(&app, &state, id)?;
    send_to(&state, id, Request::Resize { cols, rows })
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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    if std::env::args().any(|a| a == "--daemon") {
        mux::run_daemon();
        return;
    }
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .manage(PtyManager::default())
        .invoke_handler(tauri::generate_handler![
            list_sessions,
            create_session,
            attach_session,
            write_session,
            resize_session,
            detach_session,
            kill_session,
            get_config,
            set_config,
            history_list,
            history_read
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
