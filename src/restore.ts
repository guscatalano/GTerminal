// Which sessions come back at start-up, in what order, and whether to
// ask first.
//
// Pure, and separate from main.ts, because getting it wrong is not
// visible as a crash: it silently resurrects a tab the user closed, or
// drops one they wanted, or reorders their strip. See tests/restore.mjs.

export interface RestorableSession {
  id: number;
  created_ms: number;
  /// Set while a killed session is in its grace window.
  expires_ms?: number | null;
  /// Whether some window already has this session open. The daemon
  /// allows one attacher at a time, so adopting one takes it from
  /// whoever has it.
  attached?: boolean;
}

/// Which list a session belongs in.
///
/// - `open`     — it has a tab on screen
/// - `closing`  — killed, still inside its grace window, restorable
/// - `hidden`   — parked deliberately
/// - `ended`    — its shell is gone (reboot, or the daemon stopped), but
///                its folder and scrollback were kept. Reopening starts a
///                *new* shell with the old output replayed above it.
/// - `detached` — still running, just not on screen. Reopening hands back
///                the very shell you left.
///
/// The last two look identical in a list and are not the same thing at
/// all, which is the whole reason this exists: one click gives you your
/// shell back, the other gives you a fresh one that merely looks like it.
///
/// Order matters. A killed session counts as closing even if it was also
/// hidden — the countdown is the more urgent fact, and the one with a
/// deadline attached.
export type SessionState = "open" | "closing" | "hidden" | "ended" | "detached";

export function sessionState(
  s: { expires_ms?: number | null; alive?: boolean },
  hasTab: boolean,
  isHidden: boolean
): SessionState {
  if (hasTab) return "open";
  if (s.expires_ms) return "closing";
  if (isHidden) return "hidden";
  return s.alive === false ? "ended" : "detached";
}

/// Sessions worth reopening as tabs.
///
/// Three exclusions, and each matters. A session in its grace window was
/// *closed* by the user — attaching cancels the pending kill, so adopting
/// one would resurrect every tab they had just closed, every restart.
/// A hidden session was parked deliberately and should stay parked.
///
/// And a session another window already has open is not this window's to
/// take. The daemon permits one attacher and honours the newest, so
/// adopting one does not fail — it succeeds, and the other window watches
/// its terminal disappear. That is the failure multi-window turns from a
/// theoretical concern into the first thing that would happen.
export function adoptable<T extends RestorableSession>(sessions: T[], hidden: Set<number>): T[] {
  return sessions.filter((s) => !s.expires_ms && !hidden.has(s.id) && !s.attached);
}

/// The user's last tab order, with anything new at the end. Ties break on
/// age so the result is stable rather than however the daemon listed them.
export function inSavedOrder<T extends RestorableSession>(sessions: T[], savedOrder: number[]): T[] {
  const rank = (id: number) => {
    const i = savedOrder.indexOf(id);
    return i === -1 ? Number.MAX_SAFE_INTEGER : i;
  };
  return [...sessions].sort((a, b) => rank(a.id) - rank(b.id) || a.created_ms - b.created_ms);
}

/// Whether to ask which sessions to restore. Strictly more than the
/// threshold: at exactly the threshold the wait is what the user said
/// they would tolerate, so asking would be nagging.
export function shouldAsk(count: number, enabled: boolean, threshold: number): boolean {
  return enabled && count > threshold;
}

/// The tab Ctrl+<n> should select. 9 means the last one however many
/// there are, which is what browsers do. Undefined when there is no such
/// tab, so the key can fall through to the shell instead of being
/// swallowed to no effect.
export function tabForNumber(ids: number[], n: number): number | undefined {
  if (!ids.length || n < 1 || n > 9) return undefined;
  return n === 9 ? ids[ids.length - 1] : ids[n - 1];
}
