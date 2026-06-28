# Rogue Security AIDR — one-liner multi-agent installer (Windows / PowerShell).
#
#   irm https://raw.githubusercontent.com/qualifire-dev/rogue-plugins/main/install-all.ps1 | iex
#
# Windows sibling of install-all.sh. Detects supported coding agents, collects +
# validates credentials ONCE into the shared %USERPROFILE%\.rogue-env, then runs
# each per-agent install non-interactively. Fail-soft per agent.
#
# Params can be passed when invoked as a file; for `irm | iex` set $env:ROGUE_* first.
param(
    [string]$Only = '',
    [string]$Skip = '',
    [switch]$List,
    [switch]$DryRun,
    [switch]$Force,   # ignore the on-disk key and re-collect credentials (per-agent install always re-runs, idempotent)
    [switch]$NonInteractive,
    [string]$ApiKey   = $env:ROGUE_API_KEY,
    [string]$ActorEmail = $env:ROGUE_ACTOR_EMAIL,
    [string]$ActorName  = $env:ROGUE_ACTOR_NAME,
    [string]$BaseUrl  = $(if ($env:ROGUE_BASE_URL) { $env:ROGUE_BASE_URL } else { 'https://api.rogue.security' })
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

$Repo    = if ($env:ROGUE_REPO) { $env:ROGUE_REPO } else { 'qualifire-dev/rogue-plugins' }
$EnvFile = if ($env:ROGUE_ENV_FILE) { $env:ROGUE_ENV_FILE } else { Join-Path $env:USERPROFILE '.rogue-env' }
$CursorInstaller = if ($env:ROGUE_CURSOR_INSTALLER_PS1) { $env:ROGUE_CURSOR_INSTALLER_PS1 } else { 'https://raw.githubusercontent.com/qualifire-dev/rogue-plugin-cursor/main/install.ps1' }

function Say { param([string]$M) Write-Host $M }
function InCsv { param([string]$Csv,[string]$Id) return (",$Csv," -like "*,$Id,*") }

# ── providers / detection ──────────────────────────────────────────────────
$providers = @(
    @{ id='claude'; label='Claude Code'; detect={ [bool](Get-Command claude -ErrorAction SilentlyContinue) } },
    @{ id='codex';  label='OpenAI Codex'; detect={ [bool](Get-Command codex -ErrorAction SilentlyContinue) } },
    @{ id='cursor'; label='Cursor'; detect={ [bool](Get-Command cursor -ErrorAction SilentlyContinue) -or (Test-Path (Join-Path $env:USERPROFILE '.cursor')) -or (Test-Path (Join-Path $env:LOCALAPPDATA 'Programs\cursor')) } }
)

function Selected { param([string]$Id)
    if ($Only -and -not (InCsv $Only $Id)) { return $false }
    if ($Skip -and (InCsv $Skip $Id)) { return $false }
    return $true
}

Say "Rogue AIDR — detecting coding agents:"
$active = @()
foreach ($p in $providers) {
    $d = & $p.detect
    $mark = if ($d) { '✓' } else { '—' }
    $note = if ($d -and (Selected $p.id)) { ' (will install)' } else { '' }
    Say ("  {0} {1,-14} {2}{3}" -f $mark, $p.label, $(if($d){'yes'}else{'no'}), $note)
    if ($d -and (Selected $p.id)) { $active += $p.id }
}

if ($List) { return }
if (-not $active) { Say 'No supported agents selected. Nothing to do.'; return }

# ── credentials (collect ONCE) ─────────────────────────────────────────────
function ConvertFrom-ShellQuoted { param([string]$Val)
    if ($null -eq $Val) { return $Val }
    $Val = $Val.Trim()
    if ($Val.StartsWith("'") -and $Val.EndsWith("'")) { return $Val.Substring(1, $Val.Length-2).Replace("'\''","'") }
    return $Val
}
if (-not $ApiKey -and -not $Force -and (Test-Path -LiteralPath $EnvFile)) {
    foreach ($line in (Get-Content -LiteralPath $EnvFile)) {
        if ($line -match '^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.+)$') {
            $k = $Matches[1]; $v = ConvertFrom-ShellQuoted $Matches[2]
            switch ($k) {
                'ROGUE_API_KEY'     { if (-not $ApiKey) { $ApiKey = $v } }
                'ROGUE_ACTOR_EMAIL' { if (-not $ActorEmail) { $ActorEmail = $v } }
                'ROGUE_ACTOR_NAME'  { if (-not $ActorName) { $ActorName = $v } }
            }
        }
    }
}
if (-not $ActorEmail) { try { $ActorEmail = (& git config --global user.email 2>$null | Out-String).Trim() } catch {} }
if (-not $ActorName)  { try { $ActorName  = (& git config --global user.name  2>$null | Out-String).Trim() } catch {} }

if (-not $ApiKey) {
    if ($NonInteractive) { Say '✗ No API key (set $env:ROGUE_API_KEY or -ApiKey). Aborting.'; exit 1 }
    $sec = Read-Host -AsSecureString 'Rogue API key (rsk_...)'
    $ApiKey = [System.Net.NetworkCredential]::new('', $sec).Password
}

if (-not $DryRun) {
    try {
        $r = Invoke-WebRequest -Uri "$($BaseUrl.TrimEnd('/'))/api/v1/hooks/ping" -Headers @{ 'x-rogue-api-key' = $ApiKey } `
            -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        if ($r.StatusCode -ne 200) { throw "HTTP $($r.StatusCode)" }
        Say '✓ API key valid'
    } catch { Say "✗ API key validation failed: $($_.Exception.Message)"; exit 1 }
}

function Format-EnvVal { param([string]$Val) return "'" + ([string]$Val).Replace("'", "'\''") + "'" }
function Write-EnvFile {
    $surface = if ($env:ROGUE_CODEX_SURFACE) { $env:ROGUE_CODEX_SURFACE } else { 'codex_cli' }
    $lines = @(
        '# Managed by the rogue multi-agent installer. Read by hook subprocesses at runtime.',
        '# Delete this file to revoke credentials.',
        "export ROGUE_API_KEY=$(Format-EnvVal $ApiKey)",
        "export ROGUE_ACTOR_EMAIL=$(Format-EnvVal $ActorEmail)",
        "export ROGUE_ACTOR_NAME=$(Format-EnvVal $ActorName)",
        "export ROGUE_CODEX_SURFACE=$(Format-EnvVal $surface)"
    )
    if ($BaseUrl -ne 'https://api.rogue.security') { $lines += "export ROGUE_BASE_URL=$(Format-EnvVal $BaseUrl)" }
    Set-Content -Path $EnvFile -Value $lines -Encoding UTF8
    # Lock the credential file to the current user. If this fails, the API key would
    # be left readable with inherited permissions — delete it and fail loudly rather
    # than report success on an exposed secret.
    try {
        $acl = Get-Acl $EnvFile
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name, 'FullControl', 'Allow')
        $acl.SetAccessRule($rule); Set-Acl $EnvFile $acl
    } catch {
        Remove-Item -LiteralPath $EnvFile -Force -ErrorAction SilentlyContinue
        throw "Failed to restrict permissions on $EnvFile : $($_.Exception.Message)"
    }
}
if ($DryRun) { Say "  [dry-run] write $EnvFile" } else { Write-EnvFile; Say "✓ wrote $EnvFile" }

# ── per-agent install (fail-soft) ──────────────────────────────────────────
# Native CLIs (claude/codex) return a nonzero EXIT CODE on failure; they do NOT
# throw. So check $LASTEXITCODE explicitly after each and throw to mark failure.
function Invoke-Cli {
    param([string]$Exe, [string[]]$CliArgs, [switch]$AllowFail)
    if ($DryRun) { Say "  [dry-run] $Exe $($CliArgs -join ' ')"; return $true }
    & $Exe @CliArgs
    $ok = ($LASTEXITCODE -eq 0)
    if (-not $ok -and -not $AllowFail) { throw "$Exe $($CliArgs -join ' ') exited $LASTEXITCODE" }
    return $ok
}
function Install-MarketplacePlugin {
    param([string]$Exe)
    # add; on failure (already present) fall back to update — mirrors install-all.sh.
    if (-not (Invoke-Cli $Exe @('plugin','marketplace','add',$Repo) -AllowFail)) {
        Invoke-Cli $Exe @('plugin','marketplace','update',$Repo) -AllowFail | Out-Null
    }
    Invoke-Cli $Exe @('plugin','install','rogue@rogue-marketplace') | Out-Null
}

$rc = 0
Say ''
Say ("Installing into: " + ($active -join ', '))
foreach ($id in $active) {
    Say "-> $id"
    try {
        switch ($id) {
            'claude' { Install-MarketplacePlugin 'claude' }
            'codex'  {
                Install-MarketplacePlugin 'codex'
                Say "  ! Codex skips untrusted hooks - open /hooks in Codex and trust the Rogue entries once."
            }
            'cursor' {
                # Download to a temp file and run it as a CHILD process. Running the
                # installer via iex/Invoke-Expression executes it in-process, so an
                # `exit` inside it would kill THIS dispatcher and skip the remaining
                # agents + fail-soft handling.
                if ($DryRun) { Say "  [dry-run] download + run $CursorInstaller" }
                else {
                    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("rogue-cursor-install-{0}.ps1" -f [guid]::NewGuid())
                    $prev = $env:ROGUE_NON_INTERACTIVE
                    try {
                        Invoke-WebRequest -Uri $CursorInstaller -OutFile $tmp -UseBasicParsing -TimeoutSec 30
                        $env:ROGUE_NON_INTERACTIVE = '1'
                        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp
                        if ($LASTEXITCODE -ne 0) { throw "cursor installer exited $LASTEXITCODE" }
                    } finally {
                        if ($null -eq $prev) { Remove-Item Env:ROGUE_NON_INTERACTIVE -ErrorAction SilentlyContinue }
                        else { $env:ROGUE_NON_INTERACTIVE = $prev }
                        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    } catch { Say "  x $id failed: $($_.Exception.Message)"; $rc = 1 }
}

Say ''
if ($rc -eq 0) { Say '✓ Done. Restart each agent to load the plugin.' } else { Say '! Done with some failures - see above.' }
exit $rc
