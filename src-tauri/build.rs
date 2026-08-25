fn main() {
    // The legacy windowed tauri.conf.json (with WebView windows/bundle)
    // has been removed. The native Swift build uses the headless
    // tauri.core.conf.json. tauri_build hard-codes the lookup for
    // tauri.conf.json, so generate a transient stub from the core config
    // at build time if the legacy file is absent. The stub is .gitignore'd
    // and not committed — the repository intentionally no longer tracks a
    // windowed UI config.
    let manifest = std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let legacy = manifest.join("tauri.conf.json");
    let core = manifest.join("tauri.core.conf.json");
    if !legacy.exists() {
        if let Err(e) = std::fs::copy(&core, &legacy) {
            eprintln!("build.rs: failed to create transient tauri.conf.json from core: {e}");
        } else {
            println!("cargo:rerun-if-changed=tauri.core.conf.json");
        }
    }
    tauri_build::build()
}
