//! Now playing — the current track from Windows' system media controls.
//!
//! Not Spotify's API and no login: Windows exposes whatever is playing —
//! Spotify, a browser tab, any media app that registers with the system
//! transport controls — through SMTC
//! (`GlobalSystemMediaTransportControlsSessionManager`). Title, artist,
//! album, whether it is playing, and the album-art thumbnail, all read
//! locally and sent nowhere. Off unless the user turns it on.
//!
//! Everything here fails soft: no session, no media app, a track with no
//! art, or a platform that is not Windows all come back as `None`, and the
//! status bar simply shows nothing. A missing song is not an error.

use serde_json::Value;

/// The current track, or `None` when nothing is playing or the platform
/// cannot answer. On success: `title`, `artist`, `album`, `playing`, and
/// `art` — a `data:` URI of the album thumbnail, or null.
///
/// `want_art` gates the one expensive step. The status-bar line needs only
/// the text and asks with it off, so a poll every few seconds does not read
/// and base64 a few hundred kilobytes of image each time; the live
/// background asks with it on, and only when the track changes.
pub fn current(want_art: bool) -> Option<Value> {
    #[cfg(windows)]
    {
        imp::current(want_art)
    }
    #[cfg(not(windows))]
    {
        let _ = want_art;
        None
    }
}

/// Assemble a `data:` URI from a MIME type and raw image bytes, defaulting
/// the type when the stream named none. Pure and platform-agnostic — the
/// WinRT side hands it the bytes and the declared type — so the format and
/// the fallback are tested without a live session.
fn data_uri(mime: &str, bytes: &[u8]) -> String {
    let mime = mime.trim();
    let mime = if mime.is_empty() { "image/jpeg" } else { mime };
    format!("data:{};base64,{}", mime, crate::mux::b64(bytes))
}

#[cfg(windows)]
mod imp {
    use serde_json::{json, Value};
    use std::cell::Cell;
    use windows::Media::Control::{
        GlobalSystemMediaTransportControlsSessionManager as Manager,
        GlobalSystemMediaTransportControlsSessionMediaProperties as MediaProperties,
        GlobalSystemMediaTransportControlsSessionPlaybackStatus as PlaybackStatus,
    };
    use windows::Storage::Streams::DataReader;
    use windows::Win32::System::Com::{CoInitializeEx, COINIT_MULTITHREADED};

    // An album thumbnail is tens to a few hundred KB; a megabyte is already
    // generous, and refusing more keeps a hostile or broken stream from
    // handing us an arbitrary allocation to base64 into the UI.
    const MAX_ART_BYTES: u64 = 2 * 1024 * 1024;

    thread_local! {
        // WinRT will not talk to a thread that is not in an apartment.
        // Worker threads are reused, so init once each and never uninit —
        // the poll runs on whichever thread the pool hands it.
        static COM_READY: Cell<bool> = const { Cell::new(false) };
    }

    fn ensure_com() {
        COM_READY.with(|ready| {
            if !ready.get() {
                // MTA: this is a worker thread with no message pump, and a
                // returned S_FALSE (already initialised) is not a failure.
                unsafe {
                    let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
                }
                ready.set(true);
            }
        });
    }

    pub fn current(want_art: bool) -> Option<Value> {
        ensure_com();

        let manager = Manager::RequestAsync().ok()?.get().ok()?;
        // No current session means nothing has claimed the media controls —
        // no player open, or none playing. Not an error, just quiet.
        let session = manager.GetCurrentSession().ok()?;

        let props = session.TryGetMediaPropertiesAsync().ok()?.get().ok()?;
        let title = props.Title().map(|h| h.to_string()).unwrap_or_default();
        let artist = props.Artist().map(|h| h.to_string()).unwrap_or_default();
        let album = props.AlbumTitle().map(|h| h.to_string()).unwrap_or_default();
        // A session that names neither a title nor an artist is not a song
        // worth showing — some apps register the controls before they have
        // anything loaded.
        if title.trim().is_empty() && artist.trim().is_empty() {
            return None;
        }

        let playing = session
            .GetPlaybackInfo()
            .and_then(|info| info.PlaybackStatus())
            .map(|status| status == PlaybackStatus::Playing)
            .unwrap_or(false);

        let art = if want_art { album_art(&props) } else { None };

        Some(json!({
            "title": title,
            "artist": artist,
            "album": album,
            "playing": playing,
            "art": art,
        }))
    }

    /// The album thumbnail as a `data:` URI, or `None`. Every step is
    /// allowed to fail without taking the track down with it: plenty of
    /// tracks have no art, and a missing picture is not a missing song.
    fn album_art(props: &MediaProperties) -> Option<String> {
        let reference = props.Thumbnail().ok()?;
        let stream = reference.OpenReadAsync().ok()?.get().ok()?;
        let size = stream.Size().ok()?;
        if size == 0 || size > MAX_ART_BYTES {
            return None;
        }
        let reader = DataReader::CreateDataReader(&stream).ok()?;
        reader.LoadAsync(size as u32).ok()?.get().ok()?;
        let mut bytes = vec![0u8; size as usize];
        reader.ReadBytes(&mut bytes).ok()?;

        let mime = stream.ContentType().map(|h| h.to_string()).unwrap_or_default();
        Some(super::data_uri(&mime, &bytes))
    }
}

#[cfg(test)]
mod tests {
    use super::data_uri;

    #[test]
    fn a_named_type_is_kept_and_the_bytes_are_base64() {
        // "foo" -> "Zm9v" is the RFC vector; the encoder is mux::b64.
        assert_eq!(data_uri("image/png", b"foo"), "data:image/png;base64,Zm9v");
        assert_eq!(data_uri("image/jpeg", b""), "data:image/jpeg;base64,");
    }

    #[test]
    fn a_blank_type_falls_back_to_jpeg() {
        // Some streams answer ContentType with nothing; a data URI still has
        // to name a type or the browser will not decode it.
        assert_eq!(data_uri("", b"foo"), "data:image/jpeg;base64,Zm9v");
        assert_eq!(data_uri("   ", b"foo"), "data:image/jpeg;base64,Zm9v");
    }

    #[test]
    fn nothing_playing_is_a_clean_none_not_a_panic() {
        // Off Windows there is no media API; the call must be a quiet None
        // rather than a crash — the same shape the frontend treats as "not
        // playing". On Windows this just exercises that the call returns.
        let _ = super::current(false);
        #[cfg(not(windows))]
        assert!(super::current(true).is_none());
    }
}
