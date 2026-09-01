#!/usr/bin/env pwsh
# tests/test_hook_ps1_cursor.ps1 — unit tests for the Cursor PowerShell
# dispatcher's file-read capture helpers (plugins/cursor/scripts/hook.ps1).
#
# Lockstep partner of tests/test_hook_sh_cursor.sh: the two dispatchers must
# agree on the extension allowlist, the 1 MiB cap, the truncate-rather-than-skip
# rule and every fail-open branch.
#
# These are the ONLY automated checks that ever execute this code path on the
# Windows side: hooks.json loads hook.ps1 through a scriptblock wrapped in
# `catch { '{}' }`, so a parse or logic error there degrades silently into a
# permanent no-op for every Windows Cursor user.
#
# Run on any platform with PowerShell:  pwsh tests/test_hook_ps1_cursor.ps1
# hook.ps1 stands down on non-Windows for its MAIN body, but this test loads
# only its functions via the ROGUE_PS_LIB_ONLY seam, so it runs anywhere.

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$env:ROGUE_PS_LIB_ONLY = '1'
. ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $repo 'plugins/cursor/scripts/hook.ps1'))))
$env:ROGUE_PS_LIB_ONLY = $null
# hook.ps1 sets SilentlyContinue for its own fail-open behaviour; the test
# itself wants failures to be loud. Every helper under test guards with
# try/catch, so this does not change what they do.
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

# ── Add-FileReadBytes ────────────────────────────────────────────────────
$dir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $dir | Out-Null
$pdf = Join-Path $dir 'spec.pdf'
[System.IO.File]::WriteAllBytes($pdf, [byte[]](0x25,0x50,0x44,0x46,0x2D,0x31,0x2E,0x34))
$expected = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($pdf))

$body = '{"content":"","file_path":"' + $pdf.Replace('\','\\') + '"}'
$out = Add-FileReadBytes $body
Assert-Eq ($out -match '"rogueFileReadB64":"([^"]*)"') $true 'field is added'
Assert-Eq $Matches[1] $expected 'attached bytes are the file base64'

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

# ── Truncation at the cap ────────────────────────────────────────────────
$big = Join-Path $dir 'big.pdf'
$bytes = New-Object byte[] (1048576 + 10)
for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = 0x61 }
[System.IO.File]::WriteAllBytes($big, $bytes)
$bigBody = '{"content":"","file_path":"' + $big.Replace('\','\\') + '"}'
$bigOut = Add-FileReadBytes $bigBody
$null = $bigOut -match '"rogueFileReadB64":"([^"]*)"'
Assert-Eq ([Convert]::FromBase64String($Matches[1]).Length) 1048576 'over-cap file is truncated to the cap'

# ── The cap constant matches hook.sh ────────────────────────────────────
Assert-Eq $RogueFileReadMaxBytes 1048576 'cap constant is 1 MiB'

Remove-Item -Recurse -Force $dir
if ($script:fail -gt 0) { Write-Host "`n$($script:fail) failure(s)"; exit 1 }
Write-Host "`nall assertions passed"
