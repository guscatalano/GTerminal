# Is someone using this machine right now?
#
# Anything that takes the foreground and types must ask first. The check
# used to live inside visual.ps1, which meant every one-off probe written
# to chase a bug bypassed it — and that is exactly how keystrokes end up
# in someone's work. It lives here so there is one gate and no version of
# it that a script can forget to include.
#
#   . "$PSScriptRoot\lib\attended.ps1"
#   Assert-Unattended            # exits 2 if the machine is in use
#   Assert-Unattended -Force     # caller has explicit permission

$script:AttendedSig = @'
[DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
'@
$script:AttendedType = Add-Type -MemberDefinition $script:AttendedSig -Name Attended -Namespace GTermGate -PassThru |
  Where-Object { $_.Name -eq "Attended" }

function Get-IdleSeconds {
  $i = New-Object 'GTermGate.Attended+LASTINPUTINFO'
  $i.cbSize = 8
  [void]$script:AttendedType::GetLastInputInfo([ref]$i)
  [int](([Environment]::TickCount - $i.dwTime) / 1000)
}

function Assert-Unattended {
  param([switch]$Force, [int]$RequiredIdle = 120, [string]$What = "This")
  if ($Force) { return }
  $idle = Get-IdleSeconds
  if ($idle -lt $RequiredIdle) {
    Write-Host ""
    Write-Host "  Not running: the keyboard or mouse was used $idle second(s) ago." -ForegroundColor Yellow
    Write-Host "  $What takes over the foreground and types; anything you are" -ForegroundColor Yellow
    Write-Host "  working in would receive it." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Run it when the machine is free, or pass -Force to override." -ForegroundColor Yellow
    exit 2
  }
}
