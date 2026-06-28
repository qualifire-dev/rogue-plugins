# Emits a systemMessage at SessionStart if no ROGUE_API_KEY is configured
# (Windows analogue of warn.sh). Only needs to detect key PRESENCE.
$ErrorActionPreference = 'SilentlyContinue'

if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { exit 0 }

$pluginRoot = $env:CLAUDE_PLUGIN_ROOT
if (-not $pluginRoot) { $pluginRoot = $env:PLUGIN_ROOT }

# Mirror the real resolution order (later file wins; process env wins over all),
# and treat a blank final value as unconfigured — a non-empty earlier value must
# not be masked by an empty later assignment, and vice versa.
$key = ''
foreach ($f in @((Join-Path $pluginRoot 'env'), 'C:\ProgramData\rogue\env', (Join-Path $env:USERPROFILE '.rogue-env'))) {
    if ($f -and (Test-Path -LiteralPath $f)) {
        foreach ($line in (Get-Content -LiteralPath $f)) {
            if ($line -match '^\s*(?:export\s+)?ROGUE_API_KEY=(.*)$') { $key = $Matches[1].Trim().Trim("'").Trim('"') }
        }
    }
}
$procKey = [Environment]::GetEnvironmentVariable('ROGUE_API_KEY')
if ($procKey) { $key = $procKey }

if (-not $key) {
    [Console]::Out.Write('{"systemMessage": "[Rogue Security] Not configured. Run /rogue:setup to connect your API key."}')
}
exit 0
