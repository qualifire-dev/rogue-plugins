# Rogue Security - MDM installer for Claude Code CLI fleets (native Windows).
#
# PowerShell sibling of mdm-install-cli.sh. Auto-updating alternative to the
# frozen drag-drop zip for the CLI surface on Windows-managed machines (Intune,
# etc.). Installs from the live public marketplace (kept current by the
# SessionStart auto-update.ps1 hook) and provisions the org key + per-user
# identity OUTSIDE the plugin directory so updates never clobber credentials.
#
# NOTE: this pairs with the native-Windows hook dispatcher (hook.ps1) shipped on
# the windows-support track. On a bash-only plugin build it still provisions the
# env + managed-settings correctly, but the runtime hooks need their PowerShell
# siblings to fire on native Windows.
#
# What it does (idempotent - safe to re-run every Intune cycle):
#   1. Writes C:\ProgramData\rogue\env (key, mode, actor) - outside the plugin
#      cache, survives `claude plugin update`.
#   2. Registers the public marketplace + installs the plugin via the Claude CLI
#      with auto-update ENABLED (ROGUE_AUTO_UPDATE is not set to 0 here).
#   3. Writes a managed-settings drop-in fragment to force-register the
#      marketplace + force-enable the plugin org-wide.
#
# Usage (run elevated, as SYSTEM via Intune or in an admin shell):
#   .\mdm-install-cli.ps1 -Key rsk_xxx -Email alice@corp.com -Name "Alice Smith" -Mode ask
#
# We do NOT set the (unshipped) managed-settings autoUpdate field; the
# SessionStart auto-update.ps1 hook drives `claude plugin update`. See
# docs/cli-mdm-auto-update.md.

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $Key,
  [Parameter(Mandatory = $true)] [string] $Email,
  [Parameter(Mandatory = $true)] [string] $Name,
  [ValidateSet('ask', 'block')] [string] $Mode = 'ask',
  [string] $BaseUrl = '',
  [string] $Repo = 'qualifire-dev/rogue-plugin-claude',
  [string] $RunAs = '',
  [switch] $NoManagedSettings
)

$ErrorActionPreference = 'Stop'
$MarketplaceName = 'rogue-marketplace'
$PluginName = 'rogue'

# Shell-quote a value the same way setup.ps1 / the bundled env expect, so the
# POSIX `export KEY=value` form round-trips through ConvertFrom-ShellQuoted.
function Quote-Shell([string] $v) { "'" + ($v -replace "'", "'\''") + "'" }

# ── 1. Provision C:\ProgramData\rogue\env ─────────────────────────────────────
$RogueDir = Join-Path $env:ProgramData 'rogue'
New-Item -ItemType Directory -Force -Path $RogueDir | Out-Null
$EnvFile = Join-Path $RogueDir 'env'

$lines = @(
  "# Provisioned by mdm-install-cli.ps1 on $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))",
  "export ROGUE_API_KEY=$(Quote-Shell $Key)",
  "export ROGUE_ACTOR_EMAIL=$(Quote-Shell $Email)",
  "export ROGUE_ACTOR_NAME=$(Quote-Shell $Name)",
  "export ROGUE_PRETOOLUSE_ON_BLOCK=$(Quote-Shell $Mode)"
)
if ($BaseUrl) { $lines += "export ROGUE_BASE_URL=$(Quote-Shell $BaseUrl)" }
Set-Content -LiteralPath $EnvFile -Value ($lines -join "`n") -Encoding ASCII

# Restrict ACL: SYSTEM + Administrators full, the target user read. Contains the
# API key, so don't leave it world-readable.
try {
  icacls $EnvFile /inheritance:r /grant:r "SYSTEM:(R,W)" "Administrators:(R,W)" "Users:(R)" | Out-Null
} catch { Write-Warning "icacls hardening failed: $_" }
$tail = if ($Key.Length -ge 4) { $Key.Substring($Key.Length - 4) } else { $Key }
Write-Host "wrote $EnvFile  actor=$Email  mode=$Mode  key=...$tail"

# ── 2. Register marketplace + install plugin (as the real user) ───────────────
# `claude plugin ...` writes to the user's profile. Under SYSTEM, target the
# console user via -RunAs; otherwise run in the current context.
function Invoke-Claude([string[]] $ClaudeArgs) {
  if ($RunAs) {
    # Best-effort: run as the named user. In an Intune SYSTEM context, prefer a
    # user-targeted script instead; this branch is for admin-shell installs.
    Start-Process -FilePath 'claude' -ArgumentList $ClaudeArgs -NoNewWindow -Wait -Credential (Get-Credential $RunAs)
  } else {
    & claude @ClaudeArgs
  }
}

if (Get-Command claude -ErrorAction SilentlyContinue) {
  Write-Host "registering marketplace + installing plugin"
  try { Invoke-Claude @('plugin', 'marketplace', 'add', $Repo) }
  catch { try { Invoke-Claude @('plugin', 'marketplace', 'update', $MarketplaceName) } catch { Write-Warning "marketplace add/update: $_" } }
  try { Invoke-Claude @('plugin', 'install', "$PluginName@$MarketplaceName") }
  catch { try { Invoke-Claude @('plugin', 'update', $PluginName) } catch { Write-Warning "plugin install/update: $_" } }
} else {
  Write-Host "claude CLI not on PATH - skipping live install; managed-settings will force-register on next launch."
}

# ── 3. Managed-settings drop-in (force-register org-wide) ─────────────────────
if (-not $NoManagedSettings) {
  $MsDir = Join-Path ${env:ProgramFiles} 'ClaudeCode\managed-settings.d'
  New-Item -ItemType Directory -Force -Path $MsDir | Out-Null
  $Frag = Join-Path $MsDir '30-rogue.json'
  $obj = [ordered]@{
    extraKnownMarketplaces = [ordered]@{
      $MarketplaceName = [ordered]@{ source = [ordered]@{ source = 'github'; repo = $Repo } }
    }
    enabledPlugins = [ordered]@{ "$PluginName@$MarketplaceName" = $true }
  }
  $obj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Frag -Encoding ASCII
  Write-Host "wrote managed-settings fragment $Frag"
} else {
  Write-Host "-NoManagedSettings: skipped managed-settings fragment"
}

Write-Host "OK  Rogue CLI install complete. Auto-update is ON (SessionStart hook)."
