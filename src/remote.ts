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
export function remoteUrl(host: string, port: number, token: string): string {
  const h = host.includes(":") ? `[${host}]` : host;
  return `http://${h}:${port}/?t=${encodeURIComponent(token)}`;
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
  port?: number;
  bind?: string;
  hosts?: string[];
  error?: string;
}

/// The line under the toggle: what is actually happening right now, as
/// opposed to what the settings say should be happening. The two come
/// apart — a port already in use is the common way — and when they do,
/// the reason is the only useful thing on the page.
export function statusLine(c: RemoteSettings, st: RemoteStatus): string {
  if (!remoteOn(c)) return "Off. Nothing is listening, and no port is open.";
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
  return hosts.map((h) => remoteUrl(h, port, token));
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
    return {
      text: viewers === 1 ? "1 watching" : `${viewers} watching`,
      level: "watched",
      title: `Remote control is on and something is connected right now — ${where}. ${drive} Click to open the setting.`,
    };
  }
  return {
    text: wide ? "Remote · network" : "Remote on",
    level: wide ? "wide" : "on",
    title: `Remote control is on, ${where}. ${drive} ${PUBLISHING_WARNING} Click to open the setting.`,
  };
}
