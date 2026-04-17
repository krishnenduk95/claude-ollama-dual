# uninstall-service.ps1 — reverse install-service.ps1

$ErrorActionPreference = 'Continue'
$ServiceName = 'claude-dual-proxy'
$TaskName = 'ClaudeDualProxy'
$removed = 0

# NSSM service path
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
  Write-Host "[claude-dual] removing service '$ServiceName'..." -ForegroundColor Cyan
  Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
  if (Get-Command nssm -ErrorAction SilentlyContinue) {
    & nssm remove $ServiceName confirm | Out-Null
    Write-Host "  service removed via nssm" -ForegroundColor Green
  } else {
    # Fallback: sc delete
    & sc.exe delete $ServiceName | Out-Null
    Write-Host "  service removed via sc.exe (nssm missing)" -ForegroundColor Yellow
  }
  $removed++
}

# Task Scheduler path
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
  Write-Host "[claude-dual] removing scheduled task '$TaskName'..." -ForegroundColor Cyan
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
  Write-Host "  task removed" -ForegroundColor Green
  $removed++
}

if ($removed -eq 0) {
  Write-Host "[claude-dual] nothing to uninstall — no service or task named '$ServiceName'/'$TaskName' found"
} else {
  Write-Host "[claude-dual] uninstall complete ($removed entries removed)" -ForegroundColor Green
  Write-Host "  Note: files under ~\.claude-dual\, ~\.claude\agents\, ~\.local\bin\claude-dual.cmd remain."
  Write-Host "  Run install.ps1's uninstall mode or delete manually to fully clean up."
}
