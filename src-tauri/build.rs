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

    tauri_build::build()
}
