# Packages the release build as an MSIX.
# Requires: a prior `tauri build` (release exe) and the Windows 10/11 SDK
# (makeappx + signtool).
# Default: signs with a self-signed cert (created if absent) and exports the
# .cer next to the package so users can trust-install it.
# -ForStore: stamps the Partner Center publisher identity and skips signing
# (the Store signs on ingestion) - this is the package the publish pipeline
# submits for product 9PBXQ1K155G7.
# Run: pwsh tools/make-msix.ps1 [-ForStore]
param([switch] $ForStore)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$repo = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $repo "src-tauri\target\release\gterminal.exe"
if (-not (Test-Path $exe)) { throw "release exe not found - run 'npx tauri build' first" }

# version from tauri.conf.json (MSIX wants four parts)
$conf = Get-Content (Join-Path $repo "src-tauri\tauri.conf.json") -Raw | ConvertFrom-Json
$version = $conf.version
$msixVersion = "$version.0"

# newest Windows SDK bin with the tools we need
$sdkRoot = "C:\Program Files (x86)\Windows Kits\10\bin"
$sdk = Get-ChildItem $sdkRoot -Directory -ErrorAction Stop |
  Where-Object { Test-Path (Join-Path $_.FullName "x64\makeappx.exe") } |
  Sort-Object Name -Descending | Select-Object -First 1
if (-not $sdk) { throw "Windows SDK with makeappx.exe not found under $sdkRoot" }
$makeappx = Join-Path $sdk.FullName "x64\makeappx.exe"
$signtool = Join-Path $sdk.FullName "x64\signtool.exe"

$stage = Join-Path $env:TEMP "gterminal-msix-stage"
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force (Join-Path $stage "Assets") | Out-Null
Copy-Item $exe (Join-Path $stage "gterminal.exe")

# scaled logos from the 256px icon
$src = [System.Drawing.Image]::FromFile((Join-Path $repo "src-tauri\icons\128x128@2x.png"))
foreach ($spec in @(@("Square44x44Logo.png", 44), @("Square150x150Logo.png", 150), @("StoreLogo.png", 50))) {
  $size = $spec[1]
  $bmp = New-Object System.Drawing.Bitmap($size, $size)
  $gfx = [System.Drawing.Graphics]::FromImage($bmp)
  $gfx.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $gfx.DrawImage($src, 0, 0, $size, $size)
  $gfx.Dispose()
  $bmp.Save((Join-Path $stage ("Assets\" + $spec[0])), [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}
$src.Dispose()

# Sideload builds sign with the self-signed cert, so the Publisher must match its
# subject. Store builds must instead carry the Partner Center publisher identity
# (Partner Center > Product identity) - the Store rejects any other value.
$publisher = if ($ForStore) { "CN=119E0257-3B74-437C-A728-AC7C50256853" } else { "CN=Gus Catalano" }

$manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
         xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
         xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities">
  <Identity Name="GusCatalano.GTerminal" Publisher="$publisher" Version="$msixVersion" ProcessorArchitecture="x64"/>
  <Properties>
    <DisplayName>GTerminal</DisplayName>
    <PublisherDisplayName>Gus Catalano</PublisherDisplayName>
    <Logo>Assets\StoreLogo.png</Logo>
  </Properties>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.17763.0" MaxVersionTested="10.0.26100.0"/>
  </Dependencies>
  <Resources><Resource Language="en-us"/></Resources>
  <Capabilities><rescap:Capability Name="runFullTrust"/></Capabilities>
  <Applications>
    <Application Id="GTerminal" Executable="gterminal.exe" EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements DisplayName="GTerminal"
        Description="Lightweight terminal with tmux-style persistent sessions"
        BackgroundColor="transparent"
        Square150x150Logo="Assets\Square150x150Logo.png"
        Square44x44Logo="Assets\Square44x44Logo.png"/>
    </Application>
  </Applications>
</Package>
"@
Set-Content (Join-Path $stage "AppxManifest.xml") $manifest -Encoding UTF8

$outDir = Join-Path $repo "src-tauri\target\release\bundle\msix"
New-Item -ItemType Directory -Force $outDir | Out-Null
$suffix = if ($ForStore) { "_store" } else { "" }
$msix = Join-Path $outDir "GTerminal_${version}_x64$suffix.msix"
Remove-Item $msix -ErrorAction SilentlyContinue
& $makeappx pack /d $stage /p $msix /o | Select-Object -Last 1

if ($ForStore) {
  # Unsigned on purpose: the Store signs the package on ingestion.
  Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
  "msix (store, unsigned): $msix"
} else {
  $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq "CN=Gus Catalano" -and $_.FriendlyName -eq "GTerminal MSIX signing" } | Select-Object -First 1
  if (-not $cert) {
    $cert = New-SelfSignedCertificate -Type Custom -Subject "CN=Gus Catalano" `
      -KeyUsage DigitalSignature -FriendlyName "GTerminal MSIX signing" `
      -CertStoreLocation "Cert:\CurrentUser\My" `
      -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}")
  }
  & $signtool sign /fd SHA256 /sha1 $cert.Thumbprint $msix | Select-Object -Last 1
  Export-Certificate -Cert $cert -FilePath (Join-Path $outDir "GTerminal-signing.cer") | Out-Null
  Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
  "msix: $msix"
  "cert: $(Join-Path $outDir 'GTerminal-signing.cer')"
}
