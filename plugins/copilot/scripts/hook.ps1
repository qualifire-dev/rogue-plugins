# Rogue Security hook bridge for GitHub Copilot CLI — PowerShell implementation.
#
# Cross-platform sibling of hook.sh. hooks.json fires the `bash` command on
# macOS/Linux and this `powershell` command on Windows (Copilot prefers pwsh 7+
# but falls back to Windows PowerShell 5.1 — so this stays 5.1-compatible).
# PURE RELAY: reads one Copilot hook event JSON on stdin, POSTs it to
# /api/v1/hooks/copilot, relays the native Copilot decision verbatim. No
# block-detection and no local modal — Copilot renders the native deny shape.
#
# FAIL-OPEN IS SAFETY-CRITICAL. Copilot's preToolUse is fail-CLOSED: a non-zero
# exit denies the tool. This script emits `{}` on every failure path and always
# exits 0; the loader in hooks.json additionally wraps the call in try/catch and
# `; exit 0`. A block is carried in the relayed JSON body, never the exit code.
#
# Loaded via [scriptblock]::Create((Get-Content ...)) rather than -File, so it
# runs regardless of ExecutionPolicy/GPO. Because it is a scriptblock (not a
# file), $PSCommandPath is empty — hooks.json passes the plugin root as the 2nd
# argument.
#
# Credential resolution (later file wins; process env wins over all):
#   1. ${PLUGIN_ROOT}\env          (baked into a compiled customer plugin)
#   2. C:\ProgramData\rogue\env    (MDM-provisioned; mirrors /etc/rogue/env)
#   3. %USERPROFILE%\.rogue-env    (user / installer-written)

param([string]$EventName = '', [string]$PluginRoot = '')

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

function Write-Raw {
    param([string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}
function Dbg { param([string]$Msg) if ($env:ROGUE_DEBUG) { [Console]::Error.WriteLine("[rogue] $Msg") } }

function ConvertFrom-ShellQuoted {
    # Decode one shell "word" the way hook.sh would when it sources the env file,
    # so values round-trip across both bridges (POSIX single-quoted or bash %q).
    param([string]$Val)
    if ($null -eq $Val) { return $Val }
    $sb = [System.Text.StringBuilder]::new()
    $i = 0; $n = $Val.Length; $state = 'normal'
    while ($i -lt $n) {
        $c = $Val[$i]
        switch ($state) {
            'single' { if ($c -eq "'") { $state = 'normal' } else { [void]$sb.Append($c) } }
            'double' {
                if ($c -eq '"') { $state = 'normal' }
                elseif ($c -eq '\' -and ($i + 1) -lt $n -and ('"\$`'.IndexOf($Val[$i+1]) -ge 0)) { [void]$sb.Append($Val[$i+1]); $i++ }
                else { [void]$sb.Append($c) }
            }
            default {
                if ($c -eq "'") { $state = 'single' }
                elseif ($c -eq '"') { $state = 'double' }
                elseif ($c -eq '\' -and ($i + 1) -lt $n) { [void]$sb.Append($Val[$i+1]); $i++ }
                else { [void]$sb.Append($c) }
            }
        }
        $i++
    }
    return $sb.ToString()
}

# Windows PowerShell 5.1 may negotiate only TLS 1.0/1.1 by default; add TLS 1.2.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

# Stand down on non-Windows (Copilot runs hook.sh there; this guards a stray pwsh).
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { Write-Raw '{}'; exit 0 }

if (-not $EventName) { Write-Raw '{}'; exit 0 }
Dbg "event=$EventName"

if (-not $PluginRoot) { $PluginRoot = $env:COPILOT_PLUGIN_ROOT }
if (-not $PluginRoot) { try { $PluginRoot = (Get-Location).Path } catch { $PluginRoot = '.' } }

$logFile = $env:ROGUE_LOG_FILE
if (-not $logFile) { $logFile = Join-Path (Join-Path $env:USERPROFILE '.rogue') 'hook.log' }
function Sanitize { param([string]$S) if ($null -eq $S) { return '' } ($S -replace '[\x00-\x1f\x7f]', '') }
function Log {
    param([string]$Msg)
    try {
        $dir = Split-Path $logFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Add-Content -LiteralPath $logFile -Value "$stamp provider=github_copilot event=$EventName $Msg" -Encoding UTF8
    } catch {}
}

# ── credential resolution (later file wins; process env wins over all) ─────
$creds = @{}
foreach ($f in @((Join-Path $PluginRoot 'env'), 'C:\ProgramData\rogue\env', (Join-Path $env:USERPROFILE '.rogue-env'))) {
    if (-not $f -or -not (Test-Path -LiteralPath $f)) { continue }
    foreach ($line in (Get-Content -LiteralPath $f)) {
        if ($line -match '^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.+)$') {
            $creds[$Matches[1]] = ConvertFrom-ShellQuoted ($Matches[2].Trim())
        }
    }
}
foreach ($k in 'ROGUE_API_KEY','ROGUE_ACTOR_EMAIL','ROGUE_ACTOR_NAME','ROGUE_BASE_URL','ROGUE_API_URL') {
    $val = [Environment]::GetEnvironmentVariable($k); if ($val) { $creds[$k] = $val }
}

$apiKey = $creds['ROGUE_API_KEY']

# Not configured: emit the SessionStart hint (so the user knows to run setup) or
# a clean allow for every other event. Never POST without a key. When a key IS
# present, sessionStart falls through to the POST path below (audit/persistence);
# the heartbeat runs from a separate hooks.json entry.
if (-not $apiKey) {
    Log 'outcome=unconfigured'
    if ($EventName -eq 'sessionStart') {
        Write-Raw '{"additionalContext":"[Rogue Security] Not configured. Run /rogue:setup to connect your API key."}'
    } else {
        Write-Raw '{}'
    }
    exit 0
}

# URL: explicit ROGUE_API_URL wins, else base + path.
$url = $creds['ROGUE_API_URL']
if (-not $url) {
    $baseUrl = $creds['ROGUE_BASE_URL']; if (-not $baseUrl) { $baseUrl = 'https://api.rogue.security' }
    $url = "$($baseUrl.TrimEnd('/'))/api/v1/hooks/copilot"
}

# ── actor resolution (mirrors actor.sh) ────────────────────────────────────
$actorName = $creds['ROGUE_ACTOR_NAME']
if (-not $actorName) { try { $actorName = (& git config --global user.name 2>$null | Out-String).Trim() } catch {} }
if (-not $actorName) { $actorName = $env:USERNAME }

$actorEmail = $creds['ROGUE_ACTOR_EMAIL']
if (-not $actorEmail) { try { $actorEmail = (& git config --global user.email 2>$null | Out-String).Trim() } catch {} }
if (-not $actorEmail) {
    if ($env:USERNAME -and $env:COMPUTERNAME) { $actorEmail = "$($env:USERNAME)@$($env:COMPUTERNAME)" }
    elseif ($env:USERNAME) { $actorEmail = $env:USERNAME } else { $actorEmail = $env:COMPUTERNAME }
}

# ── payload from stdin (recover UTF-8, strip BOM) ──────────────────────────
$payload = [Console]::In.ReadToEnd()
if (-not $payload) { $payload = '{}' }
try {
    $raw = [Console]::InputEncoding.GetBytes($payload)
    $payload = [System.Text.Encoding]::UTF8.GetString($raw)
} catch {}
$payload = $payload.TrimStart([char]0xFEFF)

# agentStop / subagentStop carry no message content inline — only a
# transcriptPath. Append the last ~256KB of that events.jsonl file, base64-
# encoded, as "transcriptTailB64" so the backend can extract the final message.
# base64 has no JSON-special chars, so re-closing the object is safe. Fail-open:
# any problem returns the payload unchanged.
if ($EventName -eq 'agentStop' -or $EventName -eq 'subagentStop') {
    try {
        $m = [regex]::Match($payload, '"transcriptPath":"([^"]*)"')
        if ($m.Success) {
            $tp = $m.Groups[1].Value
            if ($tp -and (Test-Path -LiteralPath $tp)) {
                $fs = [System.IO.File]::Open($tp, 'Open', 'Read', 'ReadWrite')
                try {
                    $len = $fs.Length
                    $take = [Math]::Min(262144, $len)
                    if ($take -gt 0) {
                        [void]$fs.Seek($len - $take, 'Begin')
                        $buf = New-Object byte[] $take
                        # Stream.Read may return fewer bytes than requested — loop
                        # until $take bytes are read (or EOF) so no trailing NULs
                        # leak into the base64.
                        $read = 0
                        while ($read -lt $take) {
                            $n = $fs.Read($buf, $read, $take - $read)
                            if ($n -le 0) { break }
                            $read += $n
                        }
                        if ($read -gt 0) {
                            $b64 = [Convert]::ToBase64String($buf, 0, $read)
                            # Strip exactly ONE trailing '}' (mirrors hook.sh's
                            # "${_body%\}}"). String.TrimEnd('}') would strip ALL
                            # trailing braces and corrupt a body ending in "}}".
                            $p = $payload.TrimEnd()
                            if ($p.EndsWith('}')) { $p = $p.Substring(0, $p.Length - 1) }
                            if ($b64) { $payload = $p + ',"transcriptTailB64":"' + $b64 + '"}' }
                        }
                    }
                } finally { $fs.Close() }
            }
        }
    } catch { Dbg "transcript augment failed: $($_.Exception.Message)" }
}

# ── POST (fail-open) → relay verbatim ──────────────────────────────────────
$headers = @{
    'x-rogue-api-key'     = $apiKey
    'x-rogue-event'       = $EventName
    'x-rogue-actor-email' = $actorEmail
    'x-rogue-actor-name'  = $actorName
}
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
$resp = ''
try {
    $r = Invoke-WebRequest -Uri $url -Method Post `
        -Headers $headers -ContentType 'application/json' -Body $bodyBytes `
        -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    if ($r.StatusCode -eq 200) {
        try { $resp = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) }
        catch { $resp = [string]$r.Content }
    }
} catch { Dbg "POST failed: $($_.Exception.Message)"; $resp = '' }

$respHead = if ($resp.Length -gt 400) { $resp.Substring(0, 400) } else { $resp }
Log "raw=$(Sanitize $respHead)"

if (-not $resp) { Write-Raw '{}'; exit 0 }
Write-Raw $resp
exit 0
