fn main() {
    // The frontend is baked into the binary at compile time, but cargo
    // only watches Rust sources, so editing the UI and rebuilding gives
    // you the *old* UI in a binary with a fresh timestamp — a trap that
    // silently invalidates any test run against it. Watch dist\ so a vite
    // build is enough to make cargo re-embed.
    println!("cargo:rerun-if-changed=../dist");

    // The crate version and the app version were two different numbers.
    // Cargo.toml still said 0.2.0 while the app shipped as 0.12.0, and
    // anything reading CARGO_PKG_VERSION reported the wrong one: the
    // daemon announced itself as 0.2.0 over the wire, named its copied
    // binary gterminal-daemon-0.2.0.exe, and the notice about an outdated
    // daemon would have told the user a version that does not exist.
    //
    // tauri.conf.json is the number that ships, so it is the one that
    // counts. Read it here and hand it to the code as GTERMINAL_VERSION.
    println!("cargo:rerun-if-changed=tauri.conf.json");
    let conf = std::fs::read_to_string("tauri.conf.json").expect("read tauri.conf.json");
    let version = conf
        .split(r#""version""#)
        .nth(1)
        .and_then(|rest| rest.split('"').nth(1))
        .expect("tauri.conf.json has a version");
    println!("cargo:rustc-env=GTERMINAL_VERSION={version}");

    // Which build this is. Empty for the one that ships to the Store; "dev"
    // for the installer built to try things out on a real machine without
    // waiting on certification.
    //
    // It decides the state directory, and that is the whole point of it: a
    // test build sharing %LOCALAPPDATA%\GTerminal would share the daemon
    // holding somebody's live sessions. That is not hypothetical - a
    // side-by-side package did exactly that here, attached to the running
    // daemon and took a session out of a window that was in use.
    println!("cargo:rerun-if-env-changed=GTERMINAL_CHANNEL");
    let channel = std::env::var("GTERMINAL_CHANNEL").unwrap_or_default();
    let channel = channel.trim().to_lowercase();
    // Anything that would leave the path ambiguous or escape the folder is
    // refused outright rather than sanitised into something surprising.
    if !channel.is_empty() && !channel.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        panic!("GTERMINAL_CHANNEL must be alphanumeric or '-', got {channel:?}");
    }
    println!("cargo:rustc-env=GTERMINAL_CHANNEL={channel}");

    tauri_build::build()
}
