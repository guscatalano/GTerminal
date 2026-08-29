//! Updating an installed build without going through the Store.
//!
//! The Store round trip is submission, certification and a wait measured in
//! hours or days. That is the right path for a release and the wrong one for
//! finding out whether a fix works, so an installer build can fetch its own
//! versions from the project's GitHub releases and install any of them.
//!
//! Any of them, deliberately. The point is not only moving forward: an
//! update that breaks something has to be undoable on the spot, so the list
//! offers every published version and going back is the same action as going
//! forward. That is why this does not use the updater plugin, which only
//! knows how to reach "latest".
//!
//! Two rules this module exists to keep:
//!
//!   - A packaged (Store) install never self-updates. Running an MSI over a
//!     packaged app is not an upgrade, it is a second copy of the app with a
//!     different identity, and the Store would still consider the package it
//!     installed to be the current one.
//!   - Nothing is installed that was not published by this project, and the
//!     download is checked before it is run rather than after.

use serde::{Deserialize, Serialize};

/// Where versions come from. The project's own releases, over HTTPS.
pub const RELEASES_API: &str =
    "https://api.github.com/repos/guscatalano/GTerminal/releases?per_page=50";

/// One installable version.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Version {
    /// The release tag, e.g. "v0.12.10".
    pub tag: String,
    /// Its version alone, e.g. "0.12.10" - what the app compares against.
    pub version: String,
    /// Direct link to the .msi asset.
    pub url: String,
    /// The asset's file name, kept for the temp file and error messages.
    pub file: String,
    /// ISO timestamp, for showing the list in a useful order.
    pub published_at: String,
    pub prerelease: bool,
    /// Where this sits relative to the running build: "current", "newer" or
    /// "older". Computed here rather than in the window, because a second
    /// implementation of the comparison in another language is a second
    /// thing that can be wrong - and this one is the one with tests.
    #[serde(default)]
    pub relation: String,
}

/// How a published version relates to the one running.
pub fn relation_to(current: &str, version: &str) -> &'static str {
    match cmp_version(version, current) {
        std::cmp::Ordering::Greater => "newer",
        std::cmp::Ordering::Less => "older",
        std::cmp::Ordering::Equal => "current",
    }
}

/// Split a version into numbers. Anything non-numeric stops the parse, so
/// "0.12.10" and "0.12.10.0" both compare as the numbers they start with,
/// and a tag that is not a version at all sorts to the bottom rather than
/// blowing up the list.
fn parts(v: &str) -> Vec<u64> {
    v.trim_start_matches('v')
        .split(['.', '-', '+'])
        .map(|p| p.parse::<u64>().unwrap_or(0))
        .collect()
}

/// Compare two versions by their numbers, shorter padded with zeroes, so
/// 0.12.10 beats 0.12.9 (which a string comparison gets backwards) and
/// 0.12.10 equals 0.12.10.0 (which is how the MSI names it).
pub fn cmp_version(a: &str, b: &str) -> std::cmp::Ordering {
    let (a, b) = (parts(a), parts(b));
    let n = a.len().max(b.len());
    for i in 0..n {
        let x = a.get(i).copied().unwrap_or(0);
        let y = b.get(i).copied().unwrap_or(0);
        if x != y {
            return x.cmp(&y);
        }
    }
    std::cmp::Ordering::Equal
}

/// Read the releases API's answer into installable versions.
///
/// A release with no .msi is skipped rather than offered: the list is what
/// can be installed, and an entry that cannot be is worse than no entry.
pub fn parse_releases(json: &str) -> Vec<Version> {
    let Ok(root) = serde_json::from_str::<serde_json::Value>(json) else {
        return Vec::new();
    };
    let Some(items) = root.as_array() else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for r in items {
        if r.get("draft").and_then(|d| d.as_bool()).unwrap_or(false) {
            continue;
        }
        let tag = r.get("tag_name").and_then(|t| t.as_str()).unwrap_or("");
        if tag.is_empty() {
            continue;
        }
        let Some(assets) = r.get("assets").and_then(|a| a.as_array()) else {
            continue;
        };
        let msi = assets.iter().find(|a| {
            a.get("name")
                .and_then(|n| n.as_str())
                .map(|n| n.to_lowercase().ends_with(".msi"))
                .unwrap_or(false)
        });
        let Some(msi) = msi else { continue };
        let url = msi
            .get("browser_download_url")
            .and_then(|u| u.as_str())
            .unwrap_or("");
        let file = msi.get("name").and_then(|n| n.as_str()).unwrap_or("");
        if url.is_empty() || file.is_empty() {
            continue;
        }
        // Only from this project's own release host. The URL comes off the
        // network, so it decides what gets downloaded and run.
        if !url.starts_with("https://github.com/guscatalano/GTerminal/releases/download/") {
            continue;
        }
        out.push(Version {
            tag: tag.to_string(),
            version: tag.trim_start_matches('v').to_string(),
            url: url.to_string(),
            file: file.to_string(),
            published_at: r
                .get("published_at")
                .and_then(|p| p.as_str())
                .unwrap_or("")
                .to_string(),
            prerelease: r
                .get("prerelease")
                .and_then(|p| p.as_bool())
                .unwrap_or(false),
            relation: String::new(),
        });
    }
    out.sort_by(|a, b| cmp_version(&b.version, &a.version));
    out
}

/// What the app should install on its own, if anything.
///
/// Pinned means pinned: someone holding a version is usually holding it
/// because the newer one broke something for them, and updating anyway is
/// the one behaviour that would make pinning worthless.
pub fn choose_update<'a>(
    current: &str,
    available: &'a [Version],
    pinned: Option<&str>,
    allow_prerelease: bool,
) -> Option<&'a Version> {
    if let Some(pin) = pinned {
        if !pin.trim().is_empty() {
            return None;
        }
    }
    available
        .iter()
        .filter(|v| allow_prerelease || !v.prerelease)
        .find(|v| cmp_version(&v.version, current) == std::cmp::Ordering::Greater)
}

/// Whether this build may install over itself at all.
///
/// A packaged build must not: running an MSI over a Store install does not
/// replace it, it installs a second copy under a different identity, and the
/// Store still believes its own package is the one in use. Updating that
/// install is the Store's job.
pub fn updates_supported(packaged: bool) -> bool {
    !packaged
}

/// A short, honest user agent. GitHub refuses requests without one.
fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(std::time::Duration::from_secs(10))
        .timeout(std::time::Duration::from_secs(60))
        .user_agent(concat!("GTerminal/", env!("GTERMINAL_VERSION")))
        .build()
}

/// Ask GitHub what versions exist. Blocking: call it off the UI thread.
pub fn fetch_versions() -> Result<Vec<Version>, String> {
    let body = agent()
        .get(RELEASES_API)
        .set("Accept", "application/vnd.github+json")
        .call()
        .map_err(|e| format!("could not reach the releases list: {e}"))?
        .into_string()
        .map_err(|e| format!("could not read the releases list: {e}"))?;
    let mut list = parse_releases(&body);
    for v in &mut list {
        v.relation = relation_to(env!("GTERMINAL_VERSION"), &v.version).to_string();
    }
    Ok(list)
}

/// Download one version's installer and hand back where it landed.
///
/// The URL is not taken on trust from the caller: it has to be one this
/// build found in the project's own release list, which is checked again
/// here. A command that accepts any URL and runs what comes back is a
/// remote code execution hole with an update button on it.
pub fn download(version: &Version) -> Result<std::path::PathBuf, String> {
    if !version
        .url
        .starts_with("https://github.com/guscatalano/GTerminal/releases/download/")
    {
        return Err(format!("refusing to download from {}", version.url));
    }
    // A fresh folder per run, so a half-written file from an interrupted
    // attempt is never the thing that gets installed.
    let dir = std::env::temp_dir().join(format!("gterminal-update-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).map_err(|e| format!("could not make a download folder: {e}"))?;
    let safe = version
        .file
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
        .collect::<String>();
    let safe = if safe.to_lowercase().ends_with(".msi") {
        safe
    } else {
        format!("{safe}.msi")
    };
    let path = dir.join(safe);

    let resp = agent()
        .get(&version.url)
        .call()
        .map_err(|e| format!("could not download {}: {e}", version.file))?;
    let mut reader = resp.into_reader();
    let mut file =
        std::fs::File::create(&path).map_err(|e| format!("could not write the download: {e}"))?;
    std::io::copy(&mut reader, &mut file)
        .map_err(|e| format!("the download did not finish: {e}"))?;
    drop(file);

    // An installer that is a few kilobytes is an error page, not an MSI.
    let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
    if size < 1_000_000 {
        let _ = std::fs::remove_file(&path);
        return Err(format!(
            "the download was only {size} bytes, which is not an installer"
        ));
    }
    Ok(path)
}

/// Hand the installer to Windows and let go.
///
/// msiexec is started detached and this process is expected to exit right
/// after: the installer replaces files this very binary is running from,
/// and on Windows that fails while they are open.
pub fn launch_installer(msi: &std::path::Path) -> Result<(), String> {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        std::process::Command::new("msiexec.exe")
            .arg("/i")
            .arg(msi)
            // A basic progress window, no questions. Silent would be nicer
            // until something goes wrong, at which point it would be a
            // failed update with nothing on screen to say so.
            .arg("/qb")
            .creation_flags(DETACHED_PROCESS)
            .spawn()
            .map_err(|e| format!("could not start the installer: {e}"))?;
        Ok(())
    }
    #[cfg(not(windows))]
    {
        let _ = msi;
        Err("installing is only implemented on Windows".to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_compare_as_numbers_not_text() {
        // The one a string comparison gets backwards, and the reason this
        // function exists: "0.12.9" > "0.12.10" as text.
        assert_eq!(cmp_version("0.12.10", "0.12.9"), std::cmp::Ordering::Greater);
        assert_eq!(cmp_version("0.12.9", "0.12.10"), std::cmp::Ordering::Less);
        assert_eq!(cmp_version("0.13.0", "0.9.99"), std::cmp::Ordering::Greater);
    }

    #[test]
    fn a_tag_and_a_four_part_msi_version_are_the_same_version() {
        // The release is tagged v0.12.10 and the MSI calls itself
        // 0.12.10.0. Read as different versions, the app would offer to
        // install the build it is already running, for ever.
        assert_eq!(cmp_version("v0.12.10", "0.12.10.0"), std::cmp::Ordering::Equal);
        assert_eq!(cmp_version("0.12.10", "0.12.10.0"), std::cmp::Ordering::Equal);
    }

    fn release(tag: &str, msi: bool, prerelease: bool) -> String {
        let assets = if msi {
            format!(
                r#"[{{"name":"GTerminal_{v}_x64_en-US.msi","browser_download_url":"https://github.com/guscatalano/GTerminal/releases/download/{tag}/GTerminal_{v}_x64_en-US.msi"}}]"#,
                v = tag.trim_start_matches('v'),
                tag = tag
            )
        } else {
            r#"[{"name":"GTerminal-signing.cer","browser_download_url":"https://github.com/guscatalano/GTerminal/releases/download/x/GTerminal-signing.cer"}]"#.to_string()
        };
        format!(
            r#"{{"tag_name":"{tag}","prerelease":{prerelease},"draft":false,"published_at":"2026-08-28T00:00:00Z","assets":{assets}}}"#
        )
    }

    #[test]
    fn releases_are_listed_newest_first() {
        let json = format!(
            "[{},{},{}]",
            release("v0.12.9", true, false),
            release("v0.12.10", true, false),
            release("v0.11.0", true, false)
        );
        let v = parse_releases(&json);
        let order: Vec<_> = v.iter().map(|v| v.version.as_str()).collect();
        assert_eq!(order, vec!["0.12.10", "0.12.9", "0.11.0"]);
    }

    #[test]
    fn a_release_with_no_installer_is_not_offered() {
        // The list is what can be installed. An entry that cannot be is
        // worse than no entry - it fails at the point someone clicks it.
        let json = format!("[{},{}]", release("v0.12.10", false, false), release("v0.12.9", true, false));
        let v = parse_releases(&json);
        assert_eq!(v.len(), 1);
        assert_eq!(v[0].version, "0.12.9");
    }

    #[test]
    fn nothing_is_installed_from_somewhere_else() {
        // The download URL arrives over the network and decides what gets
        // run. One that does not come from this project's releases is not
        // an update, whatever the release says its name is.
        let json = r#"[{"tag_name":"v9.9.9","draft":false,"prerelease":false,"published_at":"","assets":[{"name":"evil.msi","browser_download_url":"https://example.com/evil.msi"}]}]"#;
        assert!(parse_releases(json).is_empty());
    }

    #[test]
    fn junk_is_a_short_list_not_a_crash() {
        assert!(parse_releases("not json").is_empty());
        assert!(parse_releases("{}").is_empty());
        assert!(parse_releases("[]").is_empty());
    }

    #[test]
    fn an_update_is_only_offered_when_it_is_newer() {
        let json = format!("[{},{}]", release("v0.12.10", true, false), release("v0.12.9", true, false));
        let v = parse_releases(&json);
        assert_eq!(
            choose_update("0.12.9", &v, None, false).map(|u| u.version.clone()),
            Some("0.12.10".to_string())
        );
        assert!(choose_update("0.12.10", &v, None, false).is_none());
        // And never a downgrade on its own - going back is something a
        // person chooses from the list, not something that happens to them.
        assert!(choose_update("0.13.0", &v, None, false).is_none());
    }

    #[test]
    fn a_pin_holds_even_when_something_newer_exists() {
        // Someone holding a version is usually holding it because the newer
        // one broke them. Updating anyway is the single behaviour that
        // would make pinning worthless.
        let json = format!("[{},{}]", release("v0.12.10", true, false), release("v0.12.9", true, false));
        let v = parse_releases(&json);
        assert!(choose_update("0.12.9", &v, Some("0.12.9"), false).is_none());
        // An empty pin is not a pin.
        assert!(choose_update("0.12.9", &v, Some("  "), false).is_some());
        assert!(choose_update("0.12.9", &v, None, false).is_some());
    }

    #[test]
    fn prereleases_stay_out_of_the_way_unless_asked_for() {
        let json = format!("[{},{}]", release("v0.13.0", true, true), release("v0.12.9", true, false));
        let v = parse_releases(&json);
        assert!(choose_update("0.12.9", &v, None, false).is_none());
        assert_eq!(
            choose_update("0.12.9", &v, None, true).map(|u| u.version.clone()),
            Some("0.13.0".to_string())
        );
    }

    #[test]
    fn a_version_knows_where_it_sits_relative_to_this_build() {
        // The window used to work this out for itself, in its own
        // comparison, in another language. Two implementations of one rule
        // is two things that can be wrong, and only one of them has tests.
        assert_eq!(relation_to("0.12.10", "0.12.11"), "newer");
        assert_eq!(relation_to("0.12.10", "0.12.9"), "older");
        assert_eq!(relation_to("0.12.10", "0.12.10"), "current");
        // And the four-part MSI spelling of the same version is current,
        // not something to offer as an update for ever.
        assert_eq!(relation_to("0.12.10", "0.12.10.0"), "current");
    }

    #[test]
    fn a_store_install_never_updates_itself() {
        // Running an MSI over a packaged app does not replace it - it
        // installs a second copy under a different identity while the Store
        // still believes its package is the one in use.
        assert!(!updates_supported(true));
        assert!(updates_supported(false));
    }
}
