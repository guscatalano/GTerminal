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
/// Per-session transcript size cap; recording stops (with a notice) beyond it.
const HISTORY_MAX: u64 = 10 * 1024 * 1024;

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
    Create {
        cols: u16,
        rows: u16,
        #[serde(default)]
        shell: Option<String>,
        /// Explicit start directory (session templates); overrides
        /// config.default_cwd. Falls back to home if not a directory.
        #[serde(default)]
        cwd: Option<String>,
    },
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
    /// Set when the session is in its "oops" grace window: it will be
    /// purged for real at this timestamp unless restored first.
    pub expires_ms: Option<u64>,
    /// Programs currently running inside the session (exe names), for
    /// tab icons and restore hints.
    pub running: Vec<String>,
    /// Current working directory (from the OSC 9;9 prompt hook), used
    /// for distinctive tab labels.
    pub cwd: String,
    /// Shell profile this session runs ("auto"/"pwsh"/"powershell"/"cmd").
    pub shell: String,
}

/// The "oops I screwed up" window: killed sessions keep their process
/// running (hidden) and exited sessions keep their checkpoint, for this
/// long, so a restore can undo the mistake. Configurable via
/// config.json {"grace_minutes": N}; 0 disables the grace entirely.
/// User config from %LOCALAPPDATA%\GTerminal\config.json ({} if absent).
pub fn read_config() -> serde_json::Value {
    std::fs::read_to_string(state_dir().join("config.json"))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_else(|| serde_json::json!({}))
}

pub fn write_config(value: &serde_json::Value) -> Result<(), String> {
    std::fs::create_dir_all(state_dir()).map_err(|e| e.to_string())?;
    std::fs::write(
        state_dir().join("config.json"),
        serde_json::to_string_pretty(value).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())
}

fn grace_ms() -> Option<u64> {
    let minutes = read_config()
        .get("grace_minutes")
        .and_then(|g| g.as_u64())
        .unwrap_or(5);
    if minutes == 0 {
        None
    } else {
        Some(minutes * 60_000)
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct Meta {
    id: u32,
    created_ms: u64,
    cwd: String,
    #[serde(default)]
    running: Vec<String>,
    /// Shell profile ("auto" | "pwsh" | "powershell" | "cmd") so the same
    /// shell comes back after a reboot resurrection.
    #[serde(default)]
    shell: String,
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
    shell: String,
    dirty: bool,
    /// Typed into the shell once its first prompt renders (writing earlier
    /// gets dropped while ConPTY is still initializing).
    pending_input: Option<Vec<u8>>,
    /// Soft-killed: the process is still running but will be killed for
    /// real at this time unless an attach cancels the doom.
    doomed_until: Option<u64>,
    /// Durable history transcript; None when disabled or size-capped.
    transcript: Option<std::fs::File>,
    transcript_len: u64,
}

/// A persisted session whose process is gone (reboot, daemon crash, or a
/// shell that exited within its grace window). The ring stays on disk until
/// the session is resurrected, killed, or its grace expires.
struct ColdSession {
    created_ms: u64,
    cwd: String,
    running: Vec<String>,
    expires: Option<u64>,
    shell: String,
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

/// Durable transcripts: every session's raw output is appended to
/// history/{created_ms}-{id}.log with a {stem}.json meta beside it, kept
/// for config.history_days after the session ends (default 14, 0 = off).
pub fn history_dir() -> PathBuf {
    state_dir().join("history")
}

fn history_days() -> u64 {
    read_config()
        .get("history_days")
        .and_then(|v| v.as_u64())
        .unwrap_or(14)
}

/// Meta sidecar for a transcript. ended_ms is stamped when the session
/// ends (or at daemon startup for sessions lost to a crash/reboot).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistoryMeta {
    pub id: u32,
    pub created_ms: u64,
    #[serde(default)]
    pub ended_ms: Option<u64>,
    pub cwd: String,
    pub shell: String,
}

fn history_stem(created_ms: u64, id: u32) -> String {
    format!("{created_ms}-{id}")
}

fn write_history_meta(meta: &HistoryMeta) {
    let stem = history_stem(meta.created_ms, meta.id);
    let _ = std::fs::write(
        history_dir().join(format!("{stem}.json")),
        serde_json::to_string(meta).expect("serialize"),
    );
}

fn finish_history(s: &Session, id: u32) {
    if history_days() == 0 {
        return;
    }
    let stem = history_stem(s.created_ms, id);
    if history_dir().join(format!("{stem}.json")).exists() {
        write_history_meta(&HistoryMeta {
            id,
            created_ms: s.created_ms,
            ended_ms: Some(now_ms()),
            cwd: s.cwd.clone(),
            shell: s.shell.clone(),
        });
    }
}

/// Stamp ended_ms on any transcript left open by a daemon that died with
/// live sessions (crash or reboot); nothing is live at startup.
fn finalize_stale_history() {
    let Ok(rd) = std::fs::read_dir(history_dir()) else {
        return;
    };
    for e in rd.flatten() {
        let p = e.path();
        if p.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        let Some(mut meta) = std::fs::read_to_string(&p)
            .ok()
            .and_then(|t| serde_json::from_str::<HistoryMeta>(&t).ok())
        else {
            continue;
        };
        if meta.ended_ms.is_none() {
            meta.ended_ms = Some(now_ms());
            write_history_meta(&meta);
        }
    }
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

    finalize_stale_history();
    spawn_flush_thread(sessions.clone());
    spawn_purge_thread(sessions.clone());
    spawn_child_monitor(sessions.clone());

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
                expires: None,
                shell: meta.shell,
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
                            shell: s.shell.clone(),
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

/// Tear down a live session whose shell has ended (typed `exit`, crash,
/// or kill): notify any attached client, and within the grace window park
/// it as restorable trash instead of deleting the checkpoint.
fn end_session(sessions: &Sessions, id: u32) {
    let mut state = sessions.lock().unwrap();
    let mut deleted = false;
    if let Some(mut s) = state.live.remove(&id) {
        if let Some((_, mut w)) = s.attached.take() {
            let _ = write_line(&mut w, &json!({"ev": "exit"}));
        }
        let _ = s.child.kill();
        finish_history(&s, id);
        if let Some(grace) = grace_ms() {
            let meta = Meta {
                id,
                created_ms: s.created_ms,
                cwd: s.cwd.clone(),
                running: Vec::new(),
                shell: s.shell.clone(),
            };
            let _ = std::fs::create_dir_all(sessions_dir());
            let _ = std::fs::write(
                meta_path(id),
                serde_json::to_string(&meta).expect("serialize"),
            );
            let _ = std::fs::write(ring_path(id), &s.ring);
            state.cold.insert(
                id,
                ColdSession {
                    created_ms: s.created_ms,
                    cwd: s.cwd,
                    running: Vec::new(),
                    expires: Some(now_ms() + grace),
                    shell: s.shell,
                },
            );
        } else {
            deleted = true;
        }
    }
    drop(state);
    if deleted {
        delete_persist(id);
    }
    exit_if_idle(sessions);
}

/// ConPTY's output pipe does NOT EOF when the shell exits (conhost keeps
/// it open), so a typed `exit` is invisible to the reader thread. Poll the
/// child processes directly to notice ended shells.
fn spawn_child_monitor(sessions: Sessions) {
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_secs(1));
        let ended: Vec<u32> = {
            let mut state = sessions.lock().unwrap();
            state
                .live
                .iter_mut()
                .filter_map(|(id, s)| match s.child.try_wait() {
                    Ok(Some(_)) => Some(*id),
                    _ => None,
                })
                .collect()
        };
        for id in ended {
            end_session(&sessions, id);
        }
    });
}

/// Enforce the "oops" grace windows: hard-kill soft-killed sessions and
/// delete trashed checkpoints once their time is up.
fn spawn_purge_thread(sessions: Sessions) {
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_secs(15));
        let now = now_ms();
        let mut purged: Vec<u32> = Vec::new();
        {
            let mut state = sessions.lock().unwrap();
            let doomed: Vec<u32> = state
                .live
                .iter()
                .filter(|(_, s)| s.doomed_until.is_some_and(|t| t <= now))
                .map(|(id, _)| *id)
                .collect();
            for id in doomed {
                if let Some(mut s) = state.live.remove(&id) {
                    let _ = s.child.kill();
                    finish_history(&s, id);
                    purged.push(id);
                }
            }
            let expired: Vec<u32> = state
                .cold
                .iter()
                .filter(|(_, c)| c.expires.is_some_and(|t| t <= now))
                .map(|(id, _)| *id)
                .collect();
            for id in expired {
                state.cold.remove(&id);
                purged.push(id);
            }
        }
        purge_history(&sessions, now);
        if !purged.is_empty() {
            for id in &purged {
                delete_persist(*id);
            }
            exit_if_idle(&sessions);
        }
    });
}

/// Delete transcript pairs older than the retention window. Sessions that
/// are still live or restorable keep their transcripts regardless of age.
fn purge_history(sessions: &Sessions, now: u64) {
    let days = history_days();
    if days == 0 {
        return;
    }
    let cutoff = now.saturating_sub(days * 24 * 3600 * 1000);
    let keep: std::collections::HashSet<String> = {
        let state = sessions.lock().unwrap();
        state
            .live
            .iter()
            .map(|(id, s)| history_stem(s.created_ms, *id))
            .chain(
                state
                    .cold
                    .iter()
                    .map(|(id, c)| history_stem(c.created_ms, *id)),
            )
            .collect()
    };
    let Ok(rd) = std::fs::read_dir(history_dir()) else {
        return;
    };
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().to_string();
        let stem = name
            .trim_end_matches(".log")
            .trim_end_matches(".json")
            .to_string();
        let created: Option<u64> = stem.split('-').next().and_then(|t| t.parse().ok());
        if created.is_some_and(|t| t < cutoff) && !keep.contains(&stem) {
            let _ = std::fs::remove_file(e.path());
        }
    }
}

fn exit_if_idle(sessions: &Sessions) {
    let state = sessions.lock().unwrap();
    if state.live.is_empty() && state.cold.is_empty() {
        let _ = std::fs::remove_file(port_file());
        // Give in-flight replies (e.g. the final kill's ok) time to reach
        // their sockets: process::exit tears connections down with an RST
        // that can discard just-written data.
        std::thread::sleep(Duration::from_millis(200));
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
                let mut list: Vec<(SessionInfo, Option<u32>)> = state
                    .live
                    .iter()
                    .map(|(id, s)| {
                        (
                            SessionInfo {
                                id: *id,
                                created_ms: s.created_ms,
                                attached: s.attached.is_some(),
                                alive: true,
                                expires_ms: s.doomed_until,
                                running: Vec::new(),
                                cwd: s.cwd.clone(),
                                shell: s.shell.clone(),
                            },
                            s.child_pid,
                        )
                    })
                    .chain(state.cold.iter().map(|(id, s)| {
                        (
                            SessionInfo {
                                id: *id,
                                created_ms: s.created_ms,
                                attached: false,
                                alive: false,
                                expires_ms: s.expires,
                                running: s.running.clone(),
                                cwd: s.cwd.clone(),
                                shell: s.shell.clone(),
                            },
                            None,
                        )
                    }))
                    .collect();
                drop(state);
                // Process enumeration happens outside the sessions lock.
                for (info, pid) in list.iter_mut() {
                    if let Some(pid) = pid {
                        info.running = descendant_programs(*pid);
                    }
                }
                let mut list: Vec<SessionInfo> = list.into_iter().map(|(i, _)| i).collect();
                list.sort_by_key(|s| s.created_ms);
                write_line(&mut out, &json!({"ok": true, "sessions": list}))?;
            }
            Request::Create { cols, rows, shell, cwd } => {
                let id = NEXT_SESSION.fetch_add(1, Ordering::Relaxed);
                // Start directory precedence: request cwd (templates), then
                // config.default_cwd, then home. start_session additionally
                // falls back to home if the path isn't a directory.
                let start_dir = cwd
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                    .or_else(|| {
                        read_config()
                            .get("default_cwd")
                            .and_then(|v| v.as_str())
                            .map(|s| s.trim().to_string())
                            .filter(|s| !s.is_empty())
                    })
                    .unwrap_or_else(|| {
                        std::env::var("USERPROFILE").unwrap_or_else(|_| "C:\\".into())
                    });
                let shell = shell.unwrap_or_else(|| "auto".into());
                match start_session(sessions, id, &start_dir, cols, rows, Vec::new(), now_ms(), &shell) {
                    Ok(()) => write_line(&mut out, &json!({"ok": true, "id": id}))?,
                    Err(e) => write_line(&mut out, &json!({"ok": false, "error": e}))?,
                }
            }
            Request::Kill { id } => {
                let mut state = sessions.lock().unwrap();
                let mut hard = true;
                if let Some(s) = state.live.get_mut(&id) {
                    if s.doomed_until.is_none() {
                        if let Some(grace) = grace_ms() {
                            // Soft kill: the tab closes, but the process
                            // keeps running until the grace expires so a
                            // restore can undo the mistake. Killing a
                            // doomed session again is a hard kill.
                            s.doomed_until = Some(now_ms() + grace);
                            if let Some((_, mut w)) = s.attached.take() {
                                let _ = write_line(&mut w, &json!({"ev": "exit"}));
                            }
                            hard = false;
                        }
                    }
                }
                if hard {
                    if let Some(mut s) = state.live.remove(&id) {
                        if let Some((_, mut w)) = s.attached.take() {
                            let _ = write_line(&mut w, &json!({"ev": "exit"}));
                        }
                        let _ = s.child.kill();
                    }
                    state.cold.remove(&id);
                }
                drop(state);
                if hard {
                    delete_persist(id);
                }
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
                    if let Err(e) = start_session(
                        sessions,
                        id,
                        &cold.cwd,
                        120,
                        30,
                        ring,
                        cold.created_ms,
                        &cold.shell.clone(),
                    ) {
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
                        // Attaching cancels any pending soft-kill.
                        s.doomed_until = None;
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
/// `shell` is a profile name: "pwsh", "powershell", "cmd", or "auto"
/// (PowerShell 7 with Windows PowerShell fallback).
fn start_session(
    sessions: &Sessions,
    id: u32,
    cwd: &str,
    cols: u16,
    rows: u16,
    ring: Vec<u8>,
    created_ms: u64,
    shell: &str,
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
    // PSReadLine prediction ("autocomplete ghost text") per config: smarter
    // sources / list view / off. try/catch keeps old PSReadLine versions
    // (Windows PowerShell 5.1) from erroring at startup.
    let prediction = read_config()
        .get("prediction")
        .and_then(|v| v.as_str())
        .unwrap_or("shell")
        .to_string();
    let ps_init = match prediction.as_str() {
        "inline" | "list" => {
            let view = if prediction == "list" { "ListView" } else { "InlineView" };
            format!(
                "{PROMPT_CMD}; try {{ Set-PSReadLineOption -PredictionSource HistoryAndPlugin -PredictionViewStyle {view} -ErrorAction Stop }} catch {{ try {{ Set-PSReadLineOption -PredictionSource History -PredictionViewStyle {view} }} catch {{}} }}"
            )
        }
        "off" => format!(
            "{PROMPT_CMD}; try {{ Set-PSReadLineOption -PredictionSource None -ErrorAction Stop }} catch {{}}"
        ),
        _ => PROMPT_CMD.to_string(),
    };
    let build_ps = |exe: &str| {
        let mut cmd = CommandBuilder::new(exe);
        cmd.args(["-NoLogo", "-NoExit", "-Command", &ps_init]);
        cmd.cwd(&cwd);
        cmd.env("TERM", "xterm-256color");
        cmd
    };
    let build_cmd_exe = || {
        let mut cmd = CommandBuilder::new("cmd.exe");
        // cmd's prompt can emit escapes: $E]9;9;$P$E\ is the same OSC 9;9
        // cwd report the PowerShell prompt hook produces.
        cmd.args(["/K", "prompt $E]9;9;$P$E\\$P$G"]);
        cmd.cwd(&cwd);
        cmd.env("TERM", "xterm-256color");
        cmd
    };
    let child = match shell {
        "cmd" => pair
            .slave
            .spawn_command(build_cmd_exe())
            .map_err(|e| e.to_string())?,
        "powershell" => pair
            .slave
            .spawn_command(build_ps("powershell.exe"))
            .map_err(|e| e.to_string())?,
        "pwsh" => pair
            .slave
            .spawn_command(build_ps("pwsh.exe"))
            .map_err(|e| e.to_string())?,
        _ => match pair.slave.spawn_command(build_ps("pwsh.exe")) {
            Ok(c) => c,
            Err(_) => pair
                .slave
                .spawn_command(build_ps("powershell.exe"))
                .map_err(|e| e.to_string())?,
        },
    };
    drop(pair.slave);

    let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
    let writer = pair.master.take_writer().map_err(|e| e.to_string())?;

    // Transcript opens in append mode: a resurrected session (same
    // created_ms + id) continues the transcript of its past life.
    let (transcript, transcript_len) = if history_days() > 0 {
        let _ = std::fs::create_dir_all(history_dir());
        let stem = history_stem(created_ms, id);
        write_history_meta(&HistoryMeta {
            id,
            created_ms,
            ended_ms: None,
            cwd: cwd.clone(),
            shell: shell.to_string(),
        });
        match std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(history_dir().join(format!("{stem}.log")))
        {
            Ok(f) => {
                let len = f.metadata().map(|m| m.len()).unwrap_or(0);
                (Some(f), len)
            }
            Err(_) => (None, 0),
        }
    } else {
        (None, 0)
    };

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
            shell: shell.to_string(),
            dirty: true,
            pending_input: None,
            doomed_until: None,
            transcript,
            transcript_len,
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
            if let Some(f) = s.transcript.as_mut() {
                let _ = f.write_all(&buf[..n]);
                s.transcript_len += n as u64;
                if s.transcript_len >= HISTORY_MAX {
                    let _ = f.write_all(
                        b"\r\n\x1b[90m[transcript size cap reached - recording stopped]\x1b[0m\r\n",
                    );
                    s.transcript = None;
                }
            }
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
        // PTY stream ended (master dropped or conhost died): tear down the
        // session if the child monitor hasn't already.
        end_session(&sessions, id);
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
