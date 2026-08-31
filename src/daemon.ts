// Telling an old daemon from a new one, and saying so in a sentence.
//
// The daemon outlives the app that started it — that is the design, not a
// bug — so an update replaces the binary while the previous daemon keeps
// serving the sessions inside it. A window can therefore be newer than
// the daemon it is talking to, and requests added since will be refused.
// See docs/daemon-protocol.md.
//
// Pure and separate from main.ts because the interesting part is the
// wording and the edge cases, not the plumbing: see tests/daemon.mjs.

export interface DaemonInfo {
  /// Absent from any daemon older than the first that reported one,
  /// which is exactly the case worth noticing.
  protocol?: number;
  version?: string;
  pid?: number;
  /// What this daemon can be asked to do beyond the protocol number.
  /// Absent on anything older than the shutdown verb.
  can?: string[];
  /// The version of the window asking. Supplied by the Rust side so the
  /// comparison is not two constants that can drift apart.
  app?: string;
}

/// How the window should replace a daemon that is not the one belonging
/// to this build.
///
///   "none"    - it is current, or newer. Leave it alone.
///   "retire"  - it can stand down on its own. Ask, say nothing, lose
///               nothing; it hands over when the last shell ends.
///   "ask"     - it is too old to stand down. Only a restart will do it,
///               and that ends the shells, so a person decides.
export type DaemonAction = "none" | "retire" | "ask";

/// Compare two versions numerically. "0.12.9" and "0.12.10" get this
/// backwards as text, and that is the pair this had to separate.
function olderThan(a: string, b: string): boolean {
  const pa = a.split(".").map((n) => Number(n) || 0);
  const pb = b.split(".").map((n) => Number(n) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const x = pa[i] ?? 0;
    const y = pb[i] ?? 0;
    if (x !== y) return x < y;
  }
  return false;
}

/// What to do about the daemon on the other end.
///
/// Version, not just protocol. Measured on a real machine: a 0.12.3
/// daemon serving eight live sessions under a 0.12.9 app, considered
/// perfectly current because both speak protocol 2 - so every daemon-side
/// fix in six releases had never reached it. Protocol answers "can these
/// two talk"; it does not answer "is this the daemon that belongs to this
/// build", and only the second question notices that.
export function daemonAction(info: DaemonInfo, required: number): DaemonAction {
  const behind =
    staleDaemon(info, required) ||
    (!!info.app && !!info.version && olderThan(info.version, info.app));
  if (!behind) return "none";
  return info.can?.includes("shutdown") ? "retire" : "ask";
}

/// Is this daemon too old for what the window wants to do?
///
/// A daemon *newer* than the window is not stale. It happens while an
/// update is half-applied, nothing is broken by it, and warning about it
/// would be noise about a situation the user cannot act on anyway.
export function staleDaemon(info: DaemonInfo, required: number): boolean {
  return (info.protocol ?? 0) < required;
}

/// What restarting would cost, in shells.
///
/// Only live ones count. A session whose shell has already ended survives
/// a restart untouched — it is on disk either way — so counting it would
/// overstate the price of the one button being offered.
export function shellsAtRisk(sessions: Array<{ alive?: boolean }>): number {
  return sessions.filter((s) => s.alive !== false).length;
}

/// The notice. One sentence for what is wrong, one for what it costs.
///
/// It names the daemon's version when it reports one and says "an older
/// version" when it does not — which is precisely the case where it
/// cannot say, since a daemon too old to report a protocol is usually too
/// old to report a version either.
export function daemonNotice(info: DaemonInfo, atRisk: number): string {
  const who = info.version
    ? `The background service is still running version ${info.version}`
    : "The background service is still running an older version";
  const cost =
    atRisk === 0
      ? "Nothing is running in it, so restarting it costs nothing."
      : atRisk === 1
        ? "Restarting it ends 1 shell — its output and folder are kept."
        : `Restarting it ends ${atRisk} shells — their output and folders are kept.`;
  return `${who}, so some things this window can do are unavailable. ${cost}`;
}
