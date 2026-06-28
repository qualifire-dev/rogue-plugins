# Emits a systemMessage at SessionStart if no ROGUE_API_KEY is configured
# (Windows analogue of warn.sh). Only needs to detect key PRESENCE.
$ErrorActionPreference = 'SilentlyContinue'

if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { exit 0 }

$pluginRoot = $env:CLAUDE_PLUGIN_ROOT
if (-not $pluginRoot) { $pluginRoot = $env:PLUGIN_ROOT }

$hasKey = $false
if ([Environment]::GetEnvironmentVariable('ROGUE_API_KEY')) { $hasKey = $true }
if (-not $hasKey) {
    foreach ($f in @((Join-Path $pluginRoot 'env'), 'C:\ProgramData\rogue\env', (Join-Path $env:USERPROFILE '.rogue-env'))) {
        if ($f -and (Test-Path -LiteralPath $f)) {
            if (Select-String -LiteralPath $f -Pattern '^\s*(?:export\s+)?ROGUE_API_KEY=' -Quiet) { $hasKey = $true; break }
        }
    }
}

if (-not $hasKey) {
    [Console]::Out.Write('{"systemMessage": "[Rogue Security] Not configured. Run /rogue:setup to connect your API key."}')
}
exit 0
