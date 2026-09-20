// Now playing: the wording and the track-change test.
// Run: node tests/nowplaying.mjs
//
// The backend is WinRT and cannot run here, but the part that decides what
// a person reads is pure — so it is tested here, and the Rust side stays
// thin glue over the system media API.
import { formatNowPlaying, nowPlayingLabel, sameTrack } from "../src/nowplaying.ts";

let failed = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
  if (!ok) failed++;
}

const track = (o = {}) => ({ title: "Dreams", artist: "Fleetwood Mac", album: "Rumours", playing: true, art: null, ...o });

// ── the three states are three different sentences ─────────────────────
// Not asked yet, asked and nothing playing, and a track. The first two
// must not read the same — "loading" and "silent" are different facts.
check("before the first read it is loading", formatNowPlaying(null, false), "♪ …");
check("asked, and nothing is playing", formatNowPlaying(null, true), "♪ nothing playing");
check("a playing track keeps the note glyph", formatNowPlaying(track(), true), "♪ Fleetwood Mac — Dreams");

// A paused track is still a track — same name, different glyph. Losing the
// name on pause would make a glance say "nothing", which is a lie.
check("a paused track keeps its name", formatNowPlaying(track({ playing: false }), true), "⏸ Fleetwood Mac — Dreams");

// ── the label ──────────────────────────────────────────────────────────
check("artist then title, in that order", nowPlayingLabel(track()), "Fleetwood Mac — Dreams");
check("a title with no artist stands alone", nowPlayingLabel(track({ artist: "" })), "Dreams");
check("neither is a named unknown, not a blank", nowPlayingLabel(track({ title: "", artist: "" })), "unknown track");

// A long title is cut with an ellipsis rather than shoving the bar around.
const long = nowPlayingLabel(track({ title: "A Very Long Song Title That Runs Well Past The Limit", artist: "Some Artist" }), 20);
check("a long label is cut to the limit", long.length <= 20, true);
check("and ends in an ellipsis", long.endsWith("…"), true);

// ── track identity ─────────────────────────────────────────────────────
// The background refetches the picture only when the song changes, so
// "same track" must ignore play state and art but not the title.
check("the same song paused is the same track", sameTrack(track(), track({ playing: false, art: "data:..." })), true);
check("a different title is a different track", sameTrack(track(), track({ title: "The Chain" })), false);
check("null matches only null", sameTrack(track(), null), false);
check("both null is the same (nothing)", sameTrack(null, null), true);

if (failed) {
  console.log(`${failed} now-playing test(s) failed`);
  process.exit(1);
}
console.log("all now-playing tests passed");
