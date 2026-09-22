//! Remote control: this app's sessions, served to a phone.
//!
//! The daemon listens on `127.0.0.1:0` with no authentication whatsoever,
//! and that is defensible only because nothing but a local process can
//! reach it. This server is the opposite case on purpose — the whole
//! point of it is that something on another machine reaches it — so none
//! of the daemon's reasoning carries over. Every request here presents a
//! shared secret, the secret is compared in constant time, the default
//! bind is loopback, and the page is baked into the binary so no request
//! path ever reaches the filesystem.
//!
//! Nothing listens until somebody turns it on. `enabled` is false for an
//! absent key, so a fresh install and every install that existed before
//! this file did opens no socket at all; `sync` is the only caller of
//! `listen`, and the settings toggle is the only caller of `sync`.
//!
//! No TLS, deliberately. The certificate for a private address would
//! have to be self-signed, and a browser warning that has to be clicked
//! through every time teaches exactly the habit that makes the next
//! warning useless - while buying nothing over WireGuard, which is the
//! intended route and is already encrypted. On a bare LAN the traffic is
//! readable by anything on that network, including the token; the
//! settings page says so where the bind is chosen, rather than leaving
//! it to be inferred from the scheme in the link.
//!
//! It runs in the app process rather than in the daemon. The daemon is
//! deliberately hard to stop — that is what keeps shells alive across a
//! closed window — and a listening socket that is deliberately hard to
//! stop is the wrong shape for something whose whole risk is that it is
//! listening. Quitting GTerminal takes the server with it, and that is
//! the behaviour a person turning this on would guess.

use crate::mux;
use crate::mux::Request;
use serde_json::{json, Value};
use rustls::{ServerConfig, ServerConnection, StreamOwned};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// The page, and everything it needs. Embedded rather than read from
/// disk: a server that answers a request by opening a file named in that
/// request is one missing check away from serving `../../config.json`,
/// and the token is in config.json.
const PAGE: &str = include_str!("remote.html");

/// The terminal engine, put in OUT_DIR by build.rs from the same
/// node_modules the desktop window is built from - so the phone and the
/// window are never two different terminals reading one byte stream.
const ENGINE_JS: &str = include_str!(concat!(env!("OUT_DIR"), "/xterm.js"));
const ENGINE_CSS: &str = include_str!(concat!(env!("OUT_DIR"), "/xterm.css"));

/// The port nothing was already using on the machines this was tried on.
/// Changeable in settings, because "nothing was using it here" is not a
/// promise about anyone else's machine.
pub const DEFAULT_PORT: u16 = 8722;

/// How long between asking the daemon what a session has produced.
///
/// `peek` copies up to the ring cap under the sessions lock, which is the
/// same lock a keystroke needs, so this is not free — but at half a
/// second it is roughly a tenth of a millisecond of lock time per second
/// per watching phone, which does not register next to the keystroke
/// budget the typing suite measures.
const POLL_MS: u64 = 500;

/// Sent when nothing has happened, so a phone that has slept, or a
/// proxy in between, does not quietly drop a stream that is still good.
const KEEPALIVE_MS: u64 = 15_000;

/// A stream and a page load each hold a thread. This is not a public web
/// server and never will be; the cap is here so that something pointed at
/// the port cannot turn "reachable" into "out of threads".
const MAX_CONNS: usize = 24;

const MAX_HEADER_BYTES: usize = 16 * 1024;
const MAX_BODY_BYTES: usize = 64 * 1024;

/// Bumped by every `sync`. A server thread that finds the number has
/// moved on stops: this is how "turn it off" and "regenerate the token"
/// reach a listener that is currently blocked in `accept`.
static GENERATION: AtomicU64 = AtomicU64::new(0);
static LIVE_CONNS: AtomicUsize = AtomicUsize::new(0);
static RUNNING_PORT: AtomicU32 = AtomicU32::new(0);
/// Whether the running server is speaking HTTPS. Read by `status` so the
/// window builds `https://` links and QR codes, since a phone opening an
/// `http://` link against a TLS port is exactly the "bad request" this
/// whole change is here to stop.
static RUNNING_TLS: AtomicBool = AtomicBool::new(false);

static FAILURES: AtomicU32 = AtomicU32::new(0);
/// Connections that got past the token, ever, and when the last one did.
///
/// Not for security - a refused request is counted elsewhere - but so
/// the window can say that somebody is actually reading it. "Remote
/// control is on" and "somebody is looking at your shell right now" are
/// different facts and the second one is the one worth interrupting for.
static SERVED: AtomicU64 = AtomicU64::new(0);
static LAST_SERVED_MS: AtomicU64 = AtomicU64::new(0);
static NEXT_VIEWER: AtomicU64 = AtomicU64::new(1);

/// How many windows of this app are on screen.
///
/// Serving requires one. Closing the last window hides it to the tray
/// and the app keeps running, which is right for a terminal holding
/// sessions and wrong for a port onto them: the badge that says the port
/// is open lives in the window, so a hidden window would be serving with
/// nothing anywhere saying so. Rather than let the warning and the thing
/// it warns about come apart, the thing stops.
///
/// The setting is untouched by this. Showing a window starts it again,
/// and the settings page calls that state paused rather than off, so
/// nobody goes looking for a switch that is already in the right place.
static WINDOWS: AtomicU32 = AtomicU32::new(0);

/// Tell the server how many windows are up, and put the running state
/// back in step with it. Cheap and idempotent: `sync` bumps a generation
/// and rebinds only when something actually changed.
pub fn set_windows(n: u32) -> bool {
    let before = WINDOWS.swap(n, Ordering::SeqCst);
    if before == n {
        return false;
    }
    let was_running = RUNNING_PORT.load(Ordering::SeqCst) != 0;
    let config = mux::read_config();
    let should_run = enabled(&config) && n > 0;
    if was_running != should_run {
        sync(&config);
        return true;
    }
    false
}

fn windows_open() -> bool {
    WINDOWS.load(Ordering::SeqCst) > 0
}

/// One line for the tray, or nothing when the feature is off.
///
/// The tray is the only surface left once the window is hidden, and
/// "hidden" is exactly the state somebody forgets they are in.
pub fn tray_line() -> Option<String> {
    let config = mux::read_config();
    if !enabled(&config) {
        return None;
    }
    if !windows_open() {
        return Some("Remote control: paused while no window is open".to_string());
    }
    let n = match who_json() {
        Value::Array(a) => a.len(),
        _ => 0,
    };
    let where_ = if bind_addr(&config) == "0.0.0.0" { "the network" } else { "this machine" };
    Some(match n {
        0 => format!("Remote control: on, reachable from {where_}"),
        1 => format!("Remote control: 1 connected, from {where_}"),
        _ => format!("Remote control: {n} connected, from {where_}"),
    })
}

/// Who is connected, as far as anything here can honestly say.
///
/// The token is the only credential, so this cannot name a person and
/// must not pretend to. What it can say is what the connection itself
/// shows: the address it came from, what the browser said it is, when it
/// arrived, which session it is watching, and whether it has typed. That
/// is enough to answer the question somebody actually asks when they see
/// the badge light up, which is "is that me on my phone, or not".
#[derive(Clone)]
struct Viewer {
    id: u64,
    addr: String,
    agent: String,
    since_ms: u64,
    last_ms: u64,
    session: Option<u32>,
    typed: u32,
}

static VIEWERS: Mutex<Vec<Viewer>> = Mutex::new(Vec::new());

/// Refused attempts, kept separately and deliberately.
///
/// A wrong token is the one thing here worth seeing after the fact: on a
/// loopback bind it means something on this machine is probing the port,
/// and on a LAN bind it means something on the network is. Neither is
/// necessarily an attack and both are worth knowing about.
static REFUSED: Mutex<Option<(u64, String, u64)>> = Mutex::new(None);

fn viewer_join(addr: String, agent: String) -> u64 {
    let id = NEXT_VIEWER.fetch_add(1, Ordering::Relaxed);
    let now = now_ms();
    if let Ok(mut v) = VIEWERS.lock() {
        v.push(Viewer { id, addr, agent, since_ms: now, last_ms: now, session: None, typed: 0 });
    }
    id
}

fn viewer_update(id: u64, session: Option<u32>, typed: bool) {
    if let Ok(mut v) = VIEWERS.lock() {
        if let Some(e) = v.iter_mut().find(|e| e.id == id) {
            e.last_ms = now_ms();
            if session.is_some() {
                e.session = session;
            }
            if typed {
                e.typed += 1;
            }
        }
    }
}

fn viewer_leave(id: u64) {
    if let Ok(mut v) = VIEWERS.lock() {
        v.retain(|e| e.id != id);
    }
}

/// What a browser said it is, reduced to the part worth showing.
///
/// Kept short on purpose. A full user-agent string is a paragraph of
/// version numbers that tells the reader nothing they asked; "iPhone" or
/// "Windows" answers "is that me on my phone" in one word. It is also a
/// claim by the client rather than a fact, which is why the address is
/// shown next to it rather than instead of it.
pub fn device_from_agent(agent: &str) -> String {
    let a = agent.to_ascii_lowercase();
    for (needle, name) in [
        ("iphone", "iPhone"),
        ("ipad", "iPad"),
        ("android", "Android"),
        ("macintosh", "Mac"),
        ("mac os", "Mac"),
        ("windows", "Windows"),
        ("cros", "ChromeOS"),
        ("linux", "Linux"),
    ] {
        if a.contains(needle) {
            return name.to_string();
        }
    }
    if a.is_empty() {
        "unknown device".to_string()
    } else {
        "another device".to_string()
    }
}
static LAST_FAIL_MS: AtomicU64 = AtomicU64::new(0);

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

// ── configuration ──────────────────────────────────────────────────────

/// Whether the feature is on. Absent means off, and it has to: every
/// config.json written before this existed has no such key, and every one
/// of those machines must keep behaving exactly as it did.
pub fn enabled(config: &Value) -> bool {
    config.get("remote_enabled").and_then(Value::as_bool) == Some(true)
}

/// What the server binds to. Anything that is not literally the
/// LAN choice is loopback, so a typo, a truncated write, or a config
/// hand-edited to nonsense fails closed rather than open.
pub fn bind_addr(config: &Value) -> &'static str {
    match config.get("remote_bind").and_then(Value::as_str) {
        Some("lan") | Some("0.0.0.0") => "0.0.0.0",
        _ => "127.0.0.1",
    }
}

pub fn port(config: &Value) -> u16 {
    match config.get("remote_port").and_then(Value::as_u64) {
        // Below 1024 needs privileges this app does not have and should
        // not want; 0 would bind an arbitrary port, which cannot be
        // printed in settings before it exists.
        Some(p) if (1024..=65535).contains(&p) => p as u16,
        _ => DEFAULT_PORT,
    }
}

fn token_of(config: &Value) -> String {
    config
        .get("remote_token")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

/// Whether the page may type into a shell.
///
/// Read per request rather than captured when the server started, so
/// turning it off in settings takes effect on the next keystroke from the
/// phone rather than at the next restart. Watching a shell and driving
/// one are different risks and this is the switch between them.
fn input_allowed() -> bool {
    mux::read_config()
        .get("remote_input")
        .and_then(Value::as_bool)
        == Some(true)
}

// ── the secret ─────────────────────────────────────────────────────────

/// Crockford's alphabet minus the letters that are read as digits, so
/// that a token copied off a screen by eye cannot become a different
/// valid-looking token.
const ALPHABET: &[u8] = b"0123456789abcdefghjkmnpqrstvwxyz";

/// A fresh token: 160 bits, from the operating system's generator.
///
/// One random byte per character and only five of its bits used, rather
/// than packing the bits tightly. Packing would be a base32 encoder, and
/// an encoder written for one call site is a place for an off-by-one to
/// live; wasting three bits of a byte the OS gave away for free is not a
/// cost worth that.
///
/// Not from a hash of the time and the pid. That is the shape of every
/// "random" token that turned out to be guessable, and the whole security
/// of this feature is this string.
pub fn new_token() -> String {
    let mut bytes = [0u8; 32];
    fill_random(&mut bytes);
    bytes.iter().map(|b| ALPHABET[(b & 31) as usize] as char).collect()
}

#[cfg(windows)]
fn fill_random(out: &mut [u8]) {
    use windows_sys::Win32::Security::Cryptography::{
        BCryptGenRandom, BCRYPT_USE_SYSTEM_PREFERRED_RNG,
    };
    let status = unsafe {
        BCryptGenRandom(
            std::ptr::null_mut(),
            out.as_mut_ptr(),
            out.len() as u32,
            BCRYPT_USE_SYSTEM_PREFERRED_RNG,
        )
    };
    // A token that is quietly all zeroes is worse than no token, so a
    // refusal from the OS generator is fatal rather than papered over.
    assert!(status == 0, "the system random generator refused");
}

#[cfg(not(windows))]
fn fill_random(out: &mut [u8]) {
    let mut f = std::fs::File::open("/dev/urandom").expect("no system random generator");
    f.read_exact(out).expect("the system random generator refused");
}

/// Compare a presented secret against the real one without letting the
/// time taken say how much of it was right.
///
/// The loop runs over the length of the *expected* token whatever was
/// presented, so a caller learns nothing from the clock — not the length,
/// and not how many leading characters matched. An empty expected token
/// is a configuration state rather than a secret (it means "no token has
/// been generated yet"), and it matches nothing at all: without that
/// guard, a server with no token would admit a request with no token.
pub fn secret_eq(expected: &str, presented: &str) -> bool {
    if expected.is_empty() {
        return false;
    }
    let e = expected.as_bytes();
    let p = presented.as_bytes();
    let mut diff: u32 = (e.len() ^ p.len()) as u32;
    for (i, eb) in e.iter().enumerate() {
        let pb = if i < p.len() { p[i] } else { 0 };
        diff |= (eb ^ pb) as u32;
    }
    diff == 0
}

/// How long to sit on a wrong token before answering.
///
/// Deliberately a delay and not a lockout. A lockout on a shared counter
/// is a way for whoever is guessing to take the feature away from the
/// person who owns it: a phone that cannot connect because something else
/// on the network is knocking is a worse outcome than a slow guesser. The
/// token is 160 bits, so the delay is belt and braces over arithmetic
/// that already says forever — it exists so that a *short* token, if this
/// ever grows one, is not free to grind through.
pub fn auth_delay_ms(consecutive_failures: u32) -> u64 {
    250 * consecutive_failures.clamp(1, 8) as u64
}

fn punish_failure() {
    let now = now_ms();
    let last = LAST_FAIL_MS.swap(now, Ordering::Relaxed);
    // A quiet minute forgives: someone who mistyped once an hour ago
    // should not be waiting two seconds for it now.
    let fails = if now.saturating_sub(last) > 60_000 {
        FAILURES.store(1, Ordering::Relaxed);
        1
    } else {
        FAILURES.fetch_add(1, Ordering::Relaxed) + 1
    };
    std::thread::sleep(Duration::from_millis(auth_delay_ms(fails)));
}

// ── request parsing ────────────────────────────────────────────────────

pub struct Req {
    pub method: String,
    pub path: String,
    pub query: Vec<(String, String)>,
    pub headers: Vec<(String, String)>,
    pub body: String,
}

impl Req {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }
    pub fn param(&self, name: &str) -> Option<&str> {
        self.query
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'%' if i + 2 < b.len() => {
                let hex = std::str::from_utf8(&b[i + 1..i + 3]).unwrap_or("");
                match u8::from_str_radix(hex, 16) {
                    Ok(v) => {
                        out.push(v);
                        i += 3;
                    }
                    Err(_) => {
                        out.push(b[i]);
                        i += 1;
                    }
                }
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Split a request target into its path and its parameters.
///
/// The path is left exactly as it arrived, undecoded. Decoding it would
/// be the first half of a directory traversal — `%2e%2e%2f` becoming
/// `../` — and there is nothing to gain from it, because the routes are
/// an exact-match list and not a lookup into anything.
pub fn parse_target(target: &str) -> (String, Vec<(String, String)>) {
    let (path, qs) = match target.split_once('?') {
        Some((p, q)) => (p, q),
        None => (target, ""),
    };
    let mut query = Vec::new();
    for pair in qs.split('&').filter(|p| !p.is_empty()) {
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        query.push((percent_decode(k), percent_decode(v)));
    }
    (path.to_string(), query)
}

#[derive(Debug, PartialEq, Eq)]
pub enum Route {
    /// The page itself.
    Page,
    /// Every session the daemon holds.
    Sessions,
    /// One session's scrollback, once.
    Peek,
    /// One session's scrollback, and then everything after it.
    Stream,
    /// Type into a session.
    Input,
    /// The terminal engine the page renders with, carried in the binary.
    Engine,
    /// Its stylesheet.
    EngineCss,
    /// Ask to pair (pre-auth, when pairing is on): records a request and
    /// hands back a handle to poll and a code to read out to the desktop.
    PairStart,
    /// Poll a pairing (pre-auth): waiting, rejected, or approved - and only
    /// then carrying the token the device may connect with.
    PairStatus,
    NotFound,
}

/// Which handler answers a request.
///
/// Exact matches only, and no normalising step before the match. There is
/// no prefix here that maps onto a directory, so `/../../x` and
/// `/api/sessions/../../x` are simply not routes — they fall through to
/// the same 404 as `/wp-login.php`.
pub fn route(method: &str, path: &str) -> Route {
    match (method, path) {
        ("GET", "/") => Route::Page,
        ("GET", "/api/sessions") => Route::Sessions,
        ("GET", "/api/peek") => Route::Peek,
        ("GET", "/api/stream") => Route::Stream,
        ("POST", "/api/input") => Route::Input,
        ("GET", "/xterm.js") => Route::Engine,
        ("GET", "/xterm.css") => Route::EngineCss,
        ("POST", "/pair/start") => Route::PairStart,
        ("GET", "/pair/status") => Route::PairStatus,
        _ => Route::NotFound,
    }
}

/// The secret a request presented, from wherever it could have put it.
///
/// Three places because three kinds of request need it. `fetch` can set a
/// header; `EventSource` cannot set anything, so a stream has to carry it
/// in the query; and the very first page load is a URL somebody opened on
/// a phone, which is a query string too. The page drops the token out of
/// the address bar as soon as it has read it.
pub fn presented_token(req: &Req) -> String {
    if let Some(v) = req.header("authorization") {
        if let Some(rest) = v.strip_prefix("Bearer ").or_else(|| v.strip_prefix("bearer ")) {
            return rest.trim().to_string();
        }
    }
    if let Some(v) = req.header("x-gterminal-token") {
        return v.trim().to_string();
    }
    req.param("t").unwrap_or_default().to_string()
}

fn read_request(reader: &mut BufReader<Conn>) -> Option<Req> {
    let mut line = String::new();
    if reader.read_line(&mut line).ok()? == 0 {
        return None;
    }
    let mut parts = line.trim_end().split(' ');
    let method = parts.next()?.to_string();
    let target = parts.next()?.to_string();
    let (path, query) = parse_target(&target);

    let mut headers = Vec::new();
    let mut consumed = line.len();
    loop {
        let mut h = String::new();
        if reader.read_line(&mut h).ok()? == 0 {
            break;
        }
        consumed += h.len();
        if consumed > MAX_HEADER_BYTES {
            return None;
        }
        let h = h.trim_end();
        if h.is_empty() {
            break;
        }
        if let Some((k, v)) = h.split_once(':') {
            headers.push((k.trim().to_ascii_lowercase(), v.trim().to_string()));
        }
    }

    let len: usize = headers
        .iter()
        .find(|(k, _)| k == "content-length")
        .and_then(|(_, v)| v.parse().ok())
        .unwrap_or(0);
    let mut body = String::new();
    if len > 0 {
        if len > MAX_BODY_BYTES {
            return None;
        }
        let mut buf = vec![0u8; len];
        reader.read_exact(&mut buf).ok()?;
        body = String::from_utf8_lossy(&buf).into_owned();
    }

    Some(Req { method, path, query, headers, body })
}

// ── responses ──────────────────────────────────────────────────────────

/// The headers every answer carries.
///
/// `no-referrer` is not decoration: the first URL a phone opens has the
/// token in it, and a `Referer` header is how a token in a URL ends up in
/// somebody else's logs. The CSP is there because the page is entirely
/// inline and has no business reaching anything — `default-src 'none'`
/// means that if this file is ever wrong about what it serves, the
/// browser will not fetch whatever it was told to.
const COMMON_HEADERS: &str = "Cache-Control: no-store\r\n\
     X-Content-Type-Options: nosniff\r\n\
     Referrer-Policy: no-referrer\r\n\
     Content-Security-Policy: default-src 'none'; style-src 'self' 'unsafe-inline'; \
     script-src 'self' 'unsafe-inline'; img-src data:; connect-src 'self'; form-action 'none'; \
     frame-ancestors 'none'\r\n";

fn respond(out: &mut Conn, status: &str, content_type: &str, body: &str) {
    let head = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\n{COMMON_HEADERS}Connection: close\r\n\r\n",
        body.len()
    );
    let _ = out.write_all(head.as_bytes());
    let _ = out.write_all(body.as_bytes());
    let _ = out.flush();
}

fn respond_json(out: &mut Conn, status: &str, body: &Value) {
    respond(out, status, "application/json; charset=utf-8", &body.to_string());
}

// ── talking to the daemon ──────────────────────────────────────────────

/// One request to the session daemon.
///
/// `connect`, never `ensure`: a phone asking what sessions exist must not
/// be able to start a daemon on a machine that has none running. That is
/// a state change, and nothing reachable from the network gets to make
/// one that was not asked for.
fn daemon(req: &Request) -> Result<Value, String> {
    let stream = mux::client::connect().map_err(|_| "no session daemon is running".to_string())?;
    mux::client::request(stream, req)
}

fn sessions_json() -> Value {
    // `can_type` rides along with the list because the page has to know
    // which half of its bottom bar to draw, and asking twice for one
    // boolean is a second round trip over a tunnel.
    let can_type = input_allowed();
    match daemon(&Request::List) {
        Ok(v) => json!({
            "sessions": v.get("sessions").cloned().unwrap_or(json!([])),
            "can_type": can_type,
        }),
        Err(e) => json!({ "sessions": [], "can_type": can_type, "error": e }),
    }
}

fn peek_text(id: u32) -> Result<String, String> {
    daemon(&Request::Peek { id }).map(|v| {
        v.get("data")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string()
    })
}

// ── the server ─────────────────────────────────────────────────────────

// ---- Approve-on-desktop pairing ----------------------------------------
//
// The token is the credential; typing it into a phone is the friction this
// removes. A device with no token asks to pair, and is shown nothing but a
// short code. The desktop - the machine that already holds the shells - is
// where that request is approved, against the same code, by the one person
// who should. Approval hands the device the token it would have typed, so
// nothing a connection may do changes: this is a safer way to deliver the
// token, not a second kind of key. Off unless asked for (remote_pairing).
//
// The handle a device polls with is a random secret, not a sequence, so
// polling another device's approved pairing is not a way in; the code is
// only the human check that the device asking is the one in the hand of
// whoever approves it.

#[derive(Clone, Copy, PartialEq, Debug)]
enum PairState {
    Waiting,
    Approved,
    Rejected,
}

struct Pending {
    id: String,
    code: String,
    created_ms: u64,
    state: PairState,
    device: String,
    /// The address the request came from. This is the anti-nuisance key:
    /// every limit below is per-IP, because the thing being defended
    /// against is one device asking over and over, not many devices asking
    /// once. On a loopback bind every request is 127.0.0.1, which is fine -
    /// there it is one machine and the limits still bound its prompts.
    ip: String,
    /// When a decision was made, if one has been. Used to hold a denied
    /// request in its cooldown even after its creation TTL would drop it,
    /// so "deny then ask again immediately" cannot get past the cooldown.
    decided_ms: Option<u64>,
}

static PENDING: Mutex<Vec<Pending>> = Mutex::new(Vec::new());

/// A waiting request lives this long - long enough to walk to the desktop
/// and read the code, short enough that one left unanswered does not linger.
const PAIR_TTL_MS: u64 = 3 * 60 * 1000;
/// The most requests that may wait at once across everything, so no number
/// of devices can bury the desktop in prompts.
const MAX_PENDING: usize = 12;
/// The most one address may have waiting at once. Low, because a person
/// pairing a phone needs one; the room above that is for a fat-fingered
/// retry, not for a device that has decided to be a nuisance.
const MAX_PENDING_PER_IP: usize = 3;
/// After the desktop says no, that address cannot ask again for this long.
/// This is the answer to "they just re-pair and annoy me": a denial is not
/// a thing they can undo by clicking again, it costs them a minute.
const PAIR_DENY_COOLDOWN_MS: u64 = 60 * 1000;

fn pairing_enabled(config: &Value) -> bool {
    config
        .get("remote_pairing")
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

/// Whether a record still earns its place in the list at `now`: either it
/// is within its creation TTL, or it was denied recently enough that its
/// cooldown is still running and dropping it would forget the denial. Pure
/// in `now` so the pruning can be checked without waiting for a clock.
fn pending_is_live(p: &Pending, now: u64) -> bool {
    if now.saturating_sub(p.created_ms) < PAIR_TTL_MS {
        return true;
    }
    matches!((p.state, p.decided_ms), (PairState::Rejected, Some(d))
        if now.saturating_sub(d) < PAIR_DENY_COOLDOWN_MS)
}

fn prune_at(list: &mut Vec<Pending>, now: u64) {
    list.retain(|p| pending_is_live(p, now));
}

fn prune_pending(list: &mut Vec<Pending>) {
    prune_at(list, now_ms());
}

/// Why an address may not start a pairing right now, or None if it may.
/// Split out and pure in `now` so every branch is testable with a crafted
/// list rather than by hammering the real one against a real clock.
fn start_refusal(list: &[Pending], ip: &str, now: u64) -> Option<&'static str> {
    // The global ceiling: enough devices, each within its own limit, could
    // still add up to a wall of prompts, so there is a hard cap over all.
    if list.iter().filter(|p| p.state == PairState::Waiting).count() >= MAX_PENDING {
        return Some("too many pairings are waiting");
    }
    // This address, still waiting on its earlier asks.
    if list
        .iter()
        .filter(|p| p.ip == ip && p.state == PairState::Waiting)
        .count()
        >= MAX_PENDING_PER_IP
    {
        return Some("this device already has a request waiting");
    }
    // This address, told no within the cooldown.
    if list.iter().any(|p| {
        p.ip == ip
            && p.state == PairState::Rejected
            && p.decided_ms
                .is_some_and(|d| now.saturating_sub(d) < PAIR_DENY_COOLDOWN_MS)
    }) {
        return Some("this device was just turned away; try again shortly");
    }
    None
}

/// The unguessable handle a device polls with. Random, so it cannot be
/// walked; it never appears on a screen.
fn pair_id() -> String {
    let mut b = [0u8; 16];
    fill_random(&mut b);
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// The six digits shown on both screens. A person reads them to confirm the
/// device asking is theirs; it is not a secret - the token behind it is.
fn pair_code() -> String {
    let mut b = [0u8; 4];
    fill_random(&mut b);
    format!("{:06}", u32::from_le_bytes(b) % 1_000_000)
}

/// Start a pairing from `ip`: record it, return the handle to poll and the
/// code to show. None when a limit refuses it - too many waiting overall,
/// too many already waiting from this address, or this address is inside
/// the cooldown from a denial. The caller turns any None into one 429.
fn start_pair(device: String, ip: String) -> Option<(String, String)> {
    let mut list = PENDING.lock().ok()?;
    let now = now_ms();
    prune_at(&mut list, now);
    if start_refusal(&list, &ip, now).is_some() {
        return None;
    }
    let id = pair_id();
    let code = pair_code();
    list.push(Pending {
        id: id.clone(),
        code: code.clone(),
        created_ms: now,
        state: PairState::Waiting,
        device,
        ip,
        decided_ms: None,
    });
    Some((id, code))
}

fn pair_state(id: &str) -> Option<PairState> {
    let mut list = PENDING.lock().ok()?;
    prune_pending(&mut list);
    list.iter().find(|p| p.id == id).map(|p| p.state)
}

fn set_pair_state(id: &str, state: PairState) -> bool {
    let Ok(mut list) = PENDING.lock() else {
        return false;
    };
    match list.iter_mut().find(|p| p.id == id && p.state == PairState::Waiting) {
        Some(p) => {
            p.state = state;
            // Stamped so a denial's cooldown is measured from the decision,
            // not from when the request first arrived.
            p.decided_ms = Some(now_ms());
            true
        }
        None => false,
    }
}

/// The requests still waiting, for the desktop to show. Handle, code and
/// device only - never a token, which is not decided until approval.
pub fn pending_pairs() -> Vec<Value> {
    let Ok(mut list) = PENDING.lock() else {
        return Vec::new();
    };
    prune_pending(&mut list);
    list.iter()
        .filter(|p| p.state == PairState::Waiting)
        .map(|p| json!({ "id": p.id, "code": p.code, "device": p.device, "at_ms": p.created_ms }))
        .collect()
}

pub fn approve_pair(id: &str) -> bool {
    set_pair_state(id, PairState::Approved)
}

pub fn reject_pair(id: &str) -> bool {
    set_pair_state(id, PairState::Rejected)
}

struct Ctx {
    token: Arc<String>,
    generation: u64,
    pairing: bool,
}

/// One accepted connection, HTTPS or plain. Remote control speaks TLS by
/// default; the `remote_tls: false` escape hatch drops to plain HTTP for
/// someone who already has TLS in front (a reverse proxy) or who cannot
/// get a self-signed cert past their client. The whole server is written
/// once against this, and neither the request parser nor the responders
/// know which they hold.
///
/// A TLS stream cannot be `try_clone`d — the cipher state is one shared
/// thing — so, unlike the old plain-only server, there is a single stream
/// per connection: read through a `BufReader`, written through the same
/// handle. That is safe here because a response is written only after the
/// request is fully read, and a live event stream only ever writes, so
/// the two directions are never in flight at once.
enum Conn {
    Plain(TcpStream),
    Tls(Box<StreamOwned<ServerConnection, TcpStream>>),
}

impl Conn {
    fn inner(&self) -> &TcpStream {
        match self {
            Conn::Plain(s) => s,
            Conn::Tls(s) => &s.sock,
        }
    }
    fn peer_ip(&self) -> String {
        self.inner()
            .peer_addr()
            .map(|a| a.ip().to_string())
            .unwrap_or_else(|_| "unknown address".to_string())
    }
}

impl Read for Conn {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        match self {
            Conn::Plain(s) => s.read(buf),
            Conn::Tls(s) => s.read(buf),
        }
    }
}

impl Write for Conn {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        match self {
            Conn::Plain(s) => s.write(buf),
            Conn::Tls(s) => s.write(buf),
        }
    }
    fn flush(&mut self) -> std::io::Result<()> {
        match self {
            Conn::Plain(s) => s.flush(),
            Conn::Tls(s) => s.flush(),
        }
    }
}

/// The TLS server config, built once from a self-signed certificate that
/// is generated on first use and kept. Returns `None` only if the cert
/// can neither be read nor made — sync treats that as "cannot serve
/// HTTPS" rather than quietly dropping to plaintext, because a downgrade
/// to HTTP that the user did not choose is the one outcome worse than an
/// error message.
fn tls_config() -> Option<Arc<ServerConfig>> {
    static TLS: OnceLock<Option<Arc<ServerConfig>>> = OnceLock::new();
    TLS.get_or_init(build_tls_config).clone()
}

fn cert_paths() -> Option<(PathBuf, PathBuf)> {
    let base = PathBuf::from(std::env::var_os("LOCALAPPDATA")?).join("GTerminal");
    Some((base.join("remote-cert.pem"), base.join("remote-key.pem")))
}

fn build_tls_config() -> Option<Arc<ServerConfig>> {
    let (cert_path, key_path) = cert_paths()?;
    let (cert_pem, key_pem) = load_or_make_cert(&cert_path, &key_path)?;

    let certs: Vec<_> = rustls_pemfile::certs(&mut cert_pem.as_bytes())
        .collect::<Result<_, _>>()
        .ok()?;
    let key = rustls_pemfile::private_key(&mut key_pem.as_bytes()).ok()??;

    // The ring provider explicitly: it is the one already in the build
    // (ureq links it), so this does not pull a second crypto library, and
    // being explicit means the choice does not ride on a process-wide
    // default that some other crate might install first.
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let cfg = ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .ok()?
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .ok()?;
    Some(Arc::new(cfg))
}

/// Read the stored certificate, or make one and store it. A cert that
/// will not parse — a truncated write, a hand-edit — is replaced rather
/// than fought, so a bad file on disk cannot wedge the feature shut.
fn load_or_make_cert(cert_path: &Path, key_path: &Path) -> Option<(String, String)> {
    if let (Ok(c), Ok(k)) = (
        std::fs::read_to_string(cert_path),
        std::fs::read_to_string(key_path),
    ) {
        if c.contains("BEGIN CERTIFICATE") && k.contains("PRIVATE KEY") {
            return Some((c, k));
        }
    }
    let made = rcgen::generate_simple_self_signed(vec!["localhost".to_string()]).ok()?;
    let cert_pem = made.cert.pem();
    let key_pem = made.key_pair.serialize_pem();
    if let Some(dir) = cert_path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = std::fs::write(cert_path, &cert_pem);
    let _ = std::fs::write(key_path, &key_pem);
    Some((cert_pem, key_pem))
}

/// Wrap an accepted socket in the transport it will speak. With a config
/// present the connection is TLS; the handshake itself is lazy and
/// happens on the first read inside `serve`, under the timeouts already
/// set on the socket.
fn accept_conn(tcp: TcpStream, tls: Option<Arc<ServerConfig>>) -> Option<Conn> {
    match tls {
        None => Some(Conn::Plain(tcp)),
        Some(cfg) => {
            let conn = ServerConnection::new(cfg).ok()?;
            Some(Conn::Tls(Box::new(StreamOwned::new(conn, tcp))))
        }
    }
}

/// HTTPS unless the config explicitly says otherwise. Absent, null, or a
/// non-boolean all mean on — the fail-safe direction for a setting that
/// decides whether a shell is published in the clear.
fn tls_on(config: &Value) -> bool {
    config.get("remote_tls").and_then(Value::as_bool) != Some(false)
}

fn serve(stream: Conn, ctx: Arc<Ctx>) {
    let addr = stream.peer_ip();
    // A single stream now, read and written through one BufReader: a TLS
    // connection has no second clonable handle. The response is written
    // through `reader.get_mut()` once the request has been fully read.
    let mut reader = BufReader::new(stream);

    let Some(req) = read_request(&mut reader) else {
        respond(reader.get_mut(), "400 Bad Request", "text/plain; charset=utf-8", "bad request\n");
        return;
    };
    let out = reader.get_mut();

    let r = route(&req.method, &req.path);
    // Pairing is answered before the token gate - a device that has not
    // paired has no token to present - but only for these two routes and
    // only when it is switched on. /pair/start records a request and shows
    // the device a code; /pair/status returns the token only once the desktop
    // has approved that request, and only to the unguessable handle it was
    // given, so polling another pairing is not a way in.
    if ctx.pairing && (r == Route::PairStart || r == Route::PairStatus) {
        match r {
            Route::PairStart => {
                let device = device_from_agent(req.header("user-agent").unwrap_or_default());
                // The peer address is the limit key: it is what the anti-
                // nuisance caps in start_pair count against.
                match start_pair(device, addr.clone()) {
                    Some((id, code)) => {
                        respond_json(out, "200 OK", &json!({ "id": id, "code": code }))
                    }
                    // One 429 for every limit - global cap, per-IP cap, or
                    // denial cooldown - so a refusal never says which wall
                    // was hit or how close anything is to it.
                    None => respond_json(
                        out,
                        "429 Too Many Requests",
                        &json!({ "error": "too many pairing requests; wait a moment and try again" }),
                    ),
                }
            }
            Route::PairStatus => {
                let id = req.param("id").unwrap_or_default();
                match pair_state(id) {
                    Some(PairState::Approved) => respond_json(
                        out,
                        "200 OK",
                        &json!({ "state": "approved", "token": ctx.token.as_str() }),
                    ),
                    Some(PairState::Rejected) => {
                        respond_json(out, "200 OK", &json!({ "state": "rejected" }))
                    }
                    Some(PairState::Waiting) => {
                        respond_json(out, "200 OK", &json!({ "state": "waiting" }))
                    }
                    None => {
                        respond_json(out, "404 Not Found", &json!({ "error": "no such pairing" }))
                    }
                }
            }
            _ => {}
        }
        return;
    }

    if !secret_eq(&ctx.token, &presented_token(&req)) {
        punish_failure();
        if let Ok(mut r) = REFUSED.lock() {
            let n = r.as_ref().map(|(n, _, _)| *n).unwrap_or(0) + 1;
            *r = Some((n, addr.clone(), now_ms()));
        }
        // No hint about what was wrong with it, and nothing about the
        // token — neither the one expected nor the one presented — is
        // written anywhere, here or in a log line.
        respond(
            out,
            "401 Unauthorized",
            "text/plain; charset=utf-8",
            "GTerminal remote control: this link needs its access token.\n",
        );
        return;
    }
    FAILURES.store(0, Ordering::Relaxed);
    SERVED.fetch_add(1, Ordering::Relaxed);
    LAST_SERVED_MS.store(now_ms(), Ordering::Relaxed);
    // Every authorised request is a viewer for as long as it lasts, which
    // for a page load is a moment and for a stream is the whole visit.
    let who = viewer_join(addr, req.header("user-agent").unwrap_or_default().to_string());

    match r {
        Route::Page => respond(out, "200 OK", "text/html; charset=utf-8", PAGE),
        Route::Sessions => respond_json(out, "200 OK", &sessions_json()),
        Route::Peek => {
            let id = req.param("id").and_then(|s| s.parse::<u32>().ok());
            match id {
                Some(id) => match peek_text(id) {
                    Ok(text) => respond_json(out, "200 OK", &json!({"id": id, "text": text})),
                    Err(e) => respond_json(out, "404 Not Found", &json!({"error": e})),
                },
                None => respond_json(out, "400 Bad Request", &json!({"error": "no id"})),
            }
        }
        Route::Stream => stream_session(out, &req, &ctx, who),
        Route::Input => handle_input(out, &req, who),
        // Behind the token like everything else. There is nothing secret
        // in a copy of xterm.js, but a route that answers without one is
        // a route that says the server is here.
        Route::Engine => respond(out, "200 OK", "application/javascript; charset=utf-8", ENGINE_JS),
        Route::EngineCss => respond(out, "200 OK", "text/css; charset=utf-8", ENGINE_CSS),
        // Pairing routes are served pre-auth above when it is enabled; if
        // one reaches here, pairing is off, so it simply does not exist.
        Route::PairStart | Route::PairStatus | Route::NotFound => {
            respond(out, "404 Not Found", "text/plain; charset=utf-8", "no\n")
        }
    }
    viewer_leave(who);
}

/// Live output.
///
/// Server-sent events rather than long polling, for two reasons that both
/// come from this being a hand-written HTTP server with one thread per
/// connection. A long poll is a fresh request — and so a fresh connection
/// and a fresh thread — for every chunk of output, and a busy `cargo
/// build` produces chunks faster than a phone on a tunnel can re-handshake.
/// And the reconnect logic would have to be written twice, once here and
/// once in the page, where `EventSource` already does it: a phone that
/// sleeps for ten minutes comes back and reconnects by itself.
///
/// The cost is that `EventSource` cannot set a header, so the stream's
/// token travels in the query string. That is the same place the page
/// load's token was, so it is not a new exposure.
fn stream_session(out: &mut Conn, req: &Req, ctx: &Ctx, who: u64) {
    let id = req.param("id").and_then(|s| s.parse::<u32>().ok());
    let head = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\n{COMMON_HEADERS}Connection: close\r\n\r\n"
    );
    if out.write_all(head.as_bytes()).is_err() {
        return;
    }

    let mut last_list = String::new();
    let mut quiet_ms = 0u64;

    // Watch the session rather than re-reading its scrollback.
    //
    // Polling `peek` and diffing what came back was the first version of
    // this, and it cannot show a full-screen program at all: the ring
    // deliberately keeps none of a program that took over the screen,
    // because thousands of repaints are not scrollback anybody wants.
    // So launching an agent TUI on the desktop showed nothing here -
    // reported as "I tried launching Claude Code and it didn't render in
    // the web".
    //
    // `observe` is the daemon verb for this: every byte the pty
    // produces, repaints included, without attaching - attaching would
    // take the session out of the window on the desk.
    let mut watch = match id {
        Some(id) => match observe(id) {
            Ok(r) => Some(r),
            Err(e) => {
                let body = json!({"id": id, "error": e}).to_string();
                let _ = send_event(out, "gone", &body);
                None
            }
        },
        None => None,
    };

    loop {
        if GENERATION.load(Ordering::Relaxed) != ctx.generation {
            // The feature was turned off, or the token was regenerated.
            // Either way this stream is no longer authorised to exist.
            let _ = out.write_all(b"event: bye\ndata: {}\n\n");
            return;
        }

        viewer_update(who, id, false);
        let list = sessions_json().to_string();
        if list != last_list {
            last_list = list.clone();
            if send_event(out, "sessions", &list).is_err() {
                return;
            }
            quiet_ms = 0;
        }

        // Everything the session has said since the last turn round this
        // loop. The read below carries a timeout, so this returns whether
        // or not the shell is saying anything - the session list above
        // still has to be refreshed on a session that is silent.
        if let (Some(id), Some(w)) = (id, watch.as_mut()) {
            match w.drain() {
                Ok(chunks) => {
                    for (first, text) in chunks {
                        // The daemon's first line is everything it has:
                        // the scrollback, plus whatever a full-screen
                        // program is currently holding on the alternate
                        // screen. Sent as `replace` so the page draws it
                        // from nothing rather than appending it to the
                        // previous session's output.
                        let event = if first { "replace" } else { "data" };
                        if text.is_empty() && !first {
                            continue;
                        }
                        let body = json!({"id": id, "text": text}).to_string();
                        if send_event(out, event, &body).is_err() {
                            return;
                        }
                        quiet_ms = 0;
                    }
                }
                Err(e) => {
                    let body = json!({"id": id, "error": e}).to_string();
                    let _ = send_event(out, "gone", &body);
                    watch = None;
                }
            }
        } else {
            std::thread::sleep(Duration::from_millis(POLL_MS));
        }
        quiet_ms += POLL_MS;
        if quiet_ms >= KEEPALIVE_MS {
            quiet_ms = 0;
            if out.write_all(b": still here\n\n").is_err() {
                return;
            }
        }
    }
}

/// A connection to the daemon that is watching one session.
///
/// Its own connection, deliberately. `daemon()` opens one, asks one
/// question and closes it, which is right for everything else here and
/// useless for a subscription. The read carries a short timeout so the
/// stream loop keeps turning: the session list has to be refreshed even
/// while the shell says nothing at all.
struct Watch {
    sock: TcpStream,
    /// Bytes that have arrived but do not yet make a whole line.
    ///
    /// This has to survive between calls, and that is the whole reason
    /// the reading here is done by hand rather than with `read_line`. The
    /// read carries a timeout, and a timeout can land in the middle of a
    /// line - a full-screen program's repaint is tens of kilobytes on one
    /// line, which is several reads. `read_line` reports that as an error
    /// and the bytes it had already taken off the socket go with it, so
    /// every large repaint would arrive as unparseable JSON and be
    /// skipped. Which is how "it renders nothing" survives being fixed
    /// once already.
    buf: Vec<u8>,
    first: bool,
}

fn observe(id: u32) -> Result<Watch, String> {
    let stream = mux::client::connect().map_err(|_| "no session daemon is running".to_string())?;
    stream
        .set_read_timeout(Some(Duration::from_millis(POLL_MS)))
        .map_err(|e| e.to_string())?;
    let mut w = stream.try_clone().map_err(|e| e.to_string())?;
    // Through with_token: this is the first line of the connection, and
    // a first line without the daemon's token is one the daemon closes.
    let req = serde_json::to_vec(&mux::with_token(&Request::Observe { id }))
        .map_err(|e| e.to_string())?;
    w.write_all(&req).map_err(|e| e.to_string())?;
    w.write_all(b"\n").map_err(|e| e.to_string())?;
    w.flush().map_err(|e| e.to_string())?;
    let mut watch = Watch { sock: stream, buf: Vec::new(), first: true };
    // The daemon answers before it starts streaming, and the answer says
    // whether there was a session to watch at all.
    let reply = loop {
        match watch.next_line()? {
            Some(line) => break line,
            None => continue,
        }
    };
    let v: Value = serde_json::from_str(reply.trim()).map_err(|e| e.to_string())?;
    if v.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err(v
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("the daemon would not let that session be watched")
            .to_string());
    }
    Ok(watch)
}

impl Watch {
    /// Whatever has arrived, as (is_this_the_first, text) pairs.
    ///
    /// A read timeout is silence rather than a failure - the shell is
    /// simply not saying anything - and is the normal way out of here.
    fn drain(&mut self) -> Result<Vec<(bool, String)>, String> {
        let mut out = Vec::new();
        loop {
            let Some(line) = self.next_line()? else {
                return Ok(out);
            };
            let v: Value = match serde_json::from_str(line.trim()) {
                Ok(v) => v,
                Err(_) => continue,
            };
            match v.get("ev").and_then(Value::as_str) {
                Some("data") => {
                    let text = v.get("data").and_then(Value::as_str).unwrap_or_default().to_string();
                    let first = self.first;
                    self.first = false;
                    out.push((first, text));
                }
                // The session ended. Nothing more is coming down this
                // connection whatever happens next.
                Some("ended") => return Err("the session ended".to_string()),
                _ => {}
            }
            // Do not sit here draining a session that produces faster
            // than this can send: the caller has a keepalive and a
            // session list to attend to.
            if out.len() >= 64 {
                return Ok(out);
            }
        }
    }

    /// One whole line, or `None` when the socket has gone quiet.
    ///
    /// A timeout is not an error here: it is what a shell that is not
    /// saying anything looks like. Whatever arrived before it stays in
    /// the buffer for next time.
    fn next_line(&mut self) -> Result<Option<String>, String> {
        loop {
            if let Some(at) = self.buf.iter().position(|&b| b == b'\n') {
                let line: Vec<u8> = self.buf.drain(..=at).collect();
                return Ok(Some(String::from_utf8_lossy(&line).into_owned()));
            }
            let mut chunk = [0u8; 16 * 1024];
            match self.sock.read(&mut chunk) {
                Ok(0) => return Err("the session ended".to_string()),
                Ok(n) => self.buf.extend_from_slice(&chunk[..n]),
                Err(e)
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::TimedOut =>
                {
                    return Ok(None)
                }
                Err(e) => return Err(e.to_string()),
            }
        }
    }
}

fn send_event(out: &mut Conn, event: &str, data: &str) -> std::io::Result<()> {
    // The payload is always one line of JSON, so it never needs splitting
    // across several `data:` lines — but a stray newline in it would end
    // the event early and the page would see truncated JSON, so this
    // asserts the shape rather than assuming it.
    let one_line = data.replace('\n', " ");
    out.write_all(format!("event: {event}\ndata: {one_line}\n\n").as_bytes())?;
    out.flush()
}

/// Typing from the phone.
///
/// Separate from watching, and off unless it was separately turned on: a
/// browser tab that can *see* your shell and one that can *drive* it are
/// different things to have published, and the second should never arrive
/// as a side effect of wanting the first.
fn handle_input(out: &mut Conn, req: &Req, who: u64) {
    if !input_allowed() {
        respond_json(
            out,
            "403 Forbidden",
            &json!({"error": "input is off — turn it on in the desktop app"}),
        );
        return;
    }
    let Ok(body) = serde_json::from_str::<Value>(&req.body) else {
        respond_json(out, "400 Bad Request", &json!({"error": "bad body"}));
        return;
    };
    let Some(id) = body.get("id").and_then(Value::as_u64) else {
        respond_json(out, "400 Bad Request", &json!({"error": "no id"}));
        return;
    };
    let data = body.get("data").and_then(Value::as_str).unwrap_or_default();
    match daemon(&Request::Send { id: id as u32, data: data.to_string() }) {
        Ok(_) => {
            viewer_update(who, Some(id as u32), true);
            respond_json(out, "200 OK", &json!({"ok": true}))
        }
        Err(e) => respond_json(out, "409 Conflict", &json!({"error": e})),
    }
}

// ── starting and stopping ──────────────────────────────────────────────

/// Make the running state match the config, and say what it ended up as.
///
/// Idempotent and always safe to call: the generation bump stops whatever
/// was running before anything new is bound, so a rebind, a new token and
/// a plain "off" all take the same path and none of them can leave two
/// listeners up.
pub fn sync(config: &Value) -> Value {
    let generation = GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    RUNNING_PORT.store(0, Ordering::SeqCst);

    if !enabled(config) {
        return status();
    }
    // Enabled, but there is no window to carry the warning. See WINDOWS.
    if !windows_open() {
        return json!({
            "running": false,
            "paused": true,
            "port": port(config),
            "bind": bind_addr(config),
            "tls": tls_on(config),
            "hosts": [],
        });
    }
    let token = token_of(config);
    if token.is_empty() {
        // Enabled with no token is not a thing that should be servable.
        // It would be a shell on a port with no lock at all.
        return json!({
            "running": false,
            "error": "no access token — generate one first",
            "port": port(config),
            "bind": bind_addr(config),
            "tls": tls_on(config),
            "hosts": [],
        });
    }
    let bind = bind_addr(config);
    let p = port(config);
    // HTTPS by default. The one way to serve plaintext is to ask for it
    // (`remote_tls: false`), for someone who already terminates TLS in
    // front or whose client will not take a self-signed cert. If HTTPS is
    // wanted but the certificate can be neither read nor made, say so and
    // start nothing — a silent drop to HTTP would publish a shell in the
    // clear that the user believed was encrypted.
    let secure = tls_on(config);
    let tls = if secure {
        match tls_config() {
            Some(cfg) => Some(cfg),
            None => {
                return json!({
                    "running": false,
                    "error": "could not prepare the HTTPS certificate — turn off \"Encrypt with HTTPS\" to serve without it",
                    "port": p,
                    "bind": bind,
                    "tls": true,
                    "hosts": [],
                })
            }
        }
    } else {
        None
    };
    // The previous generation's server is very likely still holding this
    // port. It stops at the top of its accept loop — which it reaches only
    // within its poll interval, then drops the listener — so a config change
    // that comes straight back through here (even one that needed no
    // restart, like flipping read-only to typing) would race that release
    // and fail to bind. That failure read as the address, the QR and the
    // links all vanishing and the page going unreachable for a moment. So
    // give the outgoing server time to let go rather than binding into its
    // face; this runs off the UI thread, so the short wait costs nothing
    // that is felt.
    let mut bound = TcpListener::bind((bind, p));
    let deadline = std::time::Instant::now() + Duration::from_millis(700);
    while bound.is_err() && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(30));
        bound = TcpListener::bind((bind, p));
    }
    let listener = match bound {
        Ok(l) => l,
        Err(e) => {
            return json!({
                "running": false,
                "error": format!("could not listen on {bind}:{p} — {e}"),
                "port": p,
                "bind": bind,
                "tls": secure,
                "hosts": [],
            })
        }
    };
    // Non-blocking with a short nap rather than a blocking accept woken
    // by a connection to itself. The self-connect trick has to reach the
    // socket it is trying to close, which on a machine whose firewall or
    // loopback is in an odd state is exactly the machine where "turn it
    // off" must not hang.
    let _ = listener.set_nonblocking(true);
    let ctx = Arc::new(Ctx {
        token: Arc::new(token),
        generation,
        pairing: pairing_enabled(config),
    });

    std::thread::spawn(move || {
        loop {
            if GENERATION.load(Ordering::SeqCst) != generation {
                return;
            }
            match listener.accept() {
                Ok((tcp, _peer)) => {
                    if LIVE_CONNS.load(Ordering::Relaxed) >= MAX_CONNS {
                        drop(tcp);
                        continue;
                    }
                    LIVE_CONNS.fetch_add(1, Ordering::Relaxed);
                    let ctx = ctx.clone();
                    let tls = tls.clone();
                    std::thread::spawn(move || {
                        // The listener is non-blocking so the accept loop
                        // can poll the generation and let go on "turn it
                        // off"; on Windows the accepted socket inherits that
                        // flag. A blocking read is exactly what the rest
                        // wants — a TLS handshake is several round trips, and
                        // a non-blocking read returns WouldBlock the instant
                        // it waits for the client's next flight, which reads
                        // as a broken request and kills the handshake. So put
                        // this socket back to blocking, then bound it with a
                        // timeout: a client that opens and says nothing, or
                        // stalls mid-handshake, still cannot hold the thread.
                        let _ = tcp.set_nonblocking(false);
                        let _ = tcp.set_nodelay(true);
                        let _ = tcp.set_read_timeout(Some(Duration::from_secs(20)));
                        let _ = tcp.set_write_timeout(Some(Duration::from_secs(20)));
                        if let Some(conn) = accept_conn(tcp, tls) {
                            serve(conn, ctx);
                        }
                        LIVE_CONNS.fetch_sub(1, Ordering::Relaxed);
                    });
                }
                Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(150));
                }
                Err(_) => return,
            }
        }
    });
    RUNNING_TLS.store(secure, Ordering::SeqCst);
    RUNNING_PORT.store(p as u32, Ordering::SeqCst);
    status_for(bind, p)
}

/// Addresses worth printing next to the link.
///
/// Resolved from the machine's own name rather than by walking adapters,
/// which would be a pile of Win32 for one line of settings text. It gets
/// the LAN address right, and it gets a WireGuard address right whenever
/// the tunnel's interface is one the resolver answers for — and when it
/// does not, the settings page still says the port, which is the part
/// nobody can guess.
fn lan_hosts() -> Vec<String> {
    let name = std::env::var("COMPUTERNAME").unwrap_or_default();
    if name.is_empty() {
        return Vec::new();
    }
    let mut out: Vec<String> = Vec::new();
    if let Ok(addrs) = format!("{name}:0").to_socket_addrs() {
        for a in addrs {
            if a.is_ipv4() && !a.ip().is_loopback() {
                let s = a.ip().to_string();
                if !out.contains(&s) {
                    out.push(s);
                }
            }
        }
    }
    out
}

fn status_for(bind: &str, p: u16) -> Value {
    let who = match who_json() {
        Value::Array(a) => a,
        _ => Vec::new(),
    };
    let hosts = if bind == "0.0.0.0" {
        let mut h = lan_hosts();
        h.push("127.0.0.1".to_string());
        h
    } else {
        vec!["127.0.0.1".to_string()]
    };
    json!({
        "running": true,
        "port": p,
        "bind": bind,
        // The scheme the links must use. A phone opening http:// against
        // a TLS port is the "bad request" this whole change exists to end.
        "tls": RUNNING_TLS.load(Ordering::SeqCst),
        "hosts": hosts,
        // What the window shows. `viewers` counts connections that are
        // open now, which for this page means a phone with the stream
        // up; `served` and `last_ms` cover the case where somebody read
        // it and put the phone down, because "nobody is connected right
        // now" is not the same as "nobody has been".
        // The count is the length of the list beside it, not the number
        // of open sockets. A phone loading the page holds two - the page
        // and its stream - and a badge reading "2 watching" next to one
        // device is the kind of small lie that makes people stop
        // believing the badge.
        "viewers": who.len(),
        "served": SERVED.load(Ordering::Relaxed),
        "last_ms": LAST_SERVED_MS.load(Ordering::Relaxed),
        "who": Value::Array(who),
        "refused": refused_json(),
    })
}

/// The connections, as records the window can render.
///
/// Page loads come and go in a moment and would flicker through this
/// list, so only connections that have been there long enough to be
/// worth mentioning are listed - which in practice means the streams,
/// because a stream is what somebody watching actually holds open.
fn who_json() -> Value {
    let now = now_ms();
    let Ok(v) = VIEWERS.lock() else { return json!([]) };
    let list: Vec<Value> = v
        .iter()
        .filter(|e| now.saturating_sub(e.since_ms) >= 1000 || e.session.is_some())
        .map(|e| {
            json!({
                "addr": e.addr,
                "device": device_from_agent(&e.agent),
                "since_ms": e.since_ms,
                "last_ms": e.last_ms,
                "session": e.session,
                "typed": e.typed,
            })
        })
        .collect();
    json!(list)
}

fn refused_json() -> Value {
    match REFUSED.lock() {
        Ok(r) => match r.as_ref() {
            Some((n, addr, at)) => json!({"count": n, "addr": addr, "last_ms": at}),
            None => Value::Null,
        },
        Err(_) => Value::Null,
    }
}

pub fn status() -> Value {
    let p = RUNNING_PORT.load(Ordering::SeqCst);
    if p == 0 {
        let config = mux::read_config();
        return json!({
            "running": false,
            "paused": enabled(&config) && !windows_open(),
            "port": port(&config),
            "bind": bind_addr(&config),
            "tls": tls_on(&config),
            "hosts": [],
            "viewers": 0,
            "served": SERVED.load(Ordering::Relaxed),
            "last_ms": LAST_SERVED_MS.load(Ordering::Relaxed),
            "who": json!([]),
            "refused": refused_json(),
        });
    }
    status_for(bind_addr(&mux::read_config()), p as u16)
}

#[cfg(test)]
mod remote_tests {
    use super::*;

    /// A client-side verifier that accepts the server's self-signed cert
    /// without checking it — the "trust this certificate" a phone taps
    /// once, expressed in code so a test handshake completes. It is only
    /// ever built inside a test; it lets the handshake succeed so the
    /// token gate on the other side is what the test actually measures.
    #[derive(Debug)]
    struct AcceptAnyCert;
    impl rustls::client::danger::ServerCertVerifier for AcceptAnyCert {
        fn verify_server_cert(
            &self,
            _end_entity: &rustls::pki_types::CertificateDer<'_>,
            _intermediates: &[rustls::pki_types::CertificateDer<'_>],
            _server_name: &rustls::pki_types::ServerName<'_>,
            _ocsp: &[u8],
            _now: rustls::pki_types::UnixTime,
        ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
            Ok(rustls::client::danger::ServerCertVerified::assertion())
        }
        fn verify_tls12_signature(
            &self,
            _message: &[u8],
            _cert: &rustls::pki_types::CertificateDer<'_>,
            _dss: &rustls::DigitallySignedStruct,
        ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
            Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
        }
        fn verify_tls13_signature(
            &self,
            _message: &[u8],
            _cert: &rustls::pki_types::CertificateDer<'_>,
            _dss: &rustls::DigitallySignedStruct,
        ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
            Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
        }
        fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
            rustls::crypto::ring::default_provider()
                .signature_verification_algorithms
                .supported_schemes()
        }
    }

    /// The one that decides whether an existing install changes
    /// behaviour. Every config.json written before this feature existed
    /// looks like the first case, and every one of those machines must
    /// keep opening no socket at all.
    #[test]
    fn a_config_that_has_never_heard_of_this_is_off() {
        assert!(!enabled(&json!({})));
        assert!(!enabled(&json!({"ui_log": "errors", "history_days": 14})));
        assert!(!enabled(&json!({"remote_enabled": false})));
        assert!(enabled(&json!({"remote_enabled": true})));
    }

    /// A truthy-looking string is not a yes. Config files get hand-edited
    /// and a feature that publishes a shell should not turn itself on for
    /// `"remote_enabled": "no"`.
    #[test]
    fn only_a_real_boolean_true_turns_it_on() {
        assert!(!enabled(&json!({"remote_enabled": "true"})));
        assert!(!enabled(&json!({"remote_enabled": 1})));
        assert!(!enabled(&json!({"remote_enabled": null})));
    }

    /// Binding wide is a deliberate choice, so anything that is not that
    /// choice has to come back as loopback — including nonsense, which is
    /// what a half-written config file looks like.
    #[test]
    fn the_bind_fails_closed() {
        assert_eq!(bind_addr(&json!({})), "127.0.0.1");
        assert_eq!(bind_addr(&json!({"remote_bind": "local"})), "127.0.0.1");
        assert_eq!(bind_addr(&json!({"remote_bind": "banana"})), "127.0.0.1");
        assert_eq!(bind_addr(&json!({"remote_bind": ""})), "127.0.0.1");
        assert_eq!(bind_addr(&json!({"remote_bind": "lan"})), "0.0.0.0");
        assert_eq!(bind_addr(&json!({"remote_bind": "0.0.0.0"})), "0.0.0.0");
    }

    #[test]
    fn a_port_out_of_range_falls_back_rather_than_binding_something_odd() {
        assert_eq!(port(&json!({})), DEFAULT_PORT);
        assert_eq!(port(&json!({"remote_port": 0})), DEFAULT_PORT);
        assert_eq!(port(&json!({"remote_port": 80})), DEFAULT_PORT);
        assert_eq!(port(&json!({"remote_port": 99999})), DEFAULT_PORT);
        assert_eq!(port(&json!({"remote_port": 9000})), 9000);
    }

    #[test]
    fn the_right_secret_is_accepted_and_nothing_else_is() {
        let t = "abcdefghijklmnopqrstuvwxyz123456";
        assert!(secret_eq(t, t));
        assert!(!secret_eq(t, "abcdefghijklmnopqrstuvwxyz123457"));
        assert!(!secret_eq(t, "abcdefghijklmnopqrstuvwxyz12345"));
        assert!(!secret_eq(t, "abcdefghijklmnopqrstuvwxyz1234567"));
        assert!(!secret_eq(t, ""));
        // A prefix of the real token is the thing a timing attack would
        // build up to, and it is still simply wrong.
        assert!(!secret_eq(t, "abcdefghij"));
    }

    /// A server with no token yet must not admit a request with no token.
    /// Empty against empty compares equal in every naive implementation,
    /// and that would be an unlocked shell on a port.
    #[test]
    fn an_absent_token_matches_nothing_including_absence() {
        assert!(!secret_eq("", ""));
        assert!(!secret_eq("", "anything"));
    }

    /// Not a timing measurement — those are too noisy to assert on — but
    /// the property the constant-time loop exists for: the work done is
    /// set by the expected token, not by what arrived.
    #[test]
    fn the_comparison_does_not_stop_early() {
        let t = "0123456789abcdef";
        // Differing in the first character and in the last must both come
        // back false, and the loop has no early return for either.
        assert!(!secret_eq(t, "x123456789abcdef"));
        assert!(!secret_eq(t, "0123456789abcdex"));
    }

    #[test]
    fn a_generated_token_is_long_and_not_the_same_twice() {
        let a = new_token();
        let b = new_token();
        assert_eq!(a.len(), 32, "32 characters of 32 symbols each — 160 bits");
        assert_ne!(a, b, "two tokens in a row were identical");
        assert!(a.bytes().all(|c| ALPHABET.contains(&c)), "unexpected character in {a}");
    }

    #[test]
    fn a_wrong_token_costs_more_the_more_often_it_is_wrong() {
        assert_eq!(auth_delay_ms(1), 250);
        assert_eq!(auth_delay_ms(4), 1000);
        // Capped: a delay that grows without limit is a way to hold every
        // thread this server has.
        assert_eq!(auth_delay_ms(8), 2000);
        assert_eq!(auth_delay_ms(1000), 2000);
        // Even a nonsensical zero waits, or a caller that never got as
        // far as counting would be free.
        assert_eq!(auth_delay_ms(0), 250);
    }

    #[test]
    fn the_routes_are_the_routes() {
        assert_eq!(route("GET", "/"), Route::Page);
        assert_eq!(route("GET", "/api/sessions"), Route::Sessions);
        assert_eq!(route("GET", "/api/peek"), Route::Peek);
        assert_eq!(route("GET", "/api/stream"), Route::Stream);
        assert_eq!(route("POST", "/api/input"), Route::Input);
    }

    /// The method is part of the route. Input is the one request that
    /// changes something, and `GET /api/input` would be reachable from a
    /// bare link — which is the shape of every cross-site request that
    /// ever did damage.
    #[test]
    fn typing_is_not_something_a_link_can_do() {
        assert_eq!(route("GET", "/api/input"), Route::NotFound);
        assert_eq!(route("HEAD", "/api/input"), Route::NotFound);
        assert_eq!(route("POST", "/api/sessions"), Route::NotFound);
    }

    /// Nothing here maps a path onto a file, and these are the paths that
    /// would have found out if something did.
    #[test]
    fn no_path_reaches_anything_on_disk() {
        for path in [
            "/../config.json",
            "/./",
            "//",
            "/api/sessions/../../../../config.json",
            "/%2e%2e/config.json",
            "/..%2fconfig.json",
            "/C:/Windows/win.ini",
            "/index.html",
        ] {
            assert_eq!(route("GET", path), Route::NotFound, "{path} was routed somewhere");
        }
    }

    fn req(headers: &[(&str, &str)], target: &str) -> Req {
        let (path, query) = parse_target(target);
        Req {
            method: "GET".into(),
            path,
            query,
            headers: headers
                .iter()
                .map(|(k, v)| (k.to_ascii_lowercase(), v.to_string()))
                .collect(),
            body: String::new(),
        }
    }

    #[test]
    fn the_token_is_found_wherever_a_client_can_put_it() {
        assert_eq!(presented_token(&req(&[("Authorization", "Bearer hunter2")], "/")), "hunter2");
        assert_eq!(presented_token(&req(&[("X-GTerminal-Token", "hunter2")], "/")), "hunter2");
        assert_eq!(presented_token(&req(&[], "/?t=hunter2")), "hunter2");
        assert_eq!(presented_token(&req(&[], "/api/stream?id=3&t=hunter2")), "hunter2");
        assert_eq!(presented_token(&req(&[], "/")), "");
    }

    /// A header beats the query string, because the page moves to headers
    /// as soon as it has read the token out of the URL — and a stale `t`
    /// left in a bookmark must not quietly override the current one.
    #[test]
    fn the_header_wins() {
        let r = req(&[("Authorization", "Bearer fromheader")], "/?t=fromquery");
        assert_eq!(presented_token(&r), "fromheader");
    }

    #[test]
    fn a_query_string_survives_the_trip() {
        let (path, q) = parse_target("/api/stream?id=7&t=a%20b");
        assert_eq!(path, "/api/stream");
        assert_eq!(q, vec![("id".to_string(), "7".to_string()), ("t".to_string(), "a b".to_string())]);
        let (path, q) = parse_target("/");
        assert_eq!(path, "/");
        assert!(q.is_empty());
    }

    /// The path is deliberately left encoded, so that a traversal written
    /// in percent-escapes stays a string that matches no route rather than
    /// becoming one that might.
    #[test]
    fn the_path_is_not_decoded_on_the_way_in() {
        let (path, _) = parse_target("/%2e%2e%2fconfig.json");
        assert_eq!(path, "/%2e%2e%2fconfig.json");
        assert_eq!(route("GET", &path), Route::NotFound);
    }

    /// What a browser calls itself, reduced to the one word somebody
    /// actually wants when the badge lights up.
    #[test]
    fn a_phone_is_named_as_a_phone() {
        let iphone = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15";
        assert_eq!(device_from_agent(iphone), "iPhone");
        let android = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36";
        assert_eq!(device_from_agent(android), "Android");
    }

    /// An iPad says "Mac OS X" too, and an Android says "Linux". Both are
    /// matched before the desktop names they contain, which is the whole
    /// reason the list is ordered rather than a map.
    #[test]
    fn the_devices_that_lie_about_themselves_are_matched_first() {
        let ipad = "Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15";
        assert_eq!(device_from_agent(ipad), "iPad");
        let mac = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36";
        assert_eq!(device_from_agent(mac), "Mac");
    }

    /// Something that sent no user-agent at all is not "another device",
    /// which would read as a guess. It is unknown, and says so.
    #[test]
    fn nothing_said_is_reported_as_nothing_known() {
        assert_eq!(device_from_agent(""), "unknown device");
        assert_eq!(device_from_agent("curl/8.4.0"), "another device");
    }

    /// The page is compiled in. If this is ever empty, the feature serves
    /// a blank screen and says nothing about why.
    #[test]
    fn the_page_is_embedded_in_the_binary() {
        assert!(PAGE.contains("GTerminal"), "the embedded page lost its name");
        assert!(PAGE.len() > 2000, "the embedded page is suspiciously small");
    }

    /// One raw socket, because everything above this only proves the
    /// pieces. The thing worth knowing is whether a request that arrives
    /// on the wire without the token is refused — which is a claim about
    /// `sync`, `serve`, `route` and `secret_eq` agreeing with each other,
    /// and no unit test of any one of them makes it.
    ///
    /// Loopback only. A test that binds 0.0.0.0 publishes a shell on
    /// whatever network the machine running the suite happens to be on,
    /// which is a thing a test has no business doing on a laptop or on a
    /// build agent.
    #[test]
    fn a_request_without_the_token_never_reaches_a_session() {
        let token = new_token();
        let mut chosen = 0u16;
        let mut reported = json!({});
        // A window has to exist before anything binds, which in a unit
        // test has to be said out loud: serving follows the window, so
        // that a port onto somebody's shells cannot be open while the
        // badge that warns about it is off screen. See WINDOWS.
        WINDOWS.store(1, Ordering::SeqCst);
        // A fixed port would collide with whatever else is on the machine
        // running this, and a random one cannot be printed in settings.
        // Walking a small range is the version that neither fails
        // spuriously nor hides a real bind failure.
        for candidate in 48731..48741u16 {
            reported = sync(&json!({
                "remote_enabled": true,
                "remote_bind": "local",
                "remote_port": candidate,
                "remote_token": token,
                // This test drives raw HTTP sockets by hand, so it asks for
                // the plaintext transport. HTTPS gets its own test with a
                // real handshake below.
                "remote_tls": false,
            }));
            if reported.get("running").and_then(Value::as_bool) == Some(true) {
                chosen = candidate;
                break;
            }
        }
        assert!(chosen != 0, "nothing ever bound: {reported}");

        // A settings change (flipping read-only to typing, say) re-syncs on
        // the same port while the previous generation's server is still
        // letting go of it. Before the bind retry that raced and came back
        // not-running, which read as the address, QR and links all
        // vanishing. Now the rebind waits for the outgoing server, so a
        // re-sync on the same port comes back running.
        let resync = sync(&json!({
            "remote_enabled": true,
            "remote_bind": "local",
            "remote_port": chosen,
            "remote_token": token,
            "remote_tls": false,
        }));
        assert_eq!(
            resync.get("running").and_then(Value::as_bool),
            Some(true),
            "a re-sync on the same port did not come back running — the rebind raced the outgoing server: {resync}"
        );

        let get = |target: &str, bearer: Option<&str>| -> String {
            let mut s = TcpStream::connect(("127.0.0.1", chosen)).expect("connect");
            s.set_read_timeout(Some(Duration::from_secs(10))).ok();
            let auth = match bearer {
                Some(b) => format!("Authorization: Bearer {b}\r\n"),
                None => String::new(),
            };
            s.write_all(format!("GET {target} HTTP/1.1\r\nHost: t\r\n{auth}\r\n").as_bytes())
                .expect("write");
            let mut out = String::new();
            let _ = s.read_to_string(&mut out);
            out
        };

        let bare = get("/", None);
        assert!(bare.starts_with("HTTP/1.1 401"), "a bare request was answered: {}", &bare[..bare.len().min(60)]);
        assert!(!bare.contains(&token), "the refusal leaked the token");

        let wrong = get("/", Some("0000000000000000000000000000000"));
        assert!(wrong.starts_with("HTTP/1.1 401"), "a wrong token was accepted");

        let good = get("/", Some(&token));
        assert!(good.starts_with("HTTP/1.1 200"), "the right token was refused");
        assert!(good.contains("GTerminal Pocket"), "the page was not what came back");
        // The header that keeps the token in the link out of somebody
        // else's logs. Worth asserting because nothing else would notice
        // it going missing.
        assert!(good.contains("Referrer-Policy: no-referrer"), "the referrer header is gone");

        // How a phone actually arrives: a link, with the token in it.
        let from_link = get(&format!("/?t={token}"), None);
        assert!(from_link.starts_with("HTTP/1.1 200"), "the link form was refused");

        // Authenticated and still not a file server.
        let traversal = get("/../Cargo.toml", Some(&token));
        assert!(traversal.starts_with("HTTP/1.1 404"), "a path walked out of the routes");

        // The session list answers whether or not a daemon is running:
        // with one it reports sessions, without one it reports the reason.
        // A route that only works on a developer's machine is a route
        // that fails the first time somebody opens the page with no
        // shells started yet.
        let listed = get("/api/sessions", Some(&token));
        assert!(listed.starts_with("HTTP/1.1 200"), "the session list was not answered");
        assert!(listed.contains("\"sessions\""), "the session list had no sessions key");
        assert!(listed.contains("\"can_type\""), "the page cannot tell which bottom bar to draw");

        // Typing is refused when input is off, which is the state every
        // config that has not deliberately said otherwise is in.
        let mut s = TcpStream::connect(("127.0.0.1", chosen)).expect("connect");
        s.set_read_timeout(Some(Duration::from_secs(10))).ok();
        let body = "{\"id\":1,\"data\":\"x\"}";
        s.write_all(
            format!(
                "POST /api/input HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer {token}\r\nContent-Length: {}\r\n\r\n{body}",
                body.len()
            )
            .as_bytes(),
        )
        .expect("write");
        let mut typed = String::new();
        let _ = s.read_to_string(&mut typed);
        // 403 when input is off, 200/409 when the machine running this
        // has turned it on for real. The one answer that would be a bug
        // is the request never being routed at all.
        assert!(!typed.starts_with("HTTP/1.1 404"), "input was not routed: {typed}");
        assert!(!typed.starts_with("HTTP/1.1 401"), "a good token was refused on input");

        // A phone browser doing "HTTPS-First" - the modern default - tries
        // TLS against a plain-HTTP port before falling back to http. The
        // server reads the TLS ClientHello, which is binary and not valid
        // UTF-8, fails to parse it as a request line, and answers 400. That
        // 400 is the "bad request" a phone shows on the plaintext escape
        // hatch; HTTPS (the default, exercised just below) is what stops it.
        // The behaviour is still worth pinning: a plaintext port must answer
        // a TLS probe cleanly, not hang or crash.
        let mut tls = TcpStream::connect(("127.0.0.1", chosen)).expect("connect");
        tls.set_read_timeout(Some(Duration::from_secs(10))).ok();
        // A TLS record header (0x16 handshake, 0x0301) and a ClientHello
        // prefix, then filler - the kind of bytes a browser opens TLS with.
        let mut hello = vec![0x16u8, 0x03, 0x01, 0x00, 0x30, 0x01, 0x00, 0x00, 0x2c, 0x03, 0x03];
        hello.extend(std::iter::repeat(0xAAu8).take(40));
        tls.write_all(&hello).expect("write");
        // Half-close, so the server's read reaches EOF and judges what it
        // has rather than waiting for a newline a handshake never sends.
        tls.shutdown(std::net::Shutdown::Write).ok();
        let mut tls_reply = String::new();
        let _ = tls.read_to_string(&mut tls_reply);
        assert!(
            tls_reply.starts_with("HTTP/1.1 400"),
            "TLS bytes on the HTTP port must read as a bad request - this is the phone's \"bad request\": {}",
            &tls_reply[..tls_reply.len().min(60)]
        );

        // ---- and now the real thing: HTTPS -----------------------------
        //
        // Flip the same server to TLS (the default; the plaintext runs
        // above only because this test drives raw sockets) and complete an
        // actual handshake, then prove the token gate holds over it exactly
        // as it did in the clear: no token is 401, the right token is 200.
        // A gate that only held on the plaintext path would be no gate at
        // all once HTTPS became the default a phone actually uses.
        let tls_report = sync(&json!({
            "remote_enabled": true,
            "remote_bind": "local",
            "remote_port": chosen,
            "remote_token": token,
            "remote_tls": true,
        }));
        assert_eq!(
            tls_report.get("running").and_then(Value::as_bool),
            Some(true),
            "the TLS server did not come up: {tls_report}"
        );
        assert_eq!(
            tls_report.get("tls").and_then(Value::as_bool),
            Some(true),
            "the status must say TLS so the page builds https:// links: {tls_report}"
        );

        // A client that accepts the self-signed cert — the phone's "trust
        // this certificate" tap, done in code so the handshake completes.
        let client_cfg = rustls::ClientConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .expect("client versions")
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(AcceptAnyCert))
        .with_no_client_auth();
        let name = rustls::pki_types::ServerName::try_from("localhost").expect("name");

        let https = |bearer: Option<&str>| -> String {
            let mut client =
                rustls::ClientConnection::new(Arc::new(client_cfg.clone()), name.clone())
                    .expect("client conn");
            let mut sock = TcpStream::connect(("127.0.0.1", chosen)).expect("connect");
            sock.set_read_timeout(Some(Duration::from_secs(10))).ok();
            let mut tls = rustls::Stream::new(&mut client, &mut sock);
            let auth = match bearer {
                Some(b) => format!("Authorization: Bearer {b}\r\n"),
                None => String::new(),
            };
            tls.write_all(format!("GET / HTTP/1.1\r\nHost: localhost\r\n{auth}\r\n").as_bytes())
                .expect("tls write");
            tls.flush().expect("tls flush");
            let mut out = Vec::new();
            // read_to_end returns an error on the server's unclean close
            // (no TLS close_notify), by which point the response is already
            // decoded into `out`; the status line is all this test reads.
            let _ = tls.read_to_end(&mut out);
            String::from_utf8_lossy(&out).into_owned()
        };

        let bare = https(None);
        assert!(
            bare.starts_with("HTTP/1.1 401"),
            "over HTTPS a request with no token was answered: {}",
            &bare[..bare.len().min(60)]
        );
        assert!(!bare.contains(&token), "the HTTPS refusal leaked the token");
        let good = https(Some(&token));
        assert!(
            good.starts_with("HTTP/1.1 200"),
            "over HTTPS the right token was refused: {}",
            &good[..good.len().min(60)]
        );
        assert!(good.contains("GTerminal Pocket"), "the page did not come back over HTTPS");

        // And off means off: the port has to actually close, or "turn it
        // off" is a label rather than a change.
        sync(&json!({}));
        let mut still_open = true;
        for _ in 0..40 {
            std::thread::sleep(Duration::from_millis(100));
            if TcpStream::connect(("127.0.0.1", chosen)).is_err() {
                still_open = false;
                break;
            }
        }
        assert!(!still_open, "the port stayed open after the feature was turned off");
    }

    // ---- pairing --------------------------------------------------------
    //
    // The pairing list is one process-wide static, so these tests share it.
    // A single lock held for the body of each makes them run one at a time
    // against it, and clearing it on the way in means each starts from
    // empty regardless of what ran before.
    static PAIR_SERIAL: Mutex<()> = Mutex::new(());

    fn clear_pending() {
        PENDING.lock().unwrap().clear();
    }

    /// A record built by hand, so the time-based limits can be checked at a
    /// chosen `now` instead of against the wall clock.
    fn pend(ip: &str, state: PairState, created_ms: u64, decided_ms: Option<u64>) -> Pending {
        Pending {
            id: pair_id(),
            code: pair_code(),
            created_ms,
            state,
            device: "iPhone".into(),
            ip: ip.into(),
            decided_ms,
        }
    }

    #[test]
    fn pairing_is_off_unless_a_real_true_asks_for_it() {
        assert!(!pairing_enabled(&json!({})));
        assert!(!pairing_enabled(&json!({"remote_pairing": false})));
        assert!(!pairing_enabled(&json!({"remote_pairing": "true"})));
        assert!(!pairing_enabled(&json!({"remote_pairing": 1})));
        assert!(pairing_enabled(&json!({"remote_pairing": true})));
    }

    #[test]
    fn the_pairing_routes_are_the_routes() {
        assert_eq!(route("POST", "/pair/start"), Route::PairStart);
        assert_eq!(route("GET", "/pair/status"), Route::PairStatus);
        // Method is part of it here too: starting a pairing changes state,
        // so a bare link must not be able to do it.
        assert_eq!(route("GET", "/pair/start"), Route::NotFound);
        assert_eq!(route("POST", "/pair/status"), Route::NotFound);
    }

    #[test]
    fn a_started_pairing_waits_then_is_handed_over_on_approval() {
        let _g = PAIR_SERIAL.lock().unwrap();
        clear_pending();

        let (id, code) = start_pair("iPhone".into(), "10.0.0.5".into())
            .expect("a first pairing should start");
        assert_eq!(id.len(), 32, "the handle is 16 random bytes in hex");
        assert_eq!(code.len(), 6, "the code is six digits");
        assert!(code.bytes().all(|b| b.is_ascii_digit()), "the code is not all digits: {code}");
        assert_eq!(pair_state(&id), Some(PairState::Waiting));

        // It shows up for the desktop to decide on, with its code and a
        // name - but never a token.
        let waiting = pending_pairs();
        assert_eq!(waiting.len(), 1);
        assert_eq!(waiting[0]["id"], json!(id));
        assert_eq!(waiting[0]["code"], json!(code));
        assert_eq!(waiting[0]["device"], json!("iPhone"));
        assert!(waiting[0].get("token").is_none(), "a waiting pairing must not carry a token");

        assert!(approve_pair(&id), "approving a waiting pairing succeeds");
        assert_eq!(pair_state(&id), Some(PairState::Approved));
        // Once decided it is no longer waiting, so it leaves the desktop list.
        assert!(pending_pairs().is_empty(), "an approved pairing is still waiting");
    }

    #[test]
    fn a_rejected_pairing_is_never_approved_after() {
        let _g = PAIR_SERIAL.lock().unwrap();
        clear_pending();

        let (id, _code) = start_pair("Android".into(), "10.0.0.6".into()).expect("start");
        assert!(reject_pair(&id), "rejecting a waiting pairing succeeds");
        assert_eq!(pair_state(&id), Some(PairState::Rejected));
        // A decision is final: a race that both rejects and approves must
        // not flip an answered pairing back to approved.
        assert!(!approve_pair(&id), "a rejected pairing was approved after the fact");
        assert_eq!(pair_state(&id), Some(PairState::Rejected));
    }

    #[test]
    fn an_unknown_handle_is_not_a_pairing() {
        let _g = PAIR_SERIAL.lock().unwrap();
        clear_pending();
        assert_eq!(pair_state("0000000000000000000000000000000000"), None);
        assert!(!approve_pair("nope"), "an unknown handle was approved");
        assert!(!reject_pair("nope"), "an unknown handle was rejected");
    }

    /// The overall ceiling: no number of distinct addresses can put more
    /// than MAX_PENDING prompts in front of the desktop at once.
    #[test]
    fn the_desktop_is_never_buried_no_matter_how_many_devices_ask() {
        let _g = PAIR_SERIAL.lock().unwrap();
        clear_pending();

        // A different address each time, so the per-IP cap never bites and
        // the only thing that can stop it is the global one.
        for i in 0..MAX_PENDING {
            let ip = format!("10.0.{i}.1");
            assert!(start_pair("iPhone".into(), ip).is_some(), "a pairing under the global cap should start");
        }
        assert!(
            start_pair("iPhone".into(), "10.9.9.9".into()).is_none(),
            "the global cap did not hold"
        );

        // Answering one makes room again: the cap counts only what is still
        // waiting, so a decided request does not keep a slot forever.
        let waiting = pending_pairs();
        assert!(approve_pair(waiting[0]["id"].as_str().unwrap()), "approve one to free a slot");
        assert!(
            start_pair("iPhone".into(), "10.9.9.9".into()).is_some(),
            "a slot did not free after a decision"
        );
    }

    /// The point of the whole exercise: one address cannot keep asking. It
    /// gets its few, and then it is refused - while a different address is
    /// entirely unaffected, because the limit is per-IP, not global.
    #[test]
    fn one_address_gets_a_few_asks_and_no_more() {
        let _g = PAIR_SERIAL.lock().unwrap();
        clear_pending();

        let ip = "192.168.1.50";
        for _ in 0..MAX_PENDING_PER_IP {
            assert!(start_pair("iPhone".into(), ip.into()).is_some(), "an ask under the per-IP cap");
        }
        assert!(
            start_pair("iPhone".into(), ip.into()).is_none(),
            "a fourth ask from the same address got through"
        );
        // Another device is not punished for the noisy one next to it.
        assert!(
            start_pair("iPad".into(), "192.168.1.51".into()).is_some(),
            "a different address was refused because of an unrelated one"
        );
    }

    /// "They just deny and re-pair to annoy me": a denial costs the address
    /// a cooldown, checked here at a chosen `now` rather than by sleeping.
    #[test]
    fn a_denied_address_cannot_immediately_ask_again() {
        let now = 10_000_000;
        let ip = "192.168.1.60";
        // One rejected a moment ago is enough to refuse a fresh ask.
        let list = vec![pend(ip, PairState::Rejected, now - 1_000, Some(now - 1_000))];
        assert_eq!(
            start_refusal(&list, ip, now),
            Some("this device was just turned away; try again shortly")
        );
        // A different address is not inside anyone else's cooldown.
        assert_eq!(start_refusal(&list, "192.168.1.61", now), None);
    }

    /// And the cooldown ends: once it has elapsed, the same address is free
    /// to ask again, and the stale denial is pruned rather than kept.
    #[test]
    fn the_cooldown_lets_go_once_it_has_passed() {
        let now = 10_000_000;
        let ip = "192.168.1.62";
        // Created past the TTL and denied past the cooldown: nothing keeps
        // it now. (Created recently but denied long ago cannot happen - the
        // decision follows the creation - so the case that matters is both
        // clocks run out.)
        let created = now - PAIR_TTL_MS - 5_000;
        let denied_at = now - PAIR_DENY_COOLDOWN_MS - 1;
        let p = pend(ip, PairState::Rejected, created, Some(denied_at));
        // The refusal predicate no longer objects...
        assert_eq!(start_refusal(std::slice::from_ref(&p), ip, now), None);
        // ...and pruning at the same instant drops the record entirely,
        // since it is past both its TTL and its cooldown.
        let mut list = vec![p];
        prune_at(&mut list, now);
        assert!(list.is_empty(), "a spent denial was kept");
    }

    /// A denied record has to outlive its creation TTL when the cooldown is
    /// still running, or "deny near the end of the wait" would forget the
    /// denial the instant the request would have expired anyway.
    #[test]
    fn a_denial_is_kept_through_its_cooldown_even_past_the_ttl() {
        let now = 10_000_000;
        // Created long enough ago to be past the creation TTL, but denied
        // just now.
        let created = now - PAIR_TTL_MS - 5_000;
        let p = pend("192.168.1.63", PairState::Rejected, created, Some(now - 1_000));
        assert!(pending_is_live(&p, now), "a within-cooldown denial was treated as expired");
        // The same record, denied long ago, is not kept.
        let old = pend("192.168.1.63", PairState::Rejected, created, Some(now - PAIR_DENY_COOLDOWN_MS - 1));
        assert!(!pending_is_live(&old, now), "a spent denial was kept alive");
    }

    /// Approving does not start a cooldown: an approved device is in, and
    /// nothing about it should refuse a later, unrelated ask from that IP.
    #[test]
    fn approval_does_not_leave_a_cooldown_behind() {
        let now = 10_000_000;
        let ip = "192.168.1.64";
        let list = vec![pend(ip, PairState::Approved, now - 1_000, Some(now - 1_000))];
        assert_eq!(start_refusal(&list, ip, now), None);
    }
}
