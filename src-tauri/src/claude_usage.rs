//! Claude Code usage for the status bar.
//!
//! Tokens - the live number - come from Claude Code's own JSONL
//! transcripts, one file per session, under
//! `<home>\.claude\projects\<project-slug>\<session-uuid>.jsonl`. Every
//! assistant line in one of those carries a `message.usage` block with
//! the real input/output/cache-read/cache-write split; summing them
//! ourselves is the only way to get that split for *today* specifically.
//!
//! An earlier version of this module read `<home>\.claude\stats-cache.json`
//! instead - one small file rather than hundreds of transcripts, and it
//! carries `costUSD`. But that cache is written on Claude Code's own
//! schedule, not live: on the machine this was built on it was a month
//! stale (`lastComputedDate` weeks behind the actual day), so "today's
//! usage" read from it was permanently empty. It is kept on for exactly
//! the one thing JSONL cannot give: cost (see `all_time_cost`). Never for
//! today's tokens.
//!
//! Both files are Claude Code's own working formats, not a published
//! API, and the stats cache has already changed shape once relative to
//! what an earlier version of this module assumed. So parsing throughout
//! stays maximally permissive: an unreadable file, a line that isn't an
//! assistant message with usage, or a shape that doesn't match what was
//! verified on this machine all come back as "nothing here", never an
//! error. See the tests for exactly what junk this tolerates.
//!
//! No price table is hardcoded here, and no per-token rate is derived
//! from `costUSD` and multiplied by today's tokens - that would look
//! precise and be wrong, since the cache's model mix and rates can be
//! weeks out of date relative to today's usage. `costUSD` is surfaced
//! only as what it is: an all-time figure, as of whatever date the cache
//! itself claims.

use serde::{Deserialize, Serialize};
use std::path::Path;

/// One assistant message's token usage, kept in UTC exactly as written -
/// which local calendar day it falls on is decided later, by whoever is
/// asking (see `totals_for_day`), not baked in here.
#[derive(Debug, Clone, PartialEq)]
pub struct UsageEntry {
    pub session_id: String,
    pub model: String,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_creation_tokens: u64,
    pub cache_read_tokens: u64,
    pub timestamp: chrono::DateTime<chrono::Utc>,
}

fn tok(v: &serde_json::Value, key: &str) -> u64 {
    v.get(key).and_then(|x| x.as_u64()).unwrap_or(0)
}

/// Parse one JSONL line into a usage entry. Anything that is not an
/// assistant message with a usable `message.usage` block comes back
/// `None`: user turns, tool-result lines, session summaries, blank
/// lines, a trailing partial line from a session still being written by
/// another process right now, and whatever shape a future Claude Code
/// version adds.
pub fn parse_line(line: &str) -> Option<UsageEntry> {
    let v: serde_json::Value = serde_json::from_str(line.trim()).ok()?;
    if v.get("type").and_then(|t| t.as_str()) != Some("assistant") {
        return None;
    }
    let message = v.get("message")?;
    let usage = message.get("usage")?;
    let timestamp = v
        .get("timestamp")
        .and_then(|t| t.as_str())
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())?
        .with_timezone(&chrono::Utc);
    Some(UsageEntry {
        session_id: v
            .get("sessionId")
            .and_then(|s| s.as_str())
            .unwrap_or("")
            .to_string(),
        model: message
            .get("model")
            .and_then(|s| s.as_str())
            .unwrap_or("unknown")
            .to_string(),
        input_tokens: tok(usage, "input_tokens"),
        output_tokens: tok(usage, "output_tokens"),
        cache_creation_tokens: tok(usage, "cache_creation_input_tokens"),
        cache_read_tokens: tok(usage, "cache_read_input_tokens"),
        timestamp,
    })
}

/// One model's slice of a day's usage.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ModelUsage {
    pub model: String,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_creation_tokens: u64,
    pub cache_read_tokens: u64,
    pub messages: u64,
}

/// A day's usage, plus whatever cost figure `stats-cache.json` had to
/// offer - for the status bar's detail panel.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Report {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_creation_tokens: u64,
    pub cache_read_tokens: u64,
    pub messages: u64,
    /// Distinct session ids seen, not files scanned - one file is one
    /// session, but a file need not have a message on the requested day
    /// just because it was touched on it (see `scan`).
    pub sessions: u64,
    /// Sorted by model name, so the detail panel does not reorder itself
    /// between two ticks just because a hash landed differently.
    pub by_model: Vec<ModelUsage>,
    /// Claude Code's own figure from `stats-cache.json`, summed across
    /// every model in `modelUsage`. `None` if that file is missing,
    /// unreadable, unparsable, or has no models to sum - the frontend
    /// omits the row entirely rather than show a number with no
    /// visible age. Always all-time, never scoped to today: see
    /// `all_time_cost` and the module doc.
    pub all_time_cost_usd: Option<f64>,
    /// The cache's own `lastComputedDate`, so the cost row can say how
    /// old it is instead of implying it is current. Empty when
    /// `all_time_cost_usd` is `None`, or when the cache has the field
    /// missing.
    pub cost_as_of: String,
}

/// Fold entries into totals for one local calendar day. `offset` is the
/// caller's local UTC offset, passed in rather than read from the system
/// clock here so this stays pure and testable without a real timezone: a
/// test can pin any offset and know exactly which entries land in the
/// target day, regardless of what timezone the machine running the test
/// happens to be in.
pub fn totals_for_day(
    entries: &[UsageEntry],
    day: chrono::NaiveDate,
    offset: chrono::FixedOffset,
) -> Report {
    use std::collections::{HashMap, HashSet};
    let mut totals = Report::default();
    let mut sessions: HashSet<&str> = HashSet::new();
    let mut by_model: HashMap<&str, ModelUsage> = HashMap::new();
    for e in entries {
        if e.timestamp.with_timezone(&offset).date_naive() != day {
            continue;
        }
        totals.input_tokens += e.input_tokens;
        totals.output_tokens += e.output_tokens;
        totals.cache_creation_tokens += e.cache_creation_tokens;
        totals.cache_read_tokens += e.cache_read_tokens;
        totals.messages += 1;
        sessions.insert(e.session_id.as_str());
        let m = by_model.entry(e.model.as_str()).or_insert_with(|| ModelUsage {
            model: e.model.clone(),
            ..Default::default()
        });
        m.input_tokens += e.input_tokens;
        m.output_tokens += e.output_tokens;
        m.cache_creation_tokens += e.cache_creation_tokens;
        m.cache_read_tokens += e.cache_read_tokens;
        m.messages += 1;
    }
    totals.sessions = sessions.len() as u64;
    let mut models: Vec<ModelUsage> = by_model.into_values().collect();
    models.sort_by(|a, b| a.model.cmp(&b.model));
    totals.by_model = models;
    totals
}

/// Worst case for one scan: every session file touched today is opened,
/// streamed line by line (never loaded whole into memory), up to
/// `MAX_BYTES` total or `MAX_LINES` total lines, whichever comes first -
/// so one giant or still-growing transcript cannot make a status bar
/// tick hang or balloon memory. In practice a single day's transcripts
/// are a handful of files, a few MB total; these caps only bite on a
/// pathological one.
const MAX_LINES: usize = 200_000;
const MAX_BYTES: usize = 64 * 1024 * 1024;

/// Walk every `*.jsonl` under `<claude_dir>/projects/*/`, keeping only
/// files last modified on `day` in local time - a session file's mtime
/// only advances when a line is appended to it, so a file untouched
/// today cannot contain a message from today. That mtime check, done
/// before opening a single file, is the main performance strategy: on a
/// machine with months of history this is still just today's handful of
/// files, not the whole `.claude` tree. The byte/line caps above are the
/// backstop for whatever gets past that filter.
///
/// Anything unreadable - a missing `.claude`, a permissions error, a
/// file that vanishes in a race with Claude Code still writing it - is
/// silently skipped rather than surfaced, matching the module's
/// degrade-never-throw rule.
pub fn scan(claude_dir: &Path, day: chrono::NaiveDate) -> Vec<UsageEntry> {
    let mut out = Vec::new();
    let projects = claude_dir.join("projects");
    let Ok(project_dirs) = std::fs::read_dir(&projects) else {
        return out;
    };
    let mut lines_read = 0usize;
    let mut bytes_read = 0usize;
    'projects: for project in project_dirs.flatten() {
        let Ok(files) = std::fs::read_dir(project.path()) else {
            continue;
        };
        for file in files.flatten() {
            if lines_read >= MAX_LINES || bytes_read >= MAX_BYTES {
                break 'projects;
            }
            let path = file.path();
            if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                continue;
            }
            let is_today = file
                .metadata()
                .and_then(|m| m.modified())
                .map(|m| chrono::DateTime::<chrono::Local>::from(m).date_naive() == day)
                .unwrap_or(false);
            if !is_today {
                continue;
            }
            let Ok(f) = std::fs::File::open(&path) else {
                continue;
            };
            use std::io::BufRead;
            for line in std::io::BufReader::new(f).lines() {
                let Ok(line) = line else { break };
                bytes_read += line.len() + 1;
                if let Some(entry) = parse_line(&line) {
                    out.push(entry);
                }
                lines_read += 1;
                if lines_read >= MAX_LINES || bytes_read >= MAX_BYTES {
                    break;
                }
            }
        }
    }
    out
}

/// Sum of `costUSD` across every model in a `stats-cache.json`'s
/// `modelUsage`, plus the cache's own `lastComputedDate` - or `None` if
/// the file does not parse as a JSON object, has no `modelUsage`, or
/// `modelUsage` has no models. All-time, not scoped to any single day:
/// this file is only ever consulted for cost, never for today's token
/// counts (see module doc).
pub fn all_time_cost(stats_cache_json: &str) -> Option<(f64, String)> {
    let v: serde_json::Value = serde_json::from_str(stats_cache_json).ok()?;
    let models = v.get("modelUsage")?.as_object()?;
    if models.is_empty() {
        return None;
    }
    let cost: f64 = models
        .values()
        .filter_map(|m| m.get("costUSD").and_then(|c| c.as_f64()))
        .sum();
    // Zero is not a cost, it is an absence.
    //
    // On a subscription plan Claude Code records no per-token cost at all:
    // measured on this machine, every one of the seven models tracked has
    // costUSD exactly 0. Passed through, the panel would read "$0.00" next
    // to a quarter of a billion cache-read tokens - which any reader would
    // take to mean they had used nothing. There is no cost data here, and
    // saying so by leaving the row out is the only honest rendering.
    if cost <= 0.0 {
        return None;
    }
    let as_of = v
        .get("lastComputedDate")
        .and_then(|d| d.as_str())
        .unwrap_or("")
        .to_string();
    Some((cost, as_of))
}

/// One refresh: today's local date and offset, the transcripts scanned
/// and folded, then whatever cost `stats-cache.json` has to offer
/// layered on top. The single side-effecting entry point, same shape as
/// `weather::fetch` - everything above this line is pure and covered by
/// fixture tests. A missing `.claude` directory, or a missing cost
/// cache, degrades to an empty/absent piece rather than an error.
pub fn fetch_today(claude_dir: &Path) -> Report {
    let now = chrono::Local::now();
    let entries = scan(claude_dir, now.date_naive());
    let mut report = totals_for_day(&entries, now.date_naive(), *now.offset());
    if let Ok(json) = std::fs::read_to_string(claude_dir.join("stats-cache.json")) {
        if let Some((cost, as_of)) = all_time_cost(&json) {
            report.all_time_cost_usd = Some(cost);
            report.cost_as_of = as_of;
        }
    }
    report
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A subscription plan records no cost, and that must not render as
    /// having cost nothing. Measured on a real machine: seven models
    /// tracked, every costUSD exactly 0. "$0.00" beside a day of heavy use
    /// is a wrong answer stated confidently; no row at all is a true one.
    #[test]
    fn a_plan_that_records_no_cost_reports_no_cost_not_zero() {
        let all_zero = r#"{"lastComputedDate":"2026-07-26","modelUsage":{
            "claude-opus-5":{"costUSD":0},"claude-haiku-4-5":{"costUSD":0}}}"#;
        assert_eq!(all_time_cost(all_zero), None);

        // And a plan that does record cost still reports it.
        let paid = r#"{"lastComputedDate":"2026-07-26","modelUsage":{
            "claude-opus-5":{"costUSD":1.5},"claude-haiku-4-5":{"costUSD":0}}}"#;
        let (cost, as_of) = all_time_cost(paid).expect("a cost");
        assert!((cost - 1.5).abs() < 1e-9);
        assert_eq!(as_of, "2026-07-26");
    }

    #[test]
    fn a_real_assistant_line_parses() {
        // The exact shape a transcript line has, verified on a real
        // machine - not guessed at.
        let line = r#"{"type":"assistant","timestamp":"2026-08-29T10:00:00.123Z","sessionId":"abc-123","cwd":"C:\\x","gitBranch":"main","message":{"model":"claude-opus-4-8","usage":{"input_tokens":6421,"output_tokens":227,"cache_creation_input_tokens":2805,"cache_read_input_tokens":32934}}}"#;
        let e = parse_line(line).expect("an entry");
        assert_eq!(e.session_id, "abc-123");
        assert_eq!(e.model, "claude-opus-4-8");
        assert_eq!(e.input_tokens, 6421);
        assert_eq!(e.output_tokens, 227);
        assert_eq!(e.cache_creation_tokens, 2805);
        assert_eq!(e.cache_read_tokens, 32934);
    }

    #[test]
    fn only_assistant_messages_with_usage_count() {
        // A user turn.
        assert!(parse_line(r#"{"type":"user","timestamp":"2026-08-29T00:00:00Z","message":{"usage":{"input_tokens":1}}}"#).is_none());
        // An assistant line that never got a usage block (e.g. an error).
        assert!(parse_line(r#"{"type":"assistant","timestamp":"2026-08-29T00:00:00Z","message":{"model":"x"}}"#).is_none());
        // A summary line, which has neither a type nor a message at all.
        assert!(parse_line(r#"{"type":"summary","summary":"..."}"#).is_none());
    }

    #[test]
    fn junk_is_nothing_not_a_panic() {
        assert!(parse_line("").is_none());
        assert!(parse_line("not json").is_none());
        assert!(parse_line("{}").is_none());
        assert!(parse_line(r#"{"type":"assistant"}"#).is_none());
        assert!(parse_line(r#"{"type":"assistant","timestamp":"not a date","message":{"usage":{}}}"#).is_none());
        // A truncated trailing line, the kind a crash mid-write leaves.
        assert!(parse_line(r#"{"type":"assistant","timestamp":"2026-08-29T00:00:00Z","message":{"usage":{"input_"#).is_none());
    }

    #[test]
    fn missing_token_fields_default_to_zero_not_a_panic() {
        let line = r#"{"type":"assistant","timestamp":"2026-08-29T00:00:00Z","sessionId":"s","message":{"model":"x","usage":{"input_tokens":5}}}"#;
        let e = parse_line(line).expect("an entry");
        assert_eq!(e.input_tokens, 5);
        assert_eq!(e.output_tokens, 0);
        assert_eq!(e.cache_creation_tokens, 0);
        assert_eq!(e.cache_read_tokens, 0);
    }

    #[test]
    fn a_missing_model_is_labeled_rather_than_dropped() {
        let line = r#"{"type":"assistant","timestamp":"2026-08-29T00:00:00Z","sessionId":"s","message":{"usage":{"input_tokens":1}}}"#;
        assert_eq!(parse_line(line).unwrap().model, "unknown");
    }

    fn entry(ts: &str, session: &str, model: &str, input: u64, output: u64, cw: u64, cr: u64) -> UsageEntry {
        UsageEntry {
            session_id: session.into(),
            model: model.into(),
            input_tokens: input,
            output_tokens: output,
            cache_creation_tokens: cw,
            cache_read_tokens: cr,
            timestamp: chrono::DateTime::parse_from_rfc3339(ts)
                .unwrap()
                .with_timezone(&chrono::Utc),
        }
    }

    #[test]
    fn totals_sum_only_the_requested_day_grouped_by_model_and_session() {
        let entries = vec![
            entry("2026-08-29T10:00:00Z", "s1", "claude-opus-4-8", 100, 20, 0, 0),
            entry("2026-08-29T11:00:00Z", "s1", "claude-opus-4-8", 50, 10, 5, 5),
            entry("2026-08-29T12:00:00Z", "s2", "claude-sonnet-5", 30, 5, 0, 0),
            // Close in wall-clock time but a different local day - must
            // not be folded in just because it is nearby.
            entry("2026-08-28T23:59:00Z", "s3", "claude-opus-4-8", 999, 999, 0, 0),
            entry("2026-08-30T00:00:01Z", "s4", "claude-opus-4-8", 999, 999, 0, 0),
        ];
        let day = chrono::NaiveDate::from_ymd_opt(2026, 8, 29).unwrap();
        let utc = chrono::FixedOffset::east_opt(0).unwrap();
        let totals = totals_for_day(&entries, day, utc);

        assert_eq!(totals.input_tokens, 180);
        assert_eq!(totals.output_tokens, 35);
        assert_eq!(totals.cache_creation_tokens, 5);
        assert_eq!(totals.cache_read_tokens, 5);
        assert_eq!(totals.messages, 3);
        // s1 appears twice but is one session.
        assert_eq!(totals.sessions, 2);

        assert_eq!(totals.by_model.len(), 2);
        assert_eq!(totals.by_model[0].model, "claude-opus-4-8");
        assert_eq!(totals.by_model[0].input_tokens, 150);
        assert_eq!(totals.by_model[0].messages, 2);
        assert_eq!(totals.by_model[1].model, "claude-sonnet-5");
        assert_eq!(totals.by_model[1].input_tokens, 30);
        assert_eq!(totals.by_model[1].messages, 1);

        // totals_for_day never touches cost - that is layered on by
        // fetch_today from a different file entirely.
        assert_eq!(totals.all_time_cost_usd, None);
        assert_eq!(totals.cost_as_of, "");
    }

    #[test]
    fn the_offset_moves_the_day_boundary_not_just_the_clock() {
        // 2026-08-29T06:00:00Z is 2026-08-28T22:00 for someone at UTC-8:
        // a message sent just after UTC midnight can still belong to
        // "yesterday" west of Greenwich, and the reverse east of it.
        let entries = vec![entry("2026-08-29T06:00:00Z", "s1", "m", 10, 0, 0, 0)];
        let west8 = chrono::FixedOffset::west_opt(8 * 3600).unwrap();
        let day_28 = chrono::NaiveDate::from_ymd_opt(2026, 8, 28).unwrap();
        let day_29 = chrono::NaiveDate::from_ymd_opt(2026, 8, 29).unwrap();
        assert_eq!(totals_for_day(&entries, day_28, west8).messages, 1);
        assert_eq!(totals_for_day(&entries, day_29, west8).messages, 0);
    }

    #[test]
    fn no_entries_is_all_zero_not_missing_fields() {
        let day = chrono::NaiveDate::from_ymd_opt(2026, 8, 29).unwrap();
        let totals = totals_for_day(&[], day, chrono::FixedOffset::east_opt(0).unwrap());
        assert_eq!(totals, Report::default());
        assert!(totals.by_model.is_empty());
    }

    // ── cost, from stats-cache.json ─────────────────────────────────────

    #[test]
    fn cost_sums_across_models_and_carries_its_own_date() {
        let json = r#"{
            "lastComputedDate": "2026-07-26",
            "modelUsage": {
                "claude-opus-4-8": {"inputTokens":1,"outputTokens":1,"costUSD":12.34},
                "claude-sonnet-5": {"inputTokens":1,"outputTokens":1,"costUSD":1.23}
            }
        }"#;
        let (cost, as_of) = all_time_cost(json).expect("a cost");
        assert!((cost - 13.57).abs() < 0.001);
        assert_eq!(as_of, "2026-07-26");
    }

    #[test]
    fn no_cost_cache_is_none_not_zero() {
        // Zero and "there is no figure" are different facts; None is
        // what lets the frontend omit the row instead of showing $0.00.
        assert_eq!(all_time_cost("not json"), None);
        assert_eq!(all_time_cost("[1,2,3]"), None);
        assert_eq!(all_time_cost("{}"), None);
        assert_eq!(all_time_cost(r#"{"modelUsage":{}}"#), None);
    }

    #[test]
    fn a_model_with_no_cost_field_is_not_a_panic() {
        // The point of this one is that a missing field is tolerated at
        // all. What it adds up to is nothing, and nothing is reported as
        // no figure rather than as zero - see the test above for why.
        let json = r#"{"lastComputedDate":"2026-07-26","modelUsage":{"claude-x":{}}}"#;
        assert_eq!(all_time_cost(json), None);

        // Tolerated alongside a model that does have one, which is the
        // case that would actually panic if the field were unwrapped.
        let mixed = r#"{"lastComputedDate":"2026-07-26","modelUsage":{
            "claude-x":{},"claude-y":{"costUSD":2.25}}}"#;
        let (cost, _) = all_time_cost(mixed).expect("the one figure there is");
        assert!((cost - 2.25).abs() < 1e-9);
    }

    /// A directory name unique per test run - a filesystem timestamp
    /// won't do on Windows, whose path syntax rejects the colons in
    /// `SystemTime`'s Debug output.
    fn unique_temp_dir(tag: &str) -> std::path::PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        std::env::temp_dir().join(format!("gterminal-claude-usage-test-{tag}-{}-{nanos}", std::process::id()))
    }

    #[test]
    fn a_missing_claude_directory_scans_to_nothing() {
        let dir = unique_temp_dir("missing");
        let day = chrono::NaiveDate::from_ymd_opt(2026, 1, 1).unwrap();
        assert!(scan(&dir, day).is_empty());
    }

    #[test]
    fn scan_reads_only_files_touched_on_the_requested_day() {
        let base = unique_temp_dir("scan");
        let proj = base.join("projects").join("proj1");
        std::fs::create_dir_all(&proj).unwrap();
        let line = format!(
            r#"{{"type":"assistant","timestamp":"{}","sessionId":"s1","message":{{"model":"claude-x","usage":{{"input_tokens":10,"output_tokens":5}}}}}}"#,
            chrono::Utc::now().to_rfc3339()
        );
        std::fs::write(proj.join("session.jsonl"), format!("{line}\n")).unwrap();
        // A non-JSONL file in the same folder must be ignored outright,
        // not fail the scan.
        std::fs::write(proj.join("notes.txt"), "not a transcript").unwrap();

        let today = chrono::Local::now().date_naive();
        let found = scan(&base, today);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].input_tokens, 10);

        // The file's mtime is today, not yesterday, so a scan for
        // yesterday must not even open it.
        let yesterday = today - chrono::Duration::days(1);
        assert!(scan(&base, yesterday).is_empty());

        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn fetch_today_layers_cost_onto_the_jsonl_totals() {
        let base = unique_temp_dir("fetch");
        let proj = base.join("projects").join("proj1");
        std::fs::create_dir_all(&proj).unwrap();
        let line = format!(
            r#"{{"type":"assistant","timestamp":"{}","sessionId":"s1","message":{{"model":"claude-x","usage":{{"input_tokens":10,"output_tokens":5}}}}}}"#,
            chrono::Utc::now().to_rfc3339()
        );
        std::fs::write(proj.join("session.jsonl"), format!("{line}\n")).unwrap();
        std::fs::write(
            base.join("stats-cache.json"),
            r#"{"lastComputedDate":"2026-07-26","modelUsage":{"claude-x":{"costUSD":9.99}}}"#,
        )
        .unwrap();

        let report = fetch_today(&base);
        assert_eq!(report.input_tokens, 10);
        assert_eq!(report.all_time_cost_usd, Some(9.99));
        assert_eq!(report.cost_as_of, "2026-07-26");

        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn fetch_today_without_a_cost_cache_still_has_tokens() {
        let base = unique_temp_dir("fetch-no-cost");
        let proj = base.join("projects").join("proj1");
        std::fs::create_dir_all(&proj).unwrap();
        let line = format!(
            r#"{{"type":"assistant","timestamp":"{}","sessionId":"s1","message":{{"model":"claude-x","usage":{{"input_tokens":7}}}}}}"#,
            chrono::Utc::now().to_rfc3339()
        );
        std::fs::write(proj.join("session.jsonl"), format!("{line}\n")).unwrap();
        // No stats-cache.json written at all.

        let report = fetch_today(&base);
        assert_eq!(report.input_tokens, 7);
        assert_eq!(report.all_time_cost_usd, None);
        assert_eq!(report.cost_as_of, "");

        let _ = std::fs::remove_dir_all(&base);
    }
}
