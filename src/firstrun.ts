// Whether to say something the first time, and never again.
//
// A suggestion shown twice is an advert. This exists so "never again" is
// a rule with a test on it rather than an intention in a comment.

export interface FirstRunState {
  /// Set once the hint has been shown — or once it has been decided that
  /// this install is too old to want it.
  shown?: boolean;
  /// Whether the config was untouched when the window started: no theme,
  /// no settings, nothing. Someone upgrading has a config full of their
  /// choices and does not need to be told the app has themes.
  fresh: boolean;
}

export function shouldSuggestThemes(s: FirstRunState): boolean {
  if (s.shown) return false;
  return s.fresh;
}

/// Either way the flag is set: an existing install is marked as done
/// without ever seeing the hint, so it cannot appear later when they
/// happen to clear a setting.
export function markSuggested(): boolean {
  return true;
}
