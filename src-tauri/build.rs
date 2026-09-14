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

    // cargo-llvm-cov compiles with --cfg=coverage; declaring it here stops
    // the unexpected-cfg lint firing on the daemon's mid-run profile flush.
    println!("cargo:rustc-check-cfg=cfg(coverage)");

    // The phone view renders with the same terminal engine as the
    // desktop window, and gets it from the same place: node_modules.
    //
    // It has to be a real emulator. The first version of that page had a
    // small hand-written ANSI reader that appended text as it arrived,
    // and a shell is not an append-only stream - PSReadLine repaints the
    // line you are typing with absolute cursor moves, and draws its
    // prediction in dim text it then overwrites. Appending all of that
    // shows every intermediate frame and every suggestion as if they
    // were output: "it shows stuff that doesn't exist and it doesn't
    // show what's on the shell", which is exactly what it was doing.
    //
    // Copied into OUT_DIR rather than read at run time, so the binary
    // carries it and a phone needs nothing from the network.
    let out = std::path::PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR"));
    for (from, to) in [
        ("../node_modules/@xterm/xterm/lib/xterm.js", "xterm.js"),
        ("../node_modules/@xterm/xterm/css/xterm.css", "xterm.css"),
    ] {
        println!("cargo:rerun-if-changed={from}");
        let body = std::fs::read(from).unwrap_or_else(|e| {
            panic!("{from} is missing ({e}) - run `npm ci` before building; the remote page is served out of it")
        });
        std::fs::write(out.join(to), body).expect("write the terminal engine into OUT_DIR");
    }

    tauri_build::build()
}
