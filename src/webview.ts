// The engine this window renders in.
//
// GTerminal's whole UI is a web page, drawn by the WebView2 runtime -
// Chromium, updated on the user's machine on Microsoft's schedule, not
// ours. Almost everyone is current; the exception is a machine where the
// Evergreen runtime is blocked or pinned, and there the engine can sit far
// enough back that the app draws wrong. This is how the window knows.

/// The oldest Chromium this window renders correctly in. The floor is the
/// CSS the themes lean on: color-mix() runs right through styles.css - the
/// panels, the notices, every mixed colour - and it did not ship until
/// Chromium 111. Below that those declarations are dropped and the window
/// paints without its backgrounds, which is broken enough to be worth a
/// word. The browser-matrix CI can tighten this against real old builds;
/// until it does, 111 is a floor the app already, concretely depends on.
export const MIN_WEBVIEW = 111;

/// The Chromium major version out of a userAgent, or null when it is not
/// there to read. WebView2's UA carries "Chrome/<n>" (with Edg/<n> beside
/// it); the Chrome token is the engine version and the one to trust.
export function chromiumMajor(ua: string): number | null {
  const m = /Chrome\/(\d+)/.exec(ua);
  return m ? Number(m[1]) : null;
}

/// Whether to warn that the engine is too old to render correctly. Warn
/// only below the floor, only while the setting is on, and never for a
/// version already dismissed - an old engine is a standing fact, so one
/// dismissal must not be undone by the next launch.
export function shouldWarnOldWebview(opts: {
  major: number | null;
  enabled: boolean;
  dismissed?: number;
  min?: number;
}): boolean {
  const min = opts.min ?? MIN_WEBVIEW;
  if (!opts.enabled) return false;
  if (opts.major == null) return false; // unknown is not old; say nothing.
  if (opts.major >= min) return false;
  if (opts.dismissed === opts.major) return false;
  return true;
}
