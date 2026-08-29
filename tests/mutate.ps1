# Do the tests actually catch the bugs they are named after?
#
# A passing test proves nothing on its own. Several of the tests in this
# repository passed against the very behaviour they were written to catch
# - a scene that clicked a button which was never there, a replay check
# that ran against an empty replay, a paste test that could not tell one
# paste from two. Each was found by breaking the app on purpose and
# watching the test stay green, and every one of those checks was done by
# hand and left nothing behind.
#
# This is that, written down. Each entry breaks something specific and
# names the checks that must fail because of it. A mutation nobody
# catches is reported as loudly as a failing test, because it means the
# test guarding it is decoration.
#
# Run: npm run test:mutate            (all of them)
#      npm run test:mutate -- -Only paste-twice
#
# It rebuilds the app once per mutation, so it takes minutes rather than
# seconds. That is the price of knowing.
param(
  [string]$Only,
  [switch]$Force,
  [switch]$Yes
)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path $env:TEMP "gterminal-mutate"
$target = Join-Path $scratch "target"
New-Item -ItemType Directory -Force $scratch | Out-Null

# Each mutation: what to break, and which checks must notice.
#
# Find text has to be unique in the file - the runner refuses rather than
# guess, because a mutation that lands somewhere unintended tests nothing
# and blames the wrong guard.
$mutations = @(
  @{
    Name = "paste-twice"
    What = "paste the clipboard a second time"
    File = "src/main.ts"
    Find = 'function pasteText(id: number, text: string, source = "unknown") {'
    With = 'function pasteText(id: number, text: string, source = "unknown") {' + "`n" + '  invoke("write_session", { id, data: text }).catch(() => {});'
    Check = "visual:pasteonce"
  },
  @{
    Name = "close-last-tab-closes-window"
    What = "close the window when the last tab closes"
    File = "src/main.ts"
    Find = '  if (wasLastTab) await createTab();' + "`n" + '  window.setTimeout(() => refreshChrome(), 500);'
    With = '  if (wasLastTab) await getCurrentWindow().close();' + "`n" + '  window.setTimeout(() => refreshChrome(), 500);'
    Check = "visual:closeall"
  },
  @{
    Name = "replay-answers-questions"
    What = "replay a scrollback with its questions left in"
    File = "src-tauri/src/mux.rs"
    Find = 'let replay = strip_queries(&String::from_utf8_lossy(&s.ring));'
    With = 'let replay = String::from_utf8_lossy(&s.ring).into_owned();'
    Check = "lifecycle"
  },
  @{
    Name = "record-the-alternate-screen"
    What = "keep full-screen drawing in the scrollback"
    File = "src-tauri/src/mux.rs"
    Find = 'let keep = s.ring_filter.keep(&buf[..n]);'
    With = 'let keep = buf[..n].to_vec();'
    Check = "lifecycle"
  },
  @{
    Name = "replay-keeps-mouse-mode"
    What = "hand over a replay without putting the modes back"
    File = "src-tauri/src/mux.rs"
    Find = 'replay.push_str(MODE_RESET_INLINE);'
    # Slices the reset down to nothing rather than deleting the line: the
    # constant and the variable both stay used, so the build still
    # compiles and the mutation is about behaviour rather than syntax.
    With = 'replay.push_str(&MODE_RESET_INLINE[..0]);'
    Check = "lifecycle"
  },
  @{
    Name = "maximize-keeps-the-focus"
    What = "leave focus on the maximize button after it is clicked"
    File = "src/main.ts"
    Find = '    await win.toggleMaximize();' + "`n" + '    void markMaximized();' + "`n" + '    handBackToTerminal();'
    With = '    await win.toggleMaximize();' + "`n" + '    void markMaximized();'
    Check = "visual:maxtop"
  },
  @{
    Name = "tabs-below-the-top-edge"
    What = "keep the maximized tab row's top padding, so its first pixels are not tab"
    # Renaming the selector rather than deleting the rule: the rule stays
    # in the file for the stylesheet test to find, and only stops applying
    # to the window - which is the shape the bug had.
    File = "src/styles.css"
    Find = '#app.maximized #tabbar-row {'
    With = '#app.was-maximized #tabbar-row {'
    Check = "visual:maxtop"
  },
  @{
    Name = "update-installs-from-anywhere"
    What = "accept an installer URL from any host the releases list names"
    File = "src-tauri/src/update.rs"
    Find = '        if !url.starts_with("https://github.com/guscatalano/GTerminal/releases/download/") {'
    With = '        if false {'
    Check = "rust"
  },
  @{
    Name = "update-ignores-a-pin"
    What = "update past a pinned version"
    File = "src-tauri/src/update.rs"
    Find = '    if let Some(pin) = pinned {'
    With = '    if let Some(pin) = None::<&str> {'
    Check = "rust"
  },
  @{
    Name = "update-compares-versions-as-text"
    What = "compare versions as text, so 0.12.9 looks newer than 0.12.10"
    File = "src-tauri/src/update.rs"
    Find = '    let (a, b) = (parts(a), parts(b));'
    With = '    if true { return a.trim_start_matches(''v'').cmp(b.trim_start_matches(''v'')); }' + "`n" + '    let (a, b) = (parts(a), parts(b));'
    Check = "rust"
  },
  @{
    Name = "store-install-updates-itself"
    What = "let a Store install run an MSI over itself"
    File = "src-tauri/src/update.rs"
    Find = '    !packaged'
    With = '    let _ = packaged; true'
    Check = "rust"
  },
  @{
    Name = "dev-channel-shares-the-real-state-dir"
    What = "put a test build's daemon in the folder holding real sessions"
    File = "src-tauri/src/mux.rs"
    Find = '        format!("GTerminal-{channel}")'
    With = '        "GTerminal".to_string()'
    Check = "rust"
  },
  @{
    Name = "minify-with-esbuild"
    What = "minify with the bundler that breaks xterm's enums"
    File = "vite.config.ts"
    Find = 'minify: "terser",'
    With = 'minify: "esbuild",'
    Check = "bundle"
  }
)

if ($Only) { $mutations = @($mutations | Where-Object { $_.Name -eq $Only }) }
if (-not $mutations.Count) { Write-Host "no mutation by that name" -ForegroundColor Red; exit 2 }

# The suites do not all run the same binary. The visual scenes take one
# on the command line; lifecycle and typing run the repo's own debug
# build from its default location. Building only one of those is how a
# mutation gets tested against an unmutated app - which this runner did
# on its first outing, and reported the guard as useless.
function Build-For {
  param([string]$check)
  Push-Location $repo
  try {
    if ($check -like "visual:*") {
      $env:CARGO_TARGET_DIR = $target
      & npm run build 2>&1 | Out-Null
      & npx tauri build --debug --no-bundle 2>&1 | Out-Null
      Remove-Item Env:CARGO_TARGET_DIR
      $exe = Join-Path $target "debug\gterminal.exe"
      if (-not (Test-Path $exe)) { throw "build produced no binary" }
      return $exe
    }
    # A daemon left running holds the exe open and the build fails
    # silently into a stale binary. Only ever this repo's own build.
    $repoExe = Join-Path $repo 'src-tauri\target\debug\gterminal.exe'
    Get-CimInstance Win32_Process | Where-Object { $_.Name -like "gterminal*" } | ForEach-Object {
      # This repo's own build, and the copies the suites run from their
      # scratch directories. Never anything under WindowsApps, which is
      # somebody's installed app holding their live shells.
      $mine = ($_.ExecutablePath -eq $repoExe) -or
              ($_.ExecutablePath -like "*gterminal-*-test*") -or
              ($_.ExecutablePath -like "$([regex]::Escape($target))*")
      if ($mine -and $_.ExecutablePath -notlike "*WindowsApps*") {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
      }
    }
    Start-Sleep -Seconds 1
    & npm run build 2>&1 | Out-Null
    $buildLog = & cargo build --manifest-path src-tauri/Cargo.toml 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
      # Printed rather than swallowed: the first failure here was a
      # daemon holding the exe open, and "cargo build failed" on its own
      # sent the search in the wrong direction.
      Write-Host $buildLog -ForegroundColor DarkGray
      throw "cargo build failed"
    }
    return $null
  } finally { Pop-Location }
}

# Runs a check and reports whether it FAILED, which is what is wanted.
function Invoke-Check {
  param([string]$check, [string]$exe)
  Push-Location $repo
  try {
    switch -Regex ($check) {
      '^visual:(.+)$' {
        $scene = $Matches[1]
        $args = @("run", "test:visual", "--", "-Yes", "-Only", $scene, "-Exe", $exe)
        if ($Force) { $args += "-Force" }
        & npm @args 2>&1 | Out-String -OutVariable out | Out-Null
        return @{ Failed = ($LASTEXITCODE -ne 0); Output = $out }
      }
      '^lifecycle$' {
        & npm run test:lifecycle 2>&1 | Out-String -OutVariable out | Out-Null
        return @{ Failed = ($LASTEXITCODE -ne 0); Output = $out }
      }
      '^rust$' {
        & cargo test --manifest-path src-tauri/Cargo.toml --lib 2>&1 | Out-String -OutVariable out | Out-Null
        return @{ Failed = ($LASTEXITCODE -ne 0); Output = $out }
      }
      '^bundle$' {
        & node tests/bundle.mjs 2>&1 | Out-String -OutVariable out | Out-Null
        return @{ Failed = ($LASTEXITCODE -ne 0); Output = $out }
      }
      default { throw "unknown check: $check" }
    }
  } finally { Pop-Location }
}

$uncaught = @()
foreach ($m in $mutations) {
  $path = Join-Path $repo $m.File
  $original = Get-Content $path -Raw
  $hits = ([regex]::Matches($original, [regex]::Escape($m.Find))).Count
  if ($hits -ne 1) {
    Write-Host "SKIP $($m.Name): its anchor appears $hits times in $($m.File), so the mutation would land somewhere unintended" -ForegroundColor Yellow
    $uncaught += "$($m.Name) (anchor no longer unique)"
    continue
  }
  Write-Host "── $($m.Name): $($m.What)" -ForegroundColor Cyan
  try {
    Set-Content -Path $path -Value ($original.Replace($m.Find, $m.With)) -NoNewline
    $exe = $null
    # Neither of these needs the app built: the bundle check reads dist,
    # and cargo test compiles what it runs. Sending them through Build-For
    # would also make a mutation that does not compile abort the whole run
    # instead of being reported as the one entry it is.
    if ($m.Check -eq "bundle") { Push-Location $repo; & npm run build 2>&1 | Out-Null; Pop-Location }
    elseif ($m.Check -eq "rust") { }
    else { $exe = Build-For $m.Check }
    $r = Invoke-Check $m.Check $exe
    if ($r.Failed) {
      Write-Host "   caught by $($m.Check)" -ForegroundColor Green
    } else {
      Write-Host "   NOT CAUGHT - $($m.Check) passed with this broken on purpose" -ForegroundColor Red
      $uncaught += "$($m.Name): $($m.Check) did not notice"
    }
  } finally {
    # Always, whatever happened. A mutation left behind is a bug shipped.
    Set-Content -Path $path -Value $original -NoNewline
  }
}

# Put the tree back exactly as it was found, including anything built
# from a mutated source - a stale binary outlives the mutation that made
# it and would quietly poison the next run of anything.
Push-Location $repo
try {
  & npm run build 2>&1 | Out-Null
  & cargo build --manifest-path src-tauri/Cargo.toml 2>&1 | Out-Null
} finally { Pop-Location }

if ($uncaught.Count) {
  Write-Host ""
  Write-Host "mutations nobody caught:" -ForegroundColor Red
  $uncaught | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
  exit 1
}
Write-Host ""
Write-Host "every mutation was caught" -ForegroundColor Green
