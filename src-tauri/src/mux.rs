//! Session daemon ("mux") and its client.
//!
//! The daemon is this same executable launched with `--daemon`. It owns every
//! PTY session and outlives the UI window, so shells keep running when the
//! window (or a tab) closes. The UI attaches over a localhost TCP socket and
//! replays each session's scrollback ring buffer on attach.
//!
//! Sessions are also checkpointed to disk (scrollback ring + working
//! directory) every few seconds. After a reboot the daemon loads them as
//! "cold" sessions: attaching resurrects one with a fresh shell in the saved
//! directory and the old scrollback replayed behind a divider.
//!
//! Protocol: newline-delimited JSON. Control requests (list/create/kill) get
//! one reply line. An `attach` request turns the connection into a stream:
//! the server pushes `{"ev":"data"}` / `{"ev":"exit"}` lines while the client
//! sends write/resize/detach requests, which get no reply.

use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const RING_MAX: usize = 512 * 1024;
const FLUSH_INTERVAL: Duration = Duration::from_secs(3);

/// Undo terminal modes a dead TUI may have left enabled in the replayed
/// scrollback: mouse tracking (1000/1002/1003/1005/1006 — the "mouse types
/// garbage" bug), bracketed paste, application cursor keys, alt screen, and
/// hidden cursor. Only for resurrection — on live reattach the replayed
/// modes match what the still-running app expects.
const MODE_RESET: &str =
    "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1005l\x1b[?1006l\x1b[?2004l\x1b[?1l\x1b[?1049l\x1b[?47l\x1b[?1004l\x1b[?9001l\x1b[?25h\x1b[0m\r\n";

/// Wraps the user's prompt (after their profile has set it up) so every
/// prompt also emits OSC 9;9 with the current directory — the same
/// convention Windows Terminal uses for cwd tracking.
const PROMPT_CMD: &str = r#"$global:__gtp = $function:prompt; $function:prompt = { "$(& $global:__gtp)" + [char]27 + ']9;9;' + "$pwd" + [char]7 }"#;

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum Request {
    List,
    Create { cols: u16, rows: u16 },
    Kill { id: u32 },
    Attach { id: u32 },
    Write { data: String },
    Resize { cols: u16, rows: u16 },
    Detach,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionInfo {
    pub id: u32,
    pub created_ms: u64,
    pub attached: bool,
    pub alive: bool,
}

#[derive(Debug, Serialize, Deserialize)]
struct Meta {
    id: u32,
    created_ms: u64,
    cwd: String,
    #[serde(default)]
    running: Vec<String>,
}

struct Session {
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    child: Box<dyn Child + Send + Sync>,
    child_pid: Option<u32>,
    ring: Vec<u8>,
    attached: Option<(u64, TcpStream)>,
    created_ms: u64,
    cwd: String,
    dirty: bool,
    /// Typed into the shell once its first prompt renders (writing earlier
    /// gets dropped while ConPTY is still initializing).
    pending_input: Option<Vec<u8>>,
}

/// A persisted session whose process is gone (reboot, daemon crash). The
/// ring stays on disk until the session is resurrected or killed.
struct ColdSession {
    created_ms: u64,
    cwd: String,
    running: Vec<String>,
}

#[derive(Default)]
struct DaemonState {
    live: HashMap<u32, Session>,
    cold: HashMap<u32, ColdSession>,
}

type Sessions = Arc<Mutex<DaemonState>>;

static NEXT_SESSION: AtomicU32 = AtomicU32::new(1);
static NEXT_CONN: AtomicU64 = AtomicU64::new(1);

fn state_dir() -> PathBuf {
    let base = std::env::var("LOCALAPPDATA").unwrap_or_else(|_| ".".into());
    PathBuf::from(base).join("GTerminal")
}

fn port_file() -> PathBuf {
    state_dir().join("daemon.port")
}

pub fn sessions_dir() -> PathBuf {
    state_dir().join("sessions")
}

fn meta_path(id: u32) -> PathBuf {
    sessions_dir().join(format!("{id}.json"))
}

fn ring_path(id: u32) -> PathBuf {
    sessions_dir().join(format!("{id}.ring"))
}

fn delete_persist(id: u32) {
    let _ = std::fs::remove_file(meta_path(id));
    let _ = std::fs::remove_file(ring_path(id));
}

pub fn write_line<W: Write>(w: &mut W, value: &serde_json::Value) -> std::io::Result<()> {
    let mut s = serde_json::to_string(value).expect("serialize");
    s.push('\n');
    w.write_all(s.as_bytes())
}

/// Extract the longest valid UTF-8 prefix from `carry`, leaving any
/// incomplete trailing sequence for the next PTY read.
fn take_valid_utf8(carry: &mut Vec<u8>) -> Option<String> {
    match std::str::from_utf8(carry) {
        Ok(s) => {
            let out = s.to_string();
            carry.clear();
            Some(out)
        }
        Err(e) => {
            let valid = e.valid_up_to();
            if valid > 0 {
                let out = String::from_utf8_lossy(&carry[..valid]).into_owned();
                carry.drain(..valid);
                Some(out)
            } else if carry.len() >= 8 {
                let out = String::from_utf8_lossy(carry).into_owned();
                carry.clear();
                Some(out)
            } else {
                None
            }
        }
    }
}

/// Last OSC 9;9 (current directory) sequence in a chunk of output, if any.
fn parse_cwd(text: &str) -> Option<String> {
    let start = text.rfind("\x1b]9;9;")? + 6;
    let rest = &text[start..];
    let end = rest.find(['\x07', '\x1b'])?;
    let path = rest[..end].trim_matches('"');
    if path.is_empty() {
        None
    } else {
        Some(path.to_string())
    }
}

/// Exe names (without .exe) of every descendant of `root`, e.g. what the
/// user is running inside a shell. ConPTY plumbing is filtered out.
#[cfg(windows)]
fn descendant_programs(root: u32) -> Vec<String> {
    use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
        TH32CS_SNAPPROCESS,
    };
    let mut procs: Vec<(u32, u32, String)> = Vec::new();
    unsafe {
        let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snap == INVALID_HANDLE_VALUE {
            return vec![];
        }
        let mut entry: PROCESSENTRY32W = std::mem::zeroed();
        entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
        if Process32FirstW(snap, &mut entry) != 0 {
            loop {
                let len = entry
                    .szExeFile
                    .iter()
                    .position(|&c| c == 0)
                    .unwrap_or(entry.szExeFile.len());
                let name = String::from_utf16_lossy(&entry.szExeFile[..len]);
                procs.push((entry.th32ProcessID, entry.th32ParentProcessID, name));
                if Process32NextW(snap, &mut entry) == 0 {
                    break;
                }
            }
        }
        CloseHandle(snap);
    }
    let mut out: Vec<String> = Vec::new();
    let mut frontier = vec![root];
    while let Some(pid) = frontier.pop() {
        for (cpid, ppid, name) in &procs {
            if *ppid == pid {
                frontier.push(*cpid);
                let name = name.trim_end_matches(".exe").trim_end_matches(".EXE");
                if !name.eq_ignore_ascii_case("conhost")
                    && !name.eq_ignore_ascii_case("OpenConsole")
                    && !out.iter().any(|n| n.eq_ignore_ascii_case(name))
                {
                    out.push(name.to_string());
                }
            }
        }
    }
    out.truncate(4);
    out
}

#[cfg(not(windows))]
fn descendant_programs(_root: u32) -> Vec<String> {
    vec![]
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub fn run_daemon() {
    let sessions: Sessions = Arc::new(Mutex::new(DaemonState::default()));
    load_cold(&mut sessions.lock().unwrap());

    // Cold sessions must be loaded before the port file exists, so a client
    // that connects immediately after spawn already sees them.
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind daemon socket");
    let port = listener.local_addr().expect("local addr").port();
    std::fs::create_dir_all(state_dir()).ok();
    std::fs::write(port_file(), port.to_string()).expect("write port file");

    spawn_flush_thread(sessions.clone());

    for conn in listener.incoming() {
        if let Ok(stream) = conn {
            stream.set_nodelay(true).ok();
            let sessions = sessions.clone();
            std::thread::spawn(move || {
                handle_conn(stream, sessions);
            });
        }
    }
}

fn load_cold(state: &mut DaemonState) {
    let Ok(entries) = std::fs::read_dir(sessions_dir()) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Ok(txt) = std::fs::read_to_string(&path) else {
            continue;
        };
        let Ok(meta) = serde_json::from_str::<Meta>(&txt) else {
            continue;
        };
        NEXT_SESSION.fetch_max(meta.id + 1, Ordering::Relaxed);
        state.cold.insert(
            meta.id,
            ColdSession {
                created_ms: meta.created_ms,
                cwd: meta.cwd,
                running: meta.running,
            },
        );
    }
}

fn spawn_flush_thread(sessions: Sessions) {
    std::thread::spawn(move || loop {
        std::thread::sleep(FLUSH_INTERVAL);
        let mut snapshots = Vec::new();
        {
            let mut state = sessions.lock().unwrap();
            for (id, s) in state.live.iter_mut() {
                if s.dirty {
                    s.dirty = false;
                    snapshots.push((
                        Meta {
                            id: *id,
                            created_ms: s.created_ms,
                            cwd: s.cwd.clone(),
                            running: Vec::new(),
                        },
                        s.ring.clone(),
                        s.child_pid,
                    ));
                }
            }
        }
        if !snapshots.is_empty() {
            let _ = std::fs::create_dir_all(sessions_dir());
            for (mut meta, ring, child_pid) in snapshots {
                // Process enumeration happens outside the sessions lock.
                if let Some(pid) = child_pid {
                    meta.running = descendant_programs(pid);
                }
                let _ = std::fs::write(
                    meta_path(meta.id),
                    serde_json::to_string(&meta).expect("serialize"),
                );
                let _ = std::fs::write(ring_path(meta.id), &ring);
            }
        }
    });
}

fn exit_if_idle(sessions: &Sessions) {
    let state = sessions.lock().unwrap();
    if state.live.is_empty() && state.cold.is_empty() {
        let _ = std::fs::remove_file(port_file());
        std::process::exit(0);
    }
}

fn handle_conn(stream: TcpStream, sessions: Sessions) {
    let conn_id = NEXT_CONN.fetch_add(1, Ordering::Relaxed);
    let mut attached_id: Option<u32> = None;
    // The loop must not early-return: an abrupt client death surfaces as a
    // read/write error, and the detach cleanup below has to run regardless.
    let _ = conn_loop(stream, &sessions, conn_id, &mut attached_id);
    if let Some(id) = attached_id {
        if let Some(s) = sessions.lock().unwrap().live.get_mut(&id) {
            if matches!(s.attached, Some((cid, _)) if cid == conn_id) {
                s.attached = None;
            }
        }
    }
}

fn conn_loop(
    stream: TcpStream,
    sessions: &Sessions,
    conn_id: u64,
    attached_id: &mut Option<u32>,
) -> std::io::Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut out = stream;
    let mut line = String::new();
    loop {
        line.clear();
        if reader.read_line(&mut line)? == 0 {
            break;
        }
        let req: Request = match serde_json::from_str(line.trim()) {
            Ok(r) => r,
            Err(_) => {
                write_line(&mut out, &json!({"ok": false, "error": "bad request"}))?;
                continue;
            }
        };
        match req {
            Request::List => {
                let state = sessions.lock().unwrap();
                let mut list: Vec<SessionInfo> = state
                    .live
                    .iter()
                    .map(|(id, s)| SessionInfo {
                        id: *id,
                        created_ms: s.created_ms,
                        attached: s.attached.is_some(),
                        alive: true,
                    })
                    .chain(state.cold.iter().map(|(id, s)| SessionInfo {
                        id: *id,
                        created_ms: s.created_ms,
                        attached: false,
                        alive: false,
                    }))
                    .collect();
                drop(state);
                list.sort_by_key(|s| s.created_ms);
                write_line(&mut out, &json!({"ok": true, "sessions": list}))?;
            }
            Request::Create { cols, rows } => {
                let id = NEXT_SESSION.fetch_add(1, Ordering::Relaxed);
                let home = std::env::var("USERPROFILE").unwrap_or_else(|_| "C:\\".into());
                match start_session(sessions, id, &home, cols, rows, Vec::new(), now_ms()) {
                    Ok(()) => write_line(&mut out, &json!({"ok": true, "id": id}))?,
                    Err(e) => write_line(&mut out, &json!({"ok": false, "error": e}))?,
                }
            }
            Request::Kill { id } => {
                let mut state = sessions.lock().unwrap();
                if let Some(mut s) = state.live.remove(&id) {
                    if let Some((_, mut w)) = s.attached.take() {
                        let _ = write_line(&mut w, &json!({"ev": "exit"}));
                    }
                    let _ = s.child.kill();
                }
                state.cold.remove(&id);
                drop(state);
                delete_persist(id);
                write_line(&mut out, &json!({"ok": true}))?;
                exit_if_idle(sessions);
            }
            Request::Attach { id } => {
                // Resurrect first if this is a cold session: spawn a fresh
                // shell in the saved cwd with the old scrollback preloaded.
                let cold = sessions.lock().unwrap().cold.remove(&id);
                if let Some(cold) = cold {
                    let mut divider =
                        String::from("\r\n\x1b[90m── session restored — previous shell ended (reboot?)");
                    if !cold.running.is_empty() {
                        divider += &format!(" · was running: {}", cold.running.join(", "));
                    }
                    divider += " ──\x1b[0m\r\n";
                    let mut ring = std::fs::read(ring_path(id)).unwrap_or_default();
                    ring.extend_from_slice(MODE_RESET.as_bytes());
                    ring.extend_from_slice(divider.as_bytes());
                    if let Err(e) =
                        start_session(sessions, id, &cold.cwd, 120, 30, ring, cold.created_ms)
                    {
                        sessions.lock().unwrap().cold.insert(id, cold);
                        write_line(&mut out, &json!({"ok": false, "error": e}))?;
                        continue;
                    }
                    // Claude Code resumes its conversation for the restored
                    // cwd; pre-type (without executing) so one Enter resumes.
                    if cold.running.iter().any(|n| n.to_lowercase().contains("claude")) {
                        if let Some(s) = sessions.lock().unwrap().live.get_mut(&id) {
                            s.pending_input = Some(b"claude --continue".to_vec());
                        }
                    }
                }
                let mut state = sessions.lock().unwrap();
                match state.live.get_mut(&id) {
                    Some(s) => {
                        // Send the reply and full scrollback replay while
                        // holding the lock, so the PTY reader thread cannot
                        // interleave live output mid-replay; only then does
                        // this connection start receiving live data.
                        write_line(&mut out, &json!({"ok": true}))?;
                        let replay = String::from_utf8_lossy(&s.ring).into_owned();
                        write_line(&mut out, &json!({"ev": "data", "data": replay}))?;
                        s.attached = Some((conn_id, out.try_clone()?));
                        *attached_id = Some(id);
                    }
                    None => {
                        drop(state);
                        write_line(&mut out, &json!({"ok": false, "error": "no such session"}))?;
                    }
                }
            }
            Request::Write { data } => {
                if let Some(id) = *attached_id {
                    if let Some(s) = sessions.lock().unwrap().live.get_mut(&id) {
                        let _ = s.writer.write_all(data.as_bytes());
                    }
                }
            }
            Request::Resize { cols, rows } => {
                if let Some(id) = *attached_id {
                    if let Some(s) = sessions.lock().unwrap().live.get_mut(&id) {
                        let _ = s.master.resize(PtySize {
                            rows,
                            cols,
                            pixel_width: 0,
                            pixel_height: 0,
                        });
                    }
                }
            }
            Request::Detach => break,
        }
    }
    Ok(())
}

/// Spawn a shell in `cwd` and register it as live session `id`, with `ring`
/// as pre-existing scrollback (used when resurrecting a cold session).
fn start_session(
    sessions: &Sessions,
    id: u32,
    cwd: &str,
    cols: u16,
    rows: u16,
    ring: Vec<u8>,
    created_ms: u64,
) -> Result<(), String> {
    let pty_system = native_pty_system();
    let pair = pty_system
        .openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|e| e.to_string())?;

    let cwd = if std::path::Path::new(cwd).is_dir() {
        cwd.to_string()
    } else {
        std::env::var("USERPROFILE").unwrap_or_else(|_| "C:\\".into())
    };
    let build_cmd = |shell: &str| {
        let mut cmd = CommandBuilder::new(shell);
        cmd.args(["-NoLogo", "-NoExit", "-Command", PROMPT_CMD]);
        cmd.cwd(&cwd);
        cmd.env("TERM", "xterm-256color");
        cmd
    };
    let child = match pair.slave.spawn_command(build_cmd("pwsh.exe")) {
        Ok(c) => c,
        Err(_) => pair
            .slave
            .spawn_command(build_cmd("powershell.exe"))
            .map_err(|e| e.to_string())?,
    };
    drop(pair.slave);

    let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
    let writer = pair.master.take_writer().map_err(|e| e.to_string())?;

    let child_pid = child.process_id();
    sessions.lock().unwrap().live.insert(
        id,
        Session {
            master: pair.master,
            writer,
            child,
            child_pid,
            ring,
            attached: None,
            created_ms,
            cwd,
            dirty: true,
            pending_input: None,
        },
    );

    let sessions = sessions.clone();
    std::thread::spawn(move || {
        let mut buf = [0u8; 8192];
        let mut carry: Vec<u8> = Vec::new();
        loop {
            let n = match reader.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => n,
            };
            let mut state = sessions.lock().unwrap();
            let Some(s) = state.live.get_mut(&id) else {
                break;
            };
            s.ring.extend_from_slice(&buf[..n]);
            if s.ring.len() > RING_MAX {
                let excess = s.ring.len() - RING_MAX;
                s.ring.drain(..excess);
            }
            s.dirty = true;
            carry.extend_from_slice(&buf[..n]);
            if let Some(text) = take_valid_utf8(&mut carry) {
                if let Some(cwd) = parse_cwd(&text) {
                    s.cwd = cwd;
                    // First prompt has rendered — the shell is ready for input.
                    if let Some(input) = s.pending_input.take() {
                        let _ = s.writer.write_all(&input);
                    }
                }
                if let Some((_, w)) = s.attached.as_mut() {
                    if write_line(w, &json!({"ev": "data", "data": text})).is_err() {
                        s.attached = None;
                    }
                }
            }
        }
        // Shell exited on its own (or was killed): this session is complete,
        // so its checkpoint is deleted rather than left to resurrect.
        let mut state = sessions.lock().unwrap();
        if let Some(mut s) = state.live.remove(&id) {
            if let Some((_, mut w)) = s.attached.take() {
                let _ = write_line(&mut w, &json!({"ev": "exit"}));
            }
            let _ = s.child.kill();
        }
        drop(state);
        delete_persist(id);
        exit_if_idle(&sessions);
    });

    Ok(())
}

pub mod client {
    use super::*;
    use std::process::{Command, Stdio};

    pub fn connect() -> std::io::Result<TcpStream> {
        let port: u16 = std::fs::read_to_string(port_file())?
            .trim()
            .parse()
            .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidData, "bad port file"))?;
        let stream = TcpStream::connect(("127.0.0.1", port))?;
        stream.set_nodelay(true).ok();
        Ok(stream)
    }

    /// Whether checkpointed sessions exist on disk (e.g. from before a
    /// reboot) that a daemon could offer for resurrection.
    pub fn has_persisted_sessions() -> bool {
        std::fs::read_dir(sessions_dir())
            .map(|mut d| d.next().is_some())
            .unwrap_or(false)
    }

    pub fn ensure() -> Result<TcpStream, String> {
        if let Ok(s) = connect() {
            return Ok(s);
        }
        // Stale port file from a dead daemon must not shadow the new one.
        let _ = std::fs::remove_file(port_file());
        spawn_daemon()?;
        for _ in 0..60 {
            std::thread::sleep(Duration::from_millis(50));
            if let Ok(s) = connect() {
                return Ok(s);
            }
        }
        Err("session daemon did not start".into())
    }

    #[cfg(windows)]
    fn spawn_daemon() -> Result<(), String> {
        use std::os::windows::process::CommandExt;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x0100_0000;
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        // Breakaway lets the daemon survive `tauri dev` job cleanup; fall
        // back for environments whose job object forbids breakaway.
        let spawn = |flags: u32| {
            Command::new(&exe)
                .arg("--daemon")
                .creation_flags(flags)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
        };
        spawn(DETACHED_PROCESS | CREATE_BREAKAWAY_FROM_JOB)
            .or_else(|_| spawn(DETACHED_PROCESS))
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    #[cfg(not(windows))]
    fn spawn_daemon() -> Result<(), String> {
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        Command::new(&exe)
            .arg("--daemon")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    /// One-shot request/reply on a fresh connection (list/create/kill).
    pub fn control(req: &Request) -> Result<serde_json::Value, String> {
        let stream = ensure()?;
        request(stream, req)
    }

    pub fn request(mut stream: TcpStream, req: &Request) -> Result<serde_json::Value, String> {
        write_line(&mut stream, &serde_json::to_value(req).expect("serialize"))
            .map_err(|e| e.to_string())?;
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        reader.read_line(&mut line).map_err(|e| e.to_string())?;
        let v: serde_json::Value =
            serde_json::from_str(line.trim()).map_err(|e| e.to_string())?;
        if v.get("ok").and_then(serde_json::Value::as_bool) == Some(true) {
            Ok(v)
        } else {
            Err(v
                .get("error")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("daemon error")
                .to_string())
        }
    }
}
