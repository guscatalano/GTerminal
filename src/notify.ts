// Telling you a command finished while you were somewhere else.
//
// The parts were all here already: the shell's OSC 133 marks say when a
// command ended and how it went, and the window knows whether anyone is
// looking at it. What was missing is the join, and the join is almost
// entirely a question of restraint — a terminal that toasts every time a
// prompt comes back is one whose notifications get turned off within an
// hour, and then the one that mattered is missed too.
//
// So the rules live here, apart from the plumbing, where every one of
// them can be argued with in a test. See tests/notify.mjs.

export interface NotifySettings {
  /// Off unless asked for. Nothing here should start interrupting
  /// somebody because they updated.
  notify_done?: boolean;
  /// How long a command has to run before finishing is worth saying.
  /// Seconds.
  notify_after_seconds?: number;
  /// Whether to say so even while the window is on screen and focused.
  /// Off: if you are looking at the terminal, the terminal has already
  /// told you by printing the prompt.
  notify_when_focused?: boolean;
}

/// The default wait.
///
/// Thirty seconds is about the point where somebody stops watching and
/// goes to do something else — shorter and it fires for commands you sat
/// through, which is the fastest way to teach someone to ignore it.
export const DEFAULT_NOTIFY_AFTER_SECONDS = 30;

export function notifyEnabled(c: NotifySettings): boolean {
  return c.notify_done === true;
}

export function notifyAfterMs(c: NotifySettings): number {
  const s = c.notify_after_seconds;
  // A floor rather than a free hand: zero would notify for every
  // command, which is the behaviour this whole file exists to avoid.
  return typeof s === "number" && s >= 5 && s <= 3600 ? s * 1000 : DEFAULT_NOTIFY_AFTER_SECONDS * 1000;
}

export interface FinishedCommand {
  /// How long it ran, measured from the Enter that started it.
  ranMs: number;
  /// Exit code, or undefined when the shell did not say. Unknown is not
  /// failure — see parseExit in blocks.ts.
  exit?: number;
  /// Whether the window is on screen at all.
  visible: boolean;
  /// Whether it is the window the user is working in.
  focused: boolean;
}

/// Is this worth interrupting somebody for?
export function shouldNotify(c: NotifySettings, f: FinishedCommand): boolean {
  if (!notifyEnabled(c)) return false;
  if (f.ranMs < notifyAfterMs(c)) return false;
  // A hidden window is the whole case: the terminal is in the tray and
  // the prompt coming back is invisible. A visible but unfocused one is
  // the same situation with a different shape - you are in a browser,
  // the window is behind it - so it counts too.
  if (f.visible && f.focused && c.notify_when_focused !== true) return false;
  return true;
}

/// What the toast says, in two lines: what happened, then what it was.
///
/// The command first and the outcome in the title, because a phone-sized
/// notification gets read in the order it is written and "failed" is the
/// word that decides whether somebody comes back to the machine now or
/// after their coffee.
export function notifyTitle(f: FinishedCommand): string {
  if (f.exit === undefined) return "Command finished";
  return f.exit === 0 ? "Command finished" : `Command failed (exit ${f.exit})`;
}

/// One line of body: the command, and how long it took.
///
/// The command is trimmed to something a toast can show. Windows will
/// cut it off anyway; cutting it here means choosing where, and the
/// front of a command line says more than the end of one.
export function notifyBody(command: string, ranMs: number): string {
  const line = command.split(/\r?\n/)[0].trim();
  const shown = line.length > 60 ? `${line.slice(0, 60)}…` : line;
  const took = describeDuration(ranMs);
  return shown ? `${shown} — ${took}` : `Took ${took}`;
}

/// A duration a person would say out loud. Never "0.0s", never
/// "1m 0s" for something that took a minute.
export function describeDuration(ms: number): string {
  const s = Math.round(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  const rest = s % 60;
  if (m < 60) return rest ? `${m}m ${rest}s` : `${m}m`;
  const h = Math.floor(m / 60);
  const mrest = m % 60;
  return mrest ? `${h}h ${mrest}m` : `${h}h`;
}
