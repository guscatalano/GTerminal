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


# Ctrl+C must reach the shells these suites start.
#
# SetConsoleCtrlHandler(NULL, TRUE) makes a process ignore Ctrl+C, and
# that state is INHERITED by every process it starts. A terminal launched
# by a shell which had it set passes it to its daemon, which passes it to
# the shells, which pass it to whatever those run - so Ctrl+C interrupts
# nothing anywhere in the tree, no matter how correctly the byte is
# delivered.
#
# That is a property of whoever started the suite, not of the terminal
# being tested, and it cost a long investigation to find: three tests
# failing for one reason, ping and Start-Sleep both unkillable, the
# console input mode measured and cleared, the daemon spawned every way
# the app spawns it, 0.6.0 built from its tag to compare against, and the
# app all the while interrupting perfectly well because Explorer never
# passed it down. Re-enabling it here costs one call and removes the whole
# class of confusion.
function Enable-CtrlCHandling {
  if (-not ("GTermGate.CtrlC" -as [type])) {
    Add-Type -Namespace GTermGate -Name CtrlC -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
'@ | Out-Null
  }
  [GTermGate.CtrlC]::SetConsoleCtrlHandler([IntPtr]::Zero, $false)
}
