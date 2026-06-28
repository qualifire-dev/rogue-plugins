# Rogue Security — credential storage helper (Windows / PowerShell) — Codex plugin.
# Mirrors setup.sh: writes %USERPROFILE%\.rogue-env, restricted to the current
# user, in the same `export KEY=value` shell-quoted format both bridges read.
#
# Usage: powershell -NoProfile -File setup.ps1 <api-key> <email> <name> [surface]
#   surface: codex_app | codex_cli (default codex_cli)
param(
    [Parameter(Mandatory = $true)][string]$ApiKey,
    [string]$Email   = '',
    [string]$Name    = '',
    [string]$Surface = 'codex_cli'
)

$ErrorActionPreference = 'Stop'

$EnvFile = if ($env:ROGUE_ENV_FILE) { $env:ROGUE_ENV_FILE } else { Join-Path $env:USERPROFILE '.rogue-env' }

# POSIX single-quote so the value is safe whether sourced by hook.sh or decoded by
# hook.ps1's ConvertFrom-ShellQuoted. Each ' becomes '\''.
function Format-EnvVal {
    param([string]$Val)
    return "'" + $Val.Replace("'", "'\''") + "'"
}

$envLines = @(
    '# Managed by the rogue Codex plugin. Read by hook subprocesses at runtime.',
    '# Delete this file to revoke credentials.',
    "export ROGUE_API_KEY=$(Format-EnvVal $ApiKey)",
    "export ROGUE_ACTOR_EMAIL=$(Format-EnvVal $Email)",
    "export ROGUE_ACTOR_NAME=$(Format-EnvVal $Name)",
    "export ROGUE_CODEX_SURFACE=$(Format-EnvVal $Surface)"
)

$envDir = Split-Path $EnvFile
if ($envDir -and -not (Test-Path $envDir)) {
    New-Item -ItemType Directory -Path $envDir -Force | Out-Null
}
Set-Content -Path $EnvFile -Value $envLines -Encoding UTF8

# Restrict the file to the current user only (mirrors chmod 600). If this fails the
# API key would be left readable with inherited perms — delete it and fail rather
# than print OK on an exposed secret.
try {
    $acl = Get-Acl $EnvFile
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
        'FullControl', 'Allow')
    $acl.SetAccessRule($rule)
    Set-Acl $EnvFile $acl
} catch {
    $err = $_.Exception.Message
    Remove-Item -LiteralPath $EnvFile -Force -ErrorAction SilentlyContinue
    Write-Error "Failed to restrict permissions on $EnvFile : $err"
    exit 1
}

Write-Output "OK"
Write-Output "ENV_FILE=$EnvFile"
