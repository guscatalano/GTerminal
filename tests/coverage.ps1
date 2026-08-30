# Measure what the tests actually reach, in both languages.
# Run: npm run coverage
#
# Two measurements, because the project is two things:
#
#   TypeScript - c8 around every node suite. These cover the extracted
#     modules; main.ts is webview code a node-side tool cannot see, and
#     tests/coverage-report.mjs says so rather than averaging it in.
#
#   Rust - cargo-llvm-cov over the unit tests only.
#
#     Running the E2E suites under instrumentation was tried and does not
#     work, which is worth writing down because it looks like it should.
#     The daemon copies itself to <state dir>in\gterminal-daemon-<ver>.exe
#     and runs from there (see mux::daemon_binary - it exists so a Store
#     update is not blocked by the running daemon holding its own file).
#     llvm-cov can only attribute counters to objects it was given, that
#     copy is not one of them, and cargo-llvm-cov exposes no --object to
#     add it. Measured either way: the daemon accept loop reports zero
#     hits, and the whole report comes out byte-identical with the suites
#     run and without them. Fifteen minutes for no signal.
#
# Neither number is "the coverage of GTerminal", and the report says which
# part each one measured. That is the most a coverage report can honestly
# be in a project whose remaining tests drive a real window - which no
# coverage tool here can see at all.
param(
  [switch]$SkipRust,
  [switch]$SkipTs,
  # Run the E2E suites under instrumentation anyway. Off by default
  # because it currently adds nothing to the report - see the note at the
  # top - and kept only so the next person to try can start from that
  # finding rather than rediscover it.
  [switch]$WithE2E
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

      if ($WithE2E) {
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
