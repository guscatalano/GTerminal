// Remote control: the settings side of publishing your shells.
//
// A person turning this on is opening a port on a machine that holds
// their real shells, so the wording here is doing as much work as the
// code. These are the bits that decide what the settings page says and
// what URL it hands over; pure and separate from main.ts because the
// interesting part is the defaults and the sentences, not the plumbing.
// See tests/remote.mjs, and src-tauri/src/remote.rs for the server.

export interface RemoteSettings {
  /// Absent means off, and must keep meaning off: every config.json
  /// written before this existed has no such key, and none of those
  /// machines may start listening because they were updated.
  remote_enabled?: boolean;
  /// "local" (default) or "lan". Anything else is read as "local", on
  /// both sides, so a hand-edited config fails closed.
  remote_bind?: string;
  remote_port?: number;
  remote_token?: string;
  /// Whether the page may type into a shell. Separate from being able to
  /// watch one, and separately off.
  remote_input?: boolean;
  /// Approve-on-desktop pairing. When on, a device with no token can ask
  /// to connect and is shown a code; the desktop approves it against that
  /// code and the device is handed the token. Off unless turned on, and
  /// like the rest, absent has to keep meaning off.
  remote_pairing?: boolean;
  /// Encrypt with HTTPS. Unlike everything else here, absent means ON:
  /// this is a security default, so only an explicit `false` — the escape
  /// hatch for someone already behind TLS or whose client will not take a
  /// self-signed cert — serves in the clear.
  remote_tls?: boolean;
}

/// The port the Rust side falls back to. Kept in step by the test below
/// rather than by hope — a frontend showing one port while the server
/// binds another is a link that simply does not open.
export const DEFAULT_PORT = 8722;

export function remoteOn(c: RemoteSettings): boolean {
  return c.remote_enabled === true;
}

export function remoteBind(c: RemoteSettings): "local" | "lan" {
  return c.remote_bind === "lan" || c.remote_bind === "0.0.0.0" ? "lan" : "local";
}

export function remotePort(c: RemoteSettings): number {
  const p = c.remote_port;
  // Below 1024 needs privileges this app does not have; the same range
  // the server enforces, so what settings shows is what will be bound.
  return typeof p === "number" && p >= 1024 && p <= 65535 ? p : DEFAULT_PORT;
}

export function remoteInput(c: RemoteSettings): boolean {
  return c.remote_input === true;
}

/// HTTPS is on unless the config explicitly says false — the mirror of
/// `tls_on` on the Rust side, and the one switch here whose default is on,
/// because it is what keeps a published shell off the wire in the clear.
export function remoteTls(c: RemoteSettings): boolean {
  return c.remote_tls !== false;
}

/// Whether a device with no token may ask to be let in. Like every other
/// switch here, only a real boolean true turns it on, so a hand-edited
/// `"remote_pairing": "yes"` fails closed on both sides.
export function remotePairing(c: RemoteSettings): boolean {
  return c.remote_pairing === true;
}

/// What turning pairing on actually means, in the sentence to read before
/// choosing it. The device is shown a code and nothing else; the token is
/// only ever handed over after the person at the desktop approves the
/// request, so this changes how the token is delivered, not what it is.
export function pairingConsequence(on: boolean): string {
  return on
    ? "A device opening the page without the token is shown a short code and waits. It gets in only when you approve it here, against that code — the token is handed over then, never typed."
    : "A device without the token cannot ask to connect. Opening the page then only says the link needs its token.";
}

/// One waiting request, as the desktop sees it: a handle to answer with,
/// the code the device is showing, and a guess at what the device is.
/// Never a token — that is not decided until approval.
export interface RemotePending {
  id: string;
  code: string;
  device: string;
  at_ms: number;
}

/// The line above the Allow/Deny buttons for one waiting device. The code
/// leads, because checking it against the phone in your hand is the whole
/// job; the device name is the client's own claim and comes second.
export function describePending(p: RemotePending): string {
  const device = p.device || "A device";
  return `${device} wants to connect. Code on it: ${p.code}`;
}

/// What binding wide actually means, in the words someone should read
/// before they choose it. Not "exposes the service on all interfaces" —
/// the thing at the other end of this port is a shell, and the sentence
/// has to say so.
export function bindConsequence(bind: "local" | "lan"): string {
  return bind === "lan"
    ? "Anything that can reach this machine — every device on the network you are on, and anything routed to it — can ask for the page. The token is the only thing between them and a shell."
    : "Only this machine can connect. Reach it from a phone by putting this machine on a VPN such as WireGuard and using the tunnel's address, or switch the setting below.";
}

/// The one sentence that has to be true and has to be read: these are
/// the user's real shells, not a preview of them.
export const PUBLISHING_WARNING =
  "The sessions listed here are your real shells. Anyone with this link and its token can read everything they print — and, if typing is on, run commands in them.";

/// The link to open on the phone.
///
/// The token is in the query string because the first thing that happens
/// is somebody opening a URL, and there is nowhere else to put it. The
/// page takes it out of the address bar as soon as it has read it.
export function remoteUrl(host: string, port: number, token: string, secure = true): string {
  const h = host.includes(":") ? `[${host}]` : host;
  const scheme = secure ? "https" : "http";
  return `${scheme}://${h}:${port}/?t=${encodeURIComponent(token)}`;
}

/// A token, shown in a way that can be checked against a phone without
/// being readable over a shoulder. Short tokens are shown whole, because
/// masking four characters tells nobody anything.
export function maskToken(token: string): string {
  if (!token) return "";
  if (token.length <= 8) return token;
  return `${token.slice(0, 4)}${"•".repeat(token.length - 8)}${token.slice(-4)}`;
}

export interface RemoteStatus {
  running?: boolean;
  /// On, but not listening because no window is open. A distinct state
  /// from off: the setting is where the user left it, and showing a
  /// window starts it again without touching anything.
  paused?: boolean;
  port?: number;
  bind?: string;
  hosts?: string[];
  /// Whether the running server speaks HTTPS. Default on; the links and
  /// QR use it to pick the scheme, since a phone opening http:// against
  /// a TLS port is the "bad request" the encryption is here to end.
  tls?: boolean;
  error?: string;
}

/// The line under the toggle: what is actually happening right now, as
/// opposed to what the settings say should be happening. The two come
/// apart — a port already in use is the common way — and when they do,
/// the reason is the only useful thing on the page.
export function statusLine(c: RemoteSettings, st: RemoteStatus): string {
  if (!remoteOn(c)) return "Off. Nothing is listening, and no port is open.";
  // Checked before the error, because a paused server has not failed at
  // anything and whatever error is left over is from before.
  if (st.paused) {
    return "Paused: nothing is listening while no window is open. Showing a window starts it again.";
  }
  if (st.error) return st.error;
  if (!st.running) return "Turned on, but not listening yet.";
  const where = st.bind === "0.0.0.0" ? "every address on this machine" : "127.0.0.1 only";
  return `Listening on ${where}, port ${st.port}.`;
}

/// Every address worth offering, newest-looking first.
///
/// A loopback-bound server has exactly one, and saying so is the point:
/// somebody who expected to open it from their phone finds out here
/// rather than by watching a link time out.
export function addressesFor(st: RemoteStatus, token: string): string[] {
  const port = st.port ?? DEFAULT_PORT;
  const hosts = st.hosts && st.hosts.length ? st.hosts : ["127.0.0.1"];
  // Default to HTTPS when the status is silent: the server's default is
  // on, so an old status that predates the field must not mint http links.
  const secure = st.tls !== false;
  return hosts.map((h) => remoteUrl(h, port, token, secure));
}

/// One connection, as the server can honestly describe it.
///
/// There is no account here and no name: the token is the only
/// credential, so anyone holding it is "authorised" and nothing knows
/// who they are. What the connection itself shows is the address it came
/// from and what the browser claimed to be, and the second of those is a
/// claim rather than a fact - which is why both are shown, never one
/// standing in for the other.
export interface RemoteViewer {
  addr?: string;
  device?: string;
  since_ms?: number;
  last_ms?: number;
  session?: number | null;
  typed?: number;
}

/// Requests that were turned away for presenting the wrong token, or
/// none. On a loopback bind that means something on this machine is
/// knocking; on a LAN bind, something on the network is.
export interface RemoteRefused {
  count?: number;
  addr?: string;
  last_ms?: number;
}

export interface RemoteStatusLive extends RemoteStatus {
  /// Connections open right now. For this page that is a phone with the
  /// stream up, so it reads as "somebody is watching".
  viewers?: number;
  /// Requests that have ever got past the token, and when the last one
  /// did. "Nobody is connected right now" is not the same as "nobody has
  /// been", and after the fact the second one is what you want to know.
  served?: number;
  last_ms?: number;
  who?: RemoteViewer[];
  refused?: RemoteRefused | null;
}

/// How long ago, in the shortest form that is still true.
export function ago(ms: number | undefined, now: number): string {
  if (!ms) return "";
  const d = Math.max(0, now - ms) / 1000;
  if (d < 60) return `${Math.round(d)}s ago`;
  if (d < 3600) return `${Math.round(d / 60)}m ago`;
  if (d < 86400) return `${Math.round(d / 3600)}h ago`;
  return `${Math.round(d / 86400)}d ago`;
}

/// One line about one connection.
///
/// Device and address both, in that order: the device is what somebody
/// recognises ("that's my phone") and the address is what makes it
/// checkable. Saying only the device would be repeating the client's own
/// claim back as though it were established.
export function describeViewer(v: RemoteViewer, now: number): string {
  const parts = [`${v.device || "a device"} at ${v.addr || "an unknown address"}`];
  if (typeof v.session === "number") parts.push(`watching session ${v.session}`);
  if (v.typed) parts.push(v.typed === 1 ? "typed once" : `typed ${v.typed} times`);
  const since = ago(v.since_ms, now);
  if (since) parts.push(`connected ${since}`);
  return parts.join(" · ");
}

/// The line about attempts that were refused, or nothing when there have
/// been none. Worth its own sentence rather than a number in a corner:
/// it is the only thing here that says somebody who should not be
/// knocking is.
export function describeRefused(r: RemoteRefused | null | undefined, now: number): string {
  if (!r || !r.count) return "";
  const when = ago(r.last_ms, now);
  const times = r.count === 1 ? "once" : `${r.count} times`;
  return `Turned away ${times} for the wrong token — last from ${r.addr || "an unknown address"}${
    when ? ` ${when}` : ""
  }.`;
}

/// The badge in the window chrome, or nothing.
///
/// A setting buried in a settings page is not a warning. While this is
/// on there is a port open onto the user's shells, and the window says
/// so where it cannot be missed - it is the same reasoning as the light
/// on a webcam, and it earns its space for the same reason: the whole
/// risk of the feature is forgetting it is on.
///
/// Three states, because they are three different facts. On; on and
/// reachable from the network rather than from this machine only; and
/// somebody is connected to it right now.
export function remoteBadge(
  c: RemoteSettings,
  st: RemoteStatusLive
): { text: string; level: "on" | "wide" | "watched"; title: string } | null {
  if (!remoteOn(c)) return null;
  const viewers = st.viewers ?? 0;
  const wide = remoteBind(c) === "lan";
  const typing = remoteInput(c);
  const where = wide
    ? "reachable from every address on this machine"
    : "reachable from this machine only";
  const drive = typing
    ? "Typing is on, so whoever is connected can run commands."
    : "Typing is off, so it can be read but not driven.";
  if (viewers > 0) {
    // Who, when it can be said. The count alone answers "is somebody
    // there" and leaves the question everybody asks next - "is that me
    // on my phone?" - for a settings page they have to go and find.
    const now = Date.now();
    const seen = (st.who ?? []).map((v) => describeViewer(v, now));
    const who = seen.length ? ` ${seen.join("; ")}.` : "";
    return {
      text: viewers === 1 ? "1 watching" : `${viewers} watching`,
      level: "watched",
      title: `Remote control is on and something is connected right now — ${where}.${who} ${drive} Click to open the setting.`,
    };
  }
  return {
    text: wide ? "Remote · network" : "Remote on",
    level: wide ? "wide" : "on",
    title: `Remote control is on, ${where}. ${drive} ${PUBLISHING_WARNING} Click to open the setting.`,
  };
}
