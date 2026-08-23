fn main() {
    // The frontend is baked into the binary at compile time, but cargo
    // only watches Rust sources, so editing the UI and rebuilding gives
    // you the *old* UI in a binary with a fresh timestamp — a trap that
    // silently invalidates any test run against it. Watch dist\ so a vite
    // build is enough to make cargo re-embed.
    println!("cargo:rerun-if-changed=../dist");
    tauri_build::build()
}
