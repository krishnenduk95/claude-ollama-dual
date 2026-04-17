# install-service.ps1 — install claude-dual proxy as a persistent Windows service
#
# Strategy:
#   1. If NSSM is installed → install a proper Windows service (preferred, supports crash recovery).
#   2. Otherwise → fall back to a scheduled task at user logon (less robust but works without extras).
#
# Run in an elevated PowerShell session (NSSM path) or a regular one (Task Scheduler path).

$ErrorActionPreference = 'Stop'
$ServiceName = 'claude-dual-proxy'
$TaskName = 'ClaudeDualProxy'
$ProxyScript = Join-Path $env:USERPROFILE '.claude-dual\proxy.js'
$LogFile = Join-Path $env:USERPROFILE '.claude-dual\proxy.log'
$ErrFile = Join-Path $env:USERPROFILE '.claude-dual\proxy.err.log'

function Resolve-NodeExe {
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) {
    throw "node.exe not found on PATH. Install Node.js 18+ from https://nodejs.org"
  }
  return $node.Source
}

function Test-NSSM {
  return (Get-Command nssm -ErrorAction SilentlyContinue) -ne $null
}

$nodeExe = Resolve-NodeExe

if (-not (Test-Path $ProxyScript)) {
  throw "Proxy script not found: $ProxyScript. Run install.ps1 first to copy files."
}

# Ensure log directory exists
$logDir = Split-Path $LogFile -Parent
if (-not (Test-Path $logDir)) {
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

if (Test-NSSM) {
  Write-Host "[claude-dual] NSSM detected — installing as Windows service..." -ForegroundColor Cyan

  # Stop + remove existing service (idempotent)
  $existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
  if ($existing) {
    Write-Host "  existing service found — stopping and removing"
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    & nssm remove $ServiceName confirm | Out-Null
  }

  # Install
  & nssm install $ServiceName $nodeExe $ProxyScript | Out-Null
  & nssm set $ServiceName AppStdout $LogFile | Out-Null
  & nssm set $ServiceName AppStderr $ErrFile | Out-Null
  & nssm set $ServiceName Start SERVICE_AUTO_START | Out-Null
  & nssm set $ServiceName AppRotateFiles 1 | Out-Null
  & nssm set $ServiceName AppRotateBytes 10485760 | Out-Null  # rotate log at 10 MB
  & nssm set $ServiceName Description 'claude-dual proxy — routes Claude Opus + GLM via Ollama' | Out-Null

  Start-Service -Name $ServiceName
  Write-Host "[claude-dual] service '$ServiceName' installed and started" -ForegroundColor Green
  Write-Host "  stop:  Stop-Service $ServiceName"
  Write-Host "  logs:  Get-Content $LogFile -Tail 20 -Wait"
  Write-Host "  remove: .\uninstall-service.ps1"
} else {
  Write-Host "[claude-dual] NSSM not found — falling back to Task Scheduler (AtLogon)..." -ForegroundColor Yellow
  Write-Host "  For better crash recovery, install NSSM: https://nssm.cc/"

  # Remove existing task if present
  $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($existing) {
    Write-Host "  existing task found — removing"
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
  }

  $action = New-ScheduledTaskAction -Execute $nodeExe -Argument "`"$ProxyScript`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartOnFailure -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 5
  $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive

  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'claude-dual proxy — routes Claude Opus + GLM via Ollama' | Out-Null
  Start-ScheduledTask -TaskName $TaskName

  Write-Host "[claude-dual] scheduled task '$TaskName' registered and started" -ForegroundColor Green
  Write-Host "  stop:   Stop-ScheduledTask -TaskName $TaskName"
  Write-Host "  logs:   Get-Content '$LogFile' -Tail 20 -Wait"
  Write-Host "  remove: .\uninstall-service.ps1"
}

# Health check
Start-Sleep -Seconds 2
try {
  $result = Test-NetConnection -ComputerName 127.0.0.1 -Port 3456 -InformationLevel Quiet -WarningAction SilentlyContinue
  if ($result) {
    Write-Host "[claude-dual] proxy listening on 127.0.0.1:3456 ✓" -ForegroundColor Green
  } else {
    Write-Host "[claude-dual] WARNING: proxy not yet listening on :3456 — check logs at $LogFile" -ForegroundColor Yellow
  }
} catch {
  Write-Host "[claude-dual] could not verify port (Test-NetConnection unavailable)"
}
