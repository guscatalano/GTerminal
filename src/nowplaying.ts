// Now playing: the shape of a track and how it reads in the status bar.
//
// Pure and separate from main.ts because the interesting part is the
// wording — what a paused track looks like, what "nothing is playing"
// says, how a long title is cut — and none of that needs a window to
// test. The backend that fills this in is src-tauri/src/nowplaying.rs;
// it reads Windows' system media controls locally and sends nothing.
// See tests/nowplaying.mjs.

export interface NowPlaying {
  title: string;
  artist: string;
  album: string;
  playing: boolean;
  /// A data: URI of the album thumbnail, or null. Only ever set when the
  /// caller asked for art — the status line does not, the background does.
  art: string | null;
}

/// One track, cut to fit. A single em space keeps the artist and title one
/// unit; "artist — title" is the order a person reads a now-playing line.
export function nowPlayingLabel(np: NowPlaying, max = 42): string {
  const artist = np.artist.trim();
  const title = np.title.trim();
  const full = artist && title ? `${artist} — ${title}` : title || artist || "unknown track";
  return full.length > max ? full.slice(0, max - 1).trimEnd() + "…" : full;
}

/// The status-bar text. Three states that are genuinely different and must
/// read as different: not asked yet, asked and nothing is playing, and a
/// track. A paused track is still a track — it keeps its name and changes
/// only its glyph, because "what is loaded" is the question, not "is sound
/// coming out right now".
export function formatNowPlaying(np: NowPlaying | null, fetched: boolean): string {
  if (!np) return fetched ? "♪ nothing playing" : "♪ …";
  const glyph = np.playing ? "♪" : "⏸";
  return `${glyph} ${nowPlayingLabel(np)}`;
}

/// Whether two reads are the same track — artist and title, ignoring play
/// state and art. Used so the background only refetches the picture when
/// the song actually changes, not every time it pauses or ticks.
export function sameTrack(a: NowPlaying | null, b: NowPlaying | null): boolean {
  if (!a || !b) return a === b;
  return a.title === b.title && a.artist === b.artist && a.album === b.album;
}
