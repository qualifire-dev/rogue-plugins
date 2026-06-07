#Requires -Version 5.1
<#
.SYNOPSIS
    Rogue Security — one-line installer for Claude Code (Windows).
.DESCRIPTION
    iwr -useb https://raw.githubusercontent.com/qualifire-dev/rogue-plugin-claude/main/install.ps1 | iex

    With credentials via environment variables (non-interactive):
    $env:ROGUE_API_KEY='rsk_xxx'; $env:ROGUE_ACTOR_EMAIL='you@co.com'; iwr -useb https://raw.githubusercontent.com/qualifire-dev/rogue-plugin-claude/main/install.ps1 | iex

    Direct invocation with flags:
    .\install.ps1 -ApiKey rsk_xxx -Email you@co.com -Name 'Your Name'
    .\install.ps1 -NonInteractive

    Installs the plugin through the official Claude CLI (marketplace add + plugin
    install) — the same mechanism as install.sh — validates and stores your API
    key, and confirms your actor identity.

    Unlike the runtime hooks (which fail OPEN so Claude Code never hangs on Rogue
    infrastructure), this installer fails LOUD: a half-finished install should be
    visible, not silent.
.PARAMETER ApiKey
    Rogue API key (rsk_...).
.PARAMETER Email
    Actor email address.
.PARAMETER Name
    Actor display name.
.PARAMETER BaseUrl
    Override the API base URL (default: https://api.rogue.security).
.PARAMETER PluginRepo
    Marketplace source repo (default: qualifire-dev/rogue-plugin-claude).
.PARAMETER NonInteractive
    Fail / skip prompts rather than ask for missing values.
#>
[CmdletBinding()]
param(
    [string]$ApiKey,
    [string]$Email,
    [string]$Name,
    [string]$BaseUrl,
    [string]$PluginRepo,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'

$ROGUE_BASE_URL_DEFAULT = 'https://api.rogue.security'
$MarketplaceName = 'rogue-marketplace'
$PluginName      = 'rogue'
$EnvFile = if ($env:ROGUE_ENV_FILE) { $env:ROGUE_ENV_FILE } else { Join-Path $env:USERPROFILE '.rogue-env' }

# Merge env vars -> params (explicit params win).
if (-not $ApiKey)     { $ApiKey     = $env:ROGUE_API_KEY }
if (-not $Email)      { $Email      = $env:ROGUE_ACTOR_EMAIL }
if (-not $Name)       { $Name       = $env:ROGUE_ACTOR_NAME }
if (-not $BaseUrl)    { $BaseUrl    = if ($env:ROGUE_BASE_URL) { $env:ROGUE_BASE_URL } else { $ROGUE_BASE_URL_DEFAULT } }
if (-not $PluginRepo) { $PluginRepo = if ($env:ROGUE_PLUGIN_REPO) { $env:ROGUE_PLUGIN_REPO } else { 'qualifire-dev/rogue-plugin-claude' } }
if ($env:ROGUE_NON_INTERACTIVE) { $NonInteractive = $true }

function Log  { param([string]$M) Write-Host "-> $M" -ForegroundColor Cyan }
function Ok   { param([string]$M) Write-Host "v  $M" -ForegroundColor Green }
function Warn2{ param([string]$M) Write-Host "!  $M" -ForegroundColor Yellow }
function Die  { param([string]$M) Write-Host "x  $M" -ForegroundColor Red; exit 1 }

try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

Write-Host ""
Write-Host "Rogue Security — Claude Code (Windows)" -ForegroundColor Cyan

# Claude CLI + git are required (Claude shells out to git to clone the marketplace).
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Die "Claude Code CLI not found on PATH. Install it from https://claude.com/code first."
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Die "git not found. Install Git for Windows (https://git-scm.com/download/win) first."
}

# Load existing creds from disk (same priority as the dispatcher: later wins).
function Load-ExistingCreds {
    foreach ($f in @('C:\ProgramData\rogue\env', (Join-Path $env:USERPROFILE '.rogue-env'))) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        foreach ($line in (Get-Content -LiteralPath $f -ErrorAction SilentlyContinue)) {
            if ($line -match '^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.+)$') {
                $k = $Matches[1]
                $v = $Matches[2].Trim() -replace "^'(.*)'$", '$1' -replace '^"(.*)"$', '$1'
                switch ($k) {
                    'ROGUE_API_KEY'     { if (-not $script:ApiKey)  { $script:ApiKey  = $v } }
                    'ROGUE_ACTOR_EMAIL' { if (-not $script:Email)   { $script:Email   = $v } }
                    'ROGUE_ACTOR_NAME'  { if (-not $script:Name)    { $script:Name    = $v } }
                    'ROGUE_BASE_URL'    { if ($script:BaseUrl -eq $ROGUE_BASE_URL_DEFAULT) { $script:BaseUrl = $v } }
                }
            }
        }
    }
}
Load-ExistingCreds

if (-not $ApiKey) {
    if ($NonInteractive) {
        Warn2 'No API key set and running non-interactively — skipping key setup.'
        Warn2 'Run /rogue:setup inside Claude Code to connect your key later.'
    } else {
        $secure = Read-Host 'Rogue API key (rsk_...)' -AsSecureString
        $bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $ApiKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        if (-not $ApiKey) { Die 'API key cannot be empty.' }
    }
}

# Actor identity: git config -> env fallbacks (mirrors actor.sh).
if (-not $Email) { try { $Email = (& git config --global user.email 2>$null | Out-String).Trim() } catch {} }
if (-not $Name)  { try { $Name  = (& git config --global user.name 2>$null | Out-String).Trim() } catch {} }
if (-not $Email -and $env:CLAUDE_CODE_USER_EMAIL) { $Email = $env:CLAUDE_CODE_USER_EMAIL }
if (-not $Email) { $Email = "$env:USERNAME@$env:COMPUTERNAME" }
if (-not $Name)  { $Name  = $env:USERNAME }
Log "Actor: $Name <$Email>"

# Validate the key AND register this install via /api/v1/hooks/status (the same
# heartbeat the SessionStart hook calls), so the dashboard roster row is deduped.
if ($ApiKey) {
    Log 'Validating API key...'
    try {
        $hostName = $env:COMPUTERNAME; if (-not $hostName) { $hostName = 'unknown' }
        $body = @{ agent_family = 'claude'; agent = 'Claude Code - CLI'; host = $hostName; actor_email = [string]$Email } | ConvertTo-Json -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $resp = Invoke-WebRequest -Uri "$($BaseUrl.TrimEnd('/'))/api/v1/hooks/status" -Method Post `
            -Headers @{ 'x-rogue-api-key' = $ApiKey } -ContentType 'application/json' `
            -Body $bytes -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        if ($resp.StatusCode -eq 200) { Ok 'Key validated.' } else { Warn2 "Unexpected response (HTTP $($resp.StatusCode)) — saving without verification." }
    } catch {
        $code = $null
        if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch {} }
        if ($code -eq 401 -or $code -eq 403) {
            if ($NonInteractive) { Die "Invalid API key (HTTP $code)." }
            Warn2 "Invalid key (HTTP $code) — saving anyway. Verify it at https://app.rogue.security/settings/api-keys"
        } else {
            Warn2 "Could not reach $BaseUrl to validate — saving without verification."
        }
    }

    # Write %USERPROFILE%\.rogue-env via setup.ps1's format (POSIX single-quoted).
    function Format-EnvVal { param([string]$Val) return "'" + $Val.Replace("'", "'\''") + "'" }
    $envLines = @(
        '# Managed by the rogue Claude plugin installer. Read by hook subprocesses at runtime.',
        '# Delete this file to revoke credentials.',
        "export ROGUE_API_KEY=$(Format-EnvVal $ApiKey)",
        "export ROGUE_ACTOR_EMAIL=$(Format-EnvVal $Email)",
        "export ROGUE_ACTOR_NAME=$(Format-EnvVal $Name)"
    )
    if ($BaseUrl -ne $ROGUE_BASE_URL_DEFAULT) { $envLines += "export ROGUE_BASE_URL=$(Format-EnvVal $BaseUrl)" }
    $envDir = Split-Path $EnvFile
    if ($envDir -and -not (Test-Path $envDir)) { New-Item -ItemType Directory -Path $envDir -Force | Out-Null }
    Set-Content -Path $EnvFile -Value $envLines -Encoding UTF8
    try {
        $acl = Get-Acl $EnvFile
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name, 'FullControl', 'Allow')
        $acl.SetAccessRule($rule); Set-Acl $EnvFile $acl
    } catch { Warn2 "Could not restrict permissions on $EnvFile (non-fatal)." }
    Ok "Credentials written to $EnvFile"
}

# Install through the Claude CLI marketplace (cross-platform; same as install.sh).
# `claude` is a native command — a non-zero exit does NOT throw, so gate on
# $LASTEXITCODE (the catch only fires if the process can't be spawned at all),
# mirroring the plugin-install block below.
Log "Adding marketplace $PluginRepo"
$mktOk = $false
try { & claude plugin marketplace add $PluginRepo 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $mktOk = $true } } catch {}
if ($mktOk) {
    Ok 'Marketplace added'
} else {
    # Already present (or transient) — refresh from source instead.
    try { & claude plugin marketplace update $MarketplaceName 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $mktOk = $true } } catch {}
    if ($mktOk) { Ok 'Marketplace updated' }
    else { Warn2 'Could not add or update marketplace (continuing — it may already be present).' }
}

Log "Installing plugin $PluginName@$MarketplaceName"
$installed = $false
try { & claude plugin install "$PluginName@$MarketplaceName" 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $installed = $true } } catch {}
if (-not $installed) {
    try { & claude plugin update $PluginName 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $installed = $true } } catch {}
}
if (-not $installed) {
    Die "claude plugin install failed. Run 'claude plugin install $PluginName@$MarketplaceName' to see the error."
}
Ok 'Plugin installed'

Write-Host @"

v Rogue Security (Claude Code) installed.

  Credentials:  $EnvFile

Next steps:
  1. Fully quit Claude Code and reopen it (hooks load credentials at session start).
  2. Run /rogue:status inside Claude Code to verify.
  3. AIDR dashboard: https://app.rogue.security/aidr

Re-running this installer upgrades the plugin and is safe.
"@ -ForegroundColor Green
