#!/usr/bin/env pwsh
# Unit tests for the Cursor PowerShell dispatcher's file-read capture helpers
# (plugins/cursor/scripts/hook.ps1). Lockstep partner of
# tests/test_hook_sh_cursor.sh.
#
# hooks.json loads hook.ps1 through a scriptblock wrapped in `catch { '{}' }`,
# so an error there degrades silently into a permanent no-op for every Windows
# Cursor user. This file is the only thing that catches that.
#
# The ROGUE_PS_LIB_ONLY seam loads only the functions, so this runs anywhere.

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$env:ROGUE_PS_LIB_ONLY = '1'
. ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $repo 'plugins/cursor/scripts/hook.ps1'))))
$env:ROGUE_PS_LIB_ONLY = $null
# hook.ps1 sets SilentlyContinue for its own fail-open behaviour. The test wants
# failures loud, and every helper here guards with try/catch anyway.
$ErrorActionPreference = 'Stop'

$script:fail = 0
function Assert-Eq {
    param($Actual, $Expected, [string]$What)
    if ($Actual -eq $Expected) { Write-Host "ok   $What" }
    else { Write-Host "FAIL $What`n  expected: [$Expected]`n  actual:   [$Actual]"; $script:fail++ }
}

# ── Extension allowlist ──────────────────────────────────────────────────
Assert-Eq (Test-RogueReadCapturePath '/tmp/a.pdf')  $true  'pdf is captured'
Assert-Eq (Test-RogueReadCapturePath '/tmp/A.PDF')  $true  'extension test is case-insensitive'
Assert-Eq (Test-RogueReadCapturePath '/tmp/a.svg')  $true  'svg is captured'
Assert-Eq (Test-RogueReadCapturePath '/tmp/a.png')  $false 'png is not captured'
Assert-Eq (Test-RogueReadCapturePath '/tmp/a.txt')  $false 'txt is not captured'
Assert-Eq (Test-RogueReadCapturePath '/tmp/noext')  $false 'a file with no extension is not captured'
Assert-Eq (Test-RogueReadCapturePath '/tmp/a.pdf.gz') $false 'only the LAST extension counts'

# ── Truncatable subset ───────────────────────────────────────────────────
Assert-Eq (Test-RogueReadCaptureTruncatable '/tmp/a.svg') $true  'svg is truncatable'
Assert-Eq (Test-RogueReadCaptureTruncatable '/tmp/A.SVG') $true  'truncatable test is case-insensitive'
Assert-Eq (Test-RogueReadCaptureTruncatable '/tmp/a.pdf') $false 'pdf is not truncatable'
Assert-Eq (Test-RogueReadCaptureTruncatable '/tmp/noext') $false 'a file with no extension is not truncatable'

# ── Add-FileReadBytes ────────────────────────────────────────────────────
$dir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $dir | Out-Null
$pdf = Join-Path $dir 'spec.pdf'
[System.IO.File]::WriteAllBytes($pdf, [byte[]](0x25,0x50,0x44,0x46,0x2D,0x31,0x2E,0x34))
$expected = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($pdf))

$esc = $pdf.Replace('\','\\')
$body = '{"content":"","file_path":"' + $esc + '"}'
# The whole body, since a filter that dropped `content` or `file_path` while
# still appending would pass a field-only assertion.
$expectedBody = '{"content":"","file_path":"' + $esc + '","rogueFileReadB64":"' + $expected + '"}'
Assert-Eq (Add-FileReadBytes $body) $expectedBody 'the field is appended and the rest of the body survives'

$busy = '{"content":"already here","file_path":"' + $pdf.Replace('\','\\') + '"}'
Assert-Eq (Add-FileReadBytes $busy) $busy 'non-empty content leaves the body untouched'

$png = Join-Path $dir 'i.png'
[System.IO.File]::WriteAllBytes($png, [byte[]](1,2,3))
$pngBody = '{"content":"","file_path":"' + $png.Replace('\','\\') + '"}'
Assert-Eq (Add-FileReadBytes $pngBody) $pngBody 'an extension outside the allowlist is untouched'

$missing = '{"content":"","file_path":"' + (Join-Path $dir 'nope.pdf').Replace('\','\\') + '"}'
Assert-Eq (Add-FileReadBytes $missing) $missing 'a missing file leaves the body untouched'

$empty = Join-Path $dir 'empty.pdf'
[System.IO.File]::WriteAllBytes($empty, [byte[]]@())
$emptyBody = '{"content":"","file_path":"' + $empty.Replace('\','\\') + '"}'
Assert-Eq (Add-FileReadBytes $emptyBody) $emptyBody 'a zero-byte file leaves the body untouched'

$rel = '{"content":"","file_path":"relative/x.pdf"}'
Assert-Eq (Add-FileReadBytes $rel) $rel 'a relative path leaves the body untouched'

# ── jq path == concat path ─────────────────────────────────────────────────
# Only one path runs on a given machine. Both GitHub runner images ship jq,
# while a typical Windows Cursor box has none and takes the concat path only,
# so emptying PATH is the only way to cover it.
function Invoke-WithoutJq {
    # Not named $Body: `& $Action` resolves the scriptblock's free variables
    # against THIS scope first, so that would shadow the caller's $body and the
    # scriptblock would pass itself.
    param([scriptblock]$Action)
    $rogueSavedPath = $env:PATH
    try { $env:PATH = ''; & $Action } finally { $env:PATH = $rogueSavedPath }
}
Assert-Eq (Invoke-WithoutJq { Get-Command jq -ErrorAction SilentlyContinue }) $null `
    'emptying PATH really does hide jq'

$concat = Invoke-WithoutJq { Add-FileReadBytes $body }
Assert-Eq $concat $expectedBody 'concat path (no jq on PATH) emits the documented bytes'

# Exactly ONE closing brace is stripped: TrimEnd would eat both and corrupt a
# body whose last value is a nested object.
$nested = '{"content":"","file_path":"' + $esc + '","meta":{"a":1}}'
$nestedExpected = '{"content":"","file_path":"' + $esc + '","meta":{"a":1},"rogueFileReadB64":"' + $expected + '"}'
$nestedConcat = Invoke-WithoutJq { Add-FileReadBytes $nested }
Assert-Eq $nestedConcat $nestedExpected 'concat path keeps a nested object at the end of the body'

# Trailing whitespace is trimmed first so the strip lands on the real brace.
$trailing = $body + "`n  "
$trailingConcat = Invoke-WithoutJq { Add-FileReadBytes $trailing }
Assert-Eq $trailingConcat $expectedBody 'concat path trims trailing whitespace before the brace strip'

# A body the concat path cannot safely close is left alone.
Assert-Eq (Invoke-WithoutJq { Add-FileReadBytes 'not json at all' }) 'not json at all' `
    'concat path leaves a body with no closing brace alone'

if (Get-Command jq -ErrorAction SilentlyContinue) {
    Assert-Eq (Add-FileReadBytes $body)   $concat       'jq and concat agree byte for byte'
    Assert-Eq (Add-FileReadBytes $nested) $nestedConcat 'jq and concat agree on a nested-object body'
} else {
    Write-Host '  skip: jq not installed - jq path not exercised'
}
# The empty-object separator branch is unreachable from this function: such a
# body carries no file_path and returns at the second gate. It stays for
# lockstep with Add-FilePreImage and hook.sh, where it is reachable.

# ── Over the cap: skipped for a non-truncatable type ────────────────────
$big = Join-Path $dir 'big.pdf'
$bytes = New-Object byte[] (1048576 + 10)
for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = 0x61 }
[System.IO.File]::WriteAllBytes($big, $bytes)
$bigBody = '{"content":"","file_path":"' + $big.Replace('\','\\') + '"}'
Assert-Eq (Add-FileReadBytes $bigBody) $bigBody 'an over-cap pdf leaves the body untouched'

# ── Over the cap: still truncated for a truncatable type ────────────────
# The other half of the split. Without this, the assertion above would also
# pass if the capture were disabled wholesale.
$bigSvg = Join-Path $dir 'big.svg'
# Distinguishable ends. With a uniform fill, reading the LAST 1 MiB would pass
# a length-only assertion identically.
$bytes[0] = 0x02
$bytes[$bytes.Length - 1] = 0x03
[System.IO.File]::WriteAllBytes($bigSvg, $bytes)
$bigSvgBody = '{"content":"","file_path":"' + $bigSvg.Replace('\','\\') + '"}'
$bigOut = Add-FileReadBytes $bigSvgBody
# A local match, not the ambient $Matches: a failed -match would leave the
# previous case's capture in place and these assertions would read it.
$bigMatch = [regex]::Match($bigOut, '"rogueFileReadB64":"([^"]*)"')
Assert-Eq $bigMatch.Success $true 'an over-cap svg still attaches a field'
$bigDecoded = [Convert]::FromBase64String($bigMatch.Groups[1].Value)
Assert-Eq $bigDecoded.Length 1048576 'an over-cap svg is truncated to the cap'
Assert-Eq $bigDecoded[0] ([byte]0x02) 'the truncation keeps the FIRST bytes (a prefix, not the tail)'
Assert-Eq $bigDecoded[$bigDecoded.Length - 1] ([byte]0x61) 'the file last byte is not in the prefix'

# ── At the cap: sent whole ──────────────────────────────────────────────
# One byte of slack in the comparison would turn this into a skip.
$atCap = Join-Path $dir 'atcap.pdf'
[System.IO.File]::WriteAllBytes($atCap, (New-Object byte[] 1048576))
$atCapBody = '{"content":"","file_path":"' + $atCap.Replace('\','\\') + '"}'
$atCapMatch = [regex]::Match((Add-FileReadBytes $atCapBody), '"rogueFileReadB64":"([^"]*)"')
Assert-Eq $atCapMatch.Success $true 'a pdf exactly AT the cap still attaches a field'
Assert-Eq ([Convert]::FromBase64String($atCapMatch.Groups[1].Value)).Length 1048576 `
    'a pdf exactly AT the cap is sent whole'

# ── The cap constant matches hook.sh ────────────────────────────────────
Assert-Eq $RogueFileReadMaxBytes 1048576 'cap constant is 1 MiB'

Remove-Item -Recurse -Force $dir
if ($script:fail -gt 0) { Write-Host "`n$($script:fail) failure(s)"; exit 1 }
Write-Host "`nall assertions passed"
