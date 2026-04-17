# claude-dual installer for Windows (PowerShell 5.1+ / 7+)
#
# Wires up: proxy (with npm deps), launcher, persistent service, 4 GLM subagents,
# /orchestrate slash command, global CLAUDE.md delegation rule, effortLevel: xhigh.
# Safe to re-run.

$ErrorActionPreference = 'Stop'

function Say($msg)  { Write-Host "[claude-dual] $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  ! $msg" -ForegroundColor Yellow }
function Die($msg)  { Write-Host "  X $msg" -ForegroundColor Red; exit 1 }

$RepoDir = $PSScriptRoot

Say "installing claude-dual on Windows"

# ── Prerequisites ──────────────────────────────────────────────────
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) { Die "Node.js not found. Install from https://nodejs.org (v18+)" }
$nodeVer = (node --version) -replace '^v',''
$nodeMajor = [int]($nodeVer.Split('.')[0])
if ($nodeMajor -lt 18) { Die "Node.js 18+ required (have $nodeMajor). Upgrade from nodejs.org." }
Ok "Node.js v$nodeVer"

$ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollamaCmd) { Die "Ollama not found. Install from https://ollama.com" }
Ok "Ollama present"

$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claudeCmd) { Die "Claude Code CLI not found. Install: https://docs.claude.com/en/docs/claude-code" }
Ok "Claude Code present"

# Check Ollama reachable
try {
  $null = Invoke-WebRequest -Uri http://localhost:11434/api/tags -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
  Ok "Ollama daemon reachable on :11434"
} catch { Warn "Ollama daemon not running — run: ollama serve (or open the Ollama app)" }

# ── GLM model ──────────────────────────────────────────────────────
Say "checking glm-5.1:cloud model"
$hasGlm = (& ollama list 2>$null | Select-String "glm-5.1:cloud") -ne $null
if ($hasGlm) {
  Ok "glm-5.1:cloud already pulled"
} else {
  Warn "glm-5.1:cloud not found — pulling now"
  & ollama pull glm-5.1:cloud
  if ($LASTEXITCODE -ne 0) { Die "Failed to pull glm-5.1:cloud. Sign in with: ollama signin" }
  Ok "pulled glm-5.1:cloud"
}

# ── Target directories ────────────────────────────────────────────
$dualDir    = Join-Path $env:USERPROFILE '.claude-dual'
$claudeDir  = Join-Path $env:USERPROFILE '.claude'
$agentsDir  = Join-Path $claudeDir 'agents'
$cmdsDir    = Join-Path $claudeDir 'commands'
$binDir     = Join-Path $env:USERPROFILE '.local\bin'

foreach ($d in @($dualDir, $claudeDir, $agentsDir, $cmdsDir, $binDir)) {
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ── Copy files ────────────────────────────────────────────────────
Say "installing files"
Copy-Item "$RepoDir\proxy\proxy.js"         -Destination "$dualDir\proxy.js"        -Force ; Ok "proxy"
Copy-Item "$RepoDir\proxy\package.json"     -Destination "$dualDir\package.json"    -Force ; Ok "package.json"
foreach ($a in @('glm-worker','glm-explorer','glm-reviewer','glm-analyst')) {
  Copy-Item "$RepoDir\agents\$a.md" -Destination "$agentsDir\$a.md" -Force
  Ok "agent: $a"
}
Copy-Item "$RepoDir\commands\orchestrate.md" -Destination "$cmdsDir\orchestrate.md" -Force ; Ok "slash: orchestrate"

# Windows launcher (.cmd batch file)
$launcherPath = Join-Path $binDir 'claude-dual.cmd'
@"
@echo off
REM claude-dual launcher — routes Claude requests through the local proxy so the OAuth bearer is preserved
set ANTHROPIC_BASE_URL=http://127.0.0.1:3456
set ANTHROPIC_API_KEY=
claude %*
"@ | Out-File -FilePath $launcherPath -Encoding ASCII -Force
Ok "launcher: $launcherPath"

# ── Install npm deps ──────────────────────────────────────────────
$npmCmd = Get-Command npm -ErrorAction SilentlyContinue
if ($npmCmd) {
  Say "installing proxy dependencies (pino, prom-client)"
  Push-Location $dualDir
  try {
    & npm install --omit=dev --no-audit --no-fund --silent 2>$null
    if ($LASTEXITCODE -eq 0) { Ok "deps installed" }
    else { Warn "npm install failed — proxy will fall back to basic logging (still functional)" }
  } finally { Pop-Location }
} else {
  Warn "npm not found — proxy will fall back to basic logging (still functional)"
}

# ── Install persistent service ────────────────────────────────────
Say "installing persistent service"
& "$RepoDir\service\windows\install-service.ps1"

# ── Append delegation rule to CLAUDE.md ────────────────────────────
Say "wiring global delegation rule"
$claudeMd = Join-Path $claudeDir 'CLAUDE.md'
if (-not (Test-Path $claudeMd)) { New-Item -ItemType File -Path $claudeMd -Force | Out-Null }
$content = Get-Content $claudeMd -Raw -ErrorAction SilentlyContinue
if ($content -match 'Dual-Model Orchestration \(Opus ↔ GLM\)') {
  Ok "delegation rule already present"
} else {
  $delegationRule = Get-Content "$RepoDir\claude-md\dual-model-orchestration.md" -Raw
  Add-Content -Path $claudeMd -Value $delegationRule
  Ok "delegation rule appended to ~/.claude/CLAUDE.md"
}

# ── settings.json: effortLevel xhigh ──────────────────────────────
$settingsPath = Join-Path $claudeDir 'settings.json'
Say "setting effortLevel: xhigh in ~/.claude/settings.json"
if (Test-Path $settingsPath) {
  $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
  if ($settings.effortLevel -eq 'xhigh') {
    Ok "effortLevel already xhigh"
  } else {
    $settings | Add-Member -MemberType NoteProperty -Name 'effortLevel' -Value 'xhigh' -Force
    $settings | Add-Member -MemberType NoteProperty -Name 'alwaysThinkingEnabled' -Value $true -Force
    $settings | ConvertTo-Json -Depth 10 | Out-File -FilePath $settingsPath -Encoding UTF8 -Force
    Ok "effortLevel set to xhigh"
  }
} else {
  '{"alwaysThinkingEnabled":true,"effortLevel":"xhigh"}' | Out-File -FilePath $settingsPath -Encoding UTF8 -Force
  Ok "created settings.json"
}

# ── PATH check ────────────────────────────────────────────────────
if ($env:Path -like "*$binDir*") {
  Ok "$binDir already on PATH"
} else {
  Warn "$binDir is NOT on PATH. Add it via: [Environment]::SetEnvironmentVariable('Path', `$env:Path + ';$binDir', 'User')"
}

# ── Verify ────────────────────────────────────────────────────────
Say "verifying"
Start-Sleep -Seconds 2
try {
  $result = Test-NetConnection -ComputerName 127.0.0.1 -Port 3456 -InformationLevel Quiet -WarningAction SilentlyContinue
  if ($result) { Ok "proxy listening on :3456" } else { Warn "proxy NOT listening yet" }
} catch { Warn "could not verify port" }

try {
  $health = Invoke-RestMethod -Uri http://127.0.0.1:3456/health -TimeoutSec 3 -ErrorAction Stop
  Ok "health endpoint: $($health | ConvertTo-Json -Compress)"
} catch { Warn "health endpoint not responding yet — check logs in ~/.claude-dual/proxy.log" }

# ── Done ──────────────────────────────────────────────────────────
Write-Host ""
Write-Host "────────────────────────────────────────────────────────" -ForegroundColor Green
Write-Host "  claude-dual installed (Windows)" -ForegroundColor Green
Write-Host "────────────────────────────────────────────────────────" -ForegroundColor Green
Write-Host ""
Write-Host "  Run:        claude-dual"
Write-Host "  Test:       claude-dual -p `"Reply: OK`" --model claude-opus-4-7"
Write-Host "  Watch log:  Get-Content ~/.claude-dual/proxy.log -Tail 20 -Wait"
Write-Host "  Health:     Invoke-RestMethod http://127.0.0.1:3456/health"
Write-Host "  Metrics:    Invoke-RestMethod http://127.0.0.1:3456/metrics"
Write-Host "  Cost:       Invoke-RestMethod http://127.0.0.1:3456/cost"
Write-Host "  Uninstall:  .\service\windows\uninstall-service.ps1"
Write-Host ""
