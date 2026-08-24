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
