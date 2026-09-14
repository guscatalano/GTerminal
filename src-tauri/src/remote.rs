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
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
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

fn read_request(reader: &mut BufReader<TcpStream>) -> Option<Req> {
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

fn respond(out: &mut TcpStream, status: &str, content_type: &str, body: &str) {
    let head = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\n{COMMON_HEADERS}Connection: close\r\n\r\n",
        body.len()
    );
    let _ = out.write_all(head.as_bytes());
    let _ = out.write_all(body.as_bytes());
    let _ = out.flush();
}

fn respond_json(out: &mut TcpStream, status: &str, body: &Value) {
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

struct Ctx {
    token: Arc<String>,
    generation: u64,
}

fn serve(stream: TcpStream, ctx: Arc<Ctx>) {
    let addr = stream
        .peer_addr()
        .map(|a| a.ip().to_string())
        .unwrap_or_else(|_| "unknown address".to_string());
    let _ = stream.set_nodelay(true);
    // A connection that opens and says nothing must not hold a thread
    // for the life of the process; once a stream is running it never
    // reads again, so this only ever bites the silent case.
    let _ = stream.set_read_timeout(Some(Duration::from_secs(20)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(20)));
    let Ok(read_half) = stream.try_clone() else { return };
    let mut reader = BufReader::new(read_half);
    let mut out = stream;

    let Some(req) = read_request(&mut reader) else {
        respond(&mut out, "400 Bad Request", "text/plain; charset=utf-8", "bad request\n");
        return;
    };

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
            &mut out,
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

    match route(&req.method, &req.path) {
        Route::Page => respond(&mut out, "200 OK", "text/html; charset=utf-8", PAGE),
        Route::Sessions => respond_json(&mut out, "200 OK", &sessions_json()),
        Route::Peek => {
            let id = req.param("id").and_then(|s| s.parse::<u32>().ok());
            match id {
                Some(id) => match peek_text(id) {
                    Ok(text) => respond_json(&mut out, "200 OK", &json!({"id": id, "text": text})),
                    Err(e) => respond_json(&mut out, "404 Not Found", &json!({"error": e})),
                },
                None => respond_json(&mut out, "400 Bad Request", &json!({"error": "no id"})),
            }
        }
        Route::Stream => stream_session(&mut out, &req, &ctx, who),
        Route::Input => handle_input(&mut out, &req, who),
        // Behind the token like everything else. There is nothing secret
        // in a copy of xterm.js, but a route that answers without one is
        // a route that says the server is here.
        Route::Engine => respond(&mut out, "200 OK", "application/javascript; charset=utf-8", ENGINE_JS),
        Route::EngineCss => respond(&mut out, "200 OK", "text/css; charset=utf-8", ENGINE_CSS),
        Route::NotFound => respond(&mut out, "404 Not Found", "text/plain; charset=utf-8", "no\n"),
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
fn stream_session(out: &mut TcpStream, req: &Req, ctx: &Ctx, who: u64) {
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
    let req = serde_json::to_vec(&json!({"cmd": "observe", "id": id})).map_err(|e| e.to_string())?;
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

fn send_event(out: &mut TcpStream, event: &str, data: &str) -> std::io::Result<()> {
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
fn handle_input(out: &mut TcpStream, req: &Req, who: u64) {
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
    let token = token_of(config);
    if token.is_empty() {
        // Enabled with no token is not a thing that should be servable.
        // It would be a shell on a port with no lock at all.
        return json!({
            "running": false,
            "error": "no access token — generate one first",
            "port": port(config),
            "bind": bind_addr(config),
            "hosts": [],
        });
    }
    let bind = bind_addr(config);
    let p = port(config);
    let listener = match TcpListener::bind((bind, p)) {
        Ok(l) => l,
        Err(e) => {
            return json!({
                "running": false,
                "error": format!("could not listen on {bind}:{p} — {e}"),
                "port": p,
                "bind": bind,
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
    let ctx = Arc::new(Ctx { token: Arc::new(token), generation });

    std::thread::spawn(move || {
        loop {
            if GENERATION.load(Ordering::SeqCst) != generation {
                return;
            }
            match listener.accept() {
                Ok((stream, _peer)) => {
                    if LIVE_CONNS.load(Ordering::Relaxed) >= MAX_CONNS {
                        drop(stream);
                        continue;
                    }
                    LIVE_CONNS.fetch_add(1, Ordering::Relaxed);
                    let ctx = ctx.clone();
                    std::thread::spawn(move || {
                        serve(stream, ctx);
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
            "port": port(&config),
            "bind": bind_addr(&config),
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
            }));
            if reported.get("running").and_then(Value::as_bool) == Some(true) {
                chosen = candidate;
                break;
            }
        }
        assert!(chosen != 0, "nothing ever bound: {reported}");

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
}
