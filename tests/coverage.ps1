# Measure what the tests actually reach, in both languages.
# Run: npm run coverage
#
# Two measurements, because the project is two things:
#
#   TypeScript - c8 around every node suite. These cover the extracted
#     modules; main.ts is webview code a node-side tool cannot see, and
#     tests/coverage-report.mjs says so rather than averaging it in.
#
#   Rust - cargo-llvm-cov over the unit tests AND the E2E suites. The
#     binary is instrumented and lifecycle.ps1 / typing.ps1 run against
#     it, which is what makes the daemon count: on unit tests alone mux.rs
#     reads 32%, with the suites it reads 87%.
#
#     Getting that to work took two wrong answers worth recording. The
#     first was that the daemon runs from a self-copy llvm-cov cannot
#     attribute - it does copy itself (mux::daemon_binary), but the suites
#     run `$exe --daemon` directly, so that was never in the path. The
#     real cause is that an instrumented process writes its .profraw from
#     an exit handler and every suite stops the daemon with taskkill /F.
#     The second wrong answer was flushing the profile periodically
#     without resetting: LLVM_PROFILE_FILE carries %m, so each flush
#     re-merged the cumulative counters until llvm-profdata called them
#     corrupt and refused to merge anything at all. See mux::flush_coverage.
#
# Neither number is "the coverage of GTerminal", and the report says which
# part each one measured. The window and the Tauri command layer are still
# outside it - nothing here runs a window.

param(
  [switch]$SkipRust,
  [switch]$SkipTs,
  # Skip the E2E suites. Much faster and much less true: without them
  # mux.rs reads 32% instead of 87%, because the daemon is only exercised
  # by lifecycle.ps1 and typing.ps1.
  [switch]$SkipE2E,
  # Also run the visual scenes, instrumented. That is where most of what
  # lib.rs does actually happens - run, the window event handler, summon,
  # leave, the tray - none of which any other suite touches.
  #
  # Not the default, and not because it adds nothing: it takes about forty
  # minutes, and it takes over the keyboard and the foreground while it
  # does. It belongs on a runner, or on a machine nobody is sitting at.
  [switch]$WithVisual
)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
Push-Location $repo
try {
  # Both leaves, not just the root: llvm-cov writes its lcov to a path it
  # will not create, and fails with "cannot find the path specified" after
  # having run every test.
  foreach ($d in "coverage", "coverage/ts", "coverage/rust") {
    New-Item -ItemType Directory -Force (Join-Path $repo $d) | Out-Null
  }

  if (-not $SkipTs) {
    Write-Host "== TypeScript ==" -ForegroundColor Cyan
    # --all so a module with no test at all still appears, at 0%, instead
    # of vanishing from the report and taking the problem with it.
    & npx c8 `
      --reporter=json-summary --reporter=lcov --reporter=html `
      --src=src --all --exclude='tests/**' `
      --report-dir=coverage/ts `
      node tests/run-node.mjs
    if ($LASTEXITCODE -ne 0) { throw "the node suites failed under coverage ($LASTEXITCODE)" }
  }

  if (-not $SkipRust) {
    Write-Host "== Rust ==" -ForegroundColor Cyan
    if (-not (Get-Command cargo-llvm-cov -ErrorAction SilentlyContinue)) {
      throw "cargo-llvm-cov is not installed. cargo install cargo-llvm-cov --locked"
    }
    # Its own target directory, never the repo's.
    #
    # The E2E suites drive src-tauri	arget\debug\gterminal.exe, and that
    # is frequently a binary somebody is running - on Windows the file is
    # then locked, the build fails with "Access is denied", and building
    # over it would take their terminal down anyway. Build the instrumented
    # copy somewhere else and point the suites at it with -Exe.
    $env:CARGO_TARGET_DIR = Join-Path $env:TEMP "gterminal-coverage-target"
    $covExe = Join-Path $env:CARGO_TARGET_DIR "debug\gterminal.exe"
    Push-Location (Join-Path $repo "src-tauri")
    try {
      & cargo llvm-cov clean --workspace
      if ($LASTEXITCODE -ne 0) { throw "cargo llvm-cov clean failed ($LASTEXITCODE)" }

      # Instrument, then run things ourselves and collect afterwards.
      #
      # Unit tests alone paint a false picture here: mux.rs is the daemon
      # and lifecycle.ps1 drives it hard, but it drives the BUILT BINARY as
      # a separate process, so none of that counted and mux.rs read as 30%.
      # Instrumenting the binary and running the E2E suites against it
      # measures the tests this project actually relies on.
      foreach ($line in (& cargo llvm-cov show-env)) {
        if ($line -match "^([A-Za-z_][A-Za-z0-9_]*)=(.*)$") {
          Set-Item -Path ("env:" + $Matches[1]) -Value $Matches[2].Trim("'")
        }
      }

      & cargo test --lib
      if ($LASTEXITCODE -ne 0) { throw "the unit tests failed under coverage ($LASTEXITCODE)" }

      if (-not $SkipE2E) {
        # The suites run this exact path, so building it here is what makes
        # them count.
        & cargo build
        if ($LASTEXITCODE -ne 0) { throw "the instrumented build failed ($LASTEXITCODE)" }
        Pop-Location
        Push-Location $repo
        foreach ($suite in "tests/lifecycle.ps1", "tests/typing.ps1") {
          Write-Host "-- $suite (instrumented)" -ForegroundColor DarkGray
          & pwsh -NoProfile -File $suite -Exe $covExe
          # Not fatal: a suite that fails still leaves coverage worth
          # reporting, and its failure is the other suites' business to
          # report rather than this script's.
          if ($LASTEXITCODE -ne 0) {
            Write-Host "   note: $suite failed; its coverage still counts" -ForegroundColor DarkYellow
          }
        }
        if ($WithVisual) {
          # The scenes need the frontend baked into the binary: a plain
          # cargo build points the window at the dev server on :1420, and
          # every scene would photograph a blank window. Built here under
          # the same instrumented environment.
          Write-Host "-- building the app with its UI embedded" -ForegroundColor DarkGray
          & npx tauri build --debug --no-bundle
          if ($LASTEXITCODE -ne 0) { throw "the instrumented app build failed ($LASTEXITCODE)" }
          Write-Host "-- tests/visual.ps1 (instrumented, takes the foreground)" -ForegroundColor DarkGray
          & pwsh -NoProfile -File tests/visual.ps1 -Yes -Force -Exe $covExe
          if ($LASTEXITCODE -ne 0) {
            Write-Host "   note: visual.ps1 failed; its coverage still counts" -ForegroundColor DarkYellow
          }
        }
        Pop-Location
        Push-Location (Join-Path $repo "src-tauri")
      }

      & cargo llvm-cov report --lcov --output-path ../coverage/rust/lcov.info
      if ($LASTEXITCODE -ne 0) { throw "cargo llvm-cov report failed ($LASTEXITCODE)" }
      # The browsable version, for when a number is not enough.
      & cargo llvm-cov report --html --output-dir ../coverage/rust
      if ($LASTEXITCODE -ne 0) { throw "cargo llvm-cov report --html failed ($LASTEXITCODE)" }
    } finally {
      Pop-Location
      # Nothing to restore: the repo's own target directory was never
      # touched, which is the point of building elsewhere.
      Remove-Item Env:CARGO_TARGET_DIR -ErrorAction SilentlyContinue
      foreach ($v in "RUSTC_WRAPPER", "LLVM_PROFILE_FILE", "CARGO_LLVM_COV", "CARGO_LLVM_COV_SHOW_ENV",
                     "CARGO_LLVM_COV_TARGET_DIR", "CARGO_LLVM_COV_BUILD_DIR",
                     "__CARGO_LLVM_COV_RUSTC_WRAPPER", "__CARGO_LLVM_COV_RUSTC_WRAPPER_RUSTFLAGS",
                     "__CARGO_LLVM_COV_RUSTC_WRAPPER_CRATE_NAMES") {
        Remove-Item ("env:" + $v) -ErrorAction SilentlyContinue
      }
    }
  }

  & node tests/coverage-report.mjs
  if ($LASTEXITCODE -ne 0) { throw "the report could not be built ($LASTEXITCODE)" }
} finally {
  Pop-Location
}
