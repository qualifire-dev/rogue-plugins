#!/usr/bin/env pwsh
# tests/test_hook_ps1_cursor.ps1 — unit tests for the Cursor PowerShell
# dispatcher's subagent -> parent session attribution
# (plugins/cursor/scripts/hook.ps1).
#
# Lockstep partner of tests/test_hook_sh_cursor.sh: every case there has a case
# here, because the repo's rule is that hook.sh and hook.ps1 move together. What
# it cannot mirror is the POST itself — hook.ps1's main body stands down on
# non-Windows, so this file loads only its FUNCTIONS through the
# ROGUE_PS_LIB_ONLY seam. The header-emit call site is covered by the sh suite
# plus the parse gate in .github/workflows/validate.yml; the resolution logic,
# which is where a wrong answer would come from, is covered here.
#
# These are the ONLY automated checks that ever execute this code: hooks.json
# loads hook.ps1 via `[scriptblock]::Create(...)` inside a catch that swallows
# failures into `{}`, so a logic error here is a silent no-op for every Windows
# Cursor user rather than an error anyone sees.
#
# Run on any platform with PowerShell:  pwsh tests/test_hook_ps1_cursor.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# [IO.Path]::Combine takes many segments on Windows PowerShell 5.1; multi-segment
# Join-Path is PowerShell 7+ only.
$hook = [System.IO.Path]::Combine($here, '..', 'plugins', 'cursor', 'scripts', 'hook.ps1')

# Load hook.ps1's functions without executing the dispatcher body.
$env:ROGUE_PS_LIB_ONLY = '1'
. $hook
$env:ROGUE_PS_LIB_ONLY = $null
# hook.ps1 sets SilentlyContinue for its own fail-open behaviour; the test itself
# wants failures to be loud. Every function under test guards with try/catch, so
# this does not change what they do.
$ErrorActionPreference = 'Stop'

$fails = 0
$count = 0
function Assert-Eq {
    param($Got, $Expected, [string]$Label)
    $script:count++
    if ([string]$Got -ceq [string]$Expected) { Write-Host "  ok: $Label" }
    else { Write-Host "FAIL [$Label]: got <$Got>, expected <$Expected>"; $script:fails++ }
}
function Assert-True {
    param($Cond, [string]$Label)
    $script:count++
    if ($Cond) { Write-Host "  ok: $Label" }
    else { Write-Host "FAIL [$Label]: expected true, got <$Cond>"; $script:fails++ }
}
function Assert-Null {
    param($Got, [string]$Label)
    $script:count++
    if ($null -eq $Got) { Write-Host "  ok: $Label" }
    else { Write-Host "FAIL [$Label]: expected null, got <$Got>"; $script:fails++ }
}

# ── harness ────────────────────────────────────────────────────────────────
# The functions read %USERPROFILE% (falling back to $HOME), so pointing it at a
# throwaway directory is what isolates a case.
$homes = @()
function New-TestHome {
    $d = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(),
        'rogue-cursor-ps-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    $script:homes += $d
    $env:USERPROFILE = $d
    return $d
}
function New-ChildFile {
    param([string]$Root, [string]$Slug, [string]$Parent, [string]$Child)
    $dir = [System.IO.Path]::Combine($Root, '.cursor', 'projects', $Slug, 'agent-transcripts', $Parent, 'subagents')
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($dir, ($Child + '.jsonl')), '')
}
function New-Marker {
    param([string]$Root, [string]$Slug, [string]$Id, [int]$AgeSeconds = 0)
    $dir = [System.IO.Path]::Combine($Root, '.rogue', 'cursor-spawn', $Slug)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $f = [System.IO.Path]::Combine($dir, $Id)
    [System.IO.File]::WriteAllText($f, '')
    if ($AgeSeconds -gt 0) {
        (Get-Item -LiteralPath $f).LastWriteTime = (Get-Date).AddSeconds(-$AgeSeconds)
    }
}
function Set-CachedParent {
    param([string]$Root, [string]$Child, [string]$Parent)
    $dir = [System.IO.Path]::Combine($Root, '.rogue', 'cursor-parent')
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($dir, $Child), $Parent)
}

$WS = '/Users/test/work/proj'
$SLUG = 'Users-test-work-proj'
function New-Payload {
    param([string]$Id)
    # transcript_path is null here exactly as it is on real events, INCLUDING
    # ordinary parent ones; nothing in the dispatcher may branch on it.
    return ('{"conversation_id":"' + $Id + '","session_id":"' + $Id +
            '","workspace_roots":["' + $WS + '"],"transcript_path":null}')
}

# ── Slug derivation ────────────────────────────────────────────────────────
Assert-Eq (Get-RogueWorkspaceSlug (New-Payload 'x')) $SLUG 'slug strips the leading / and maps / and . to -'
Assert-Eq (Get-RogueWorkspaceSlug '{"workspace_roots":["/a/b.c"]}') 'a-b-c' 'slug maps a dotted path segment'
Assert-Eq (Get-RogueWorkspaceSlug '{"conversation_id":"x"}') '' 'no workspace_roots yields an empty slug'
Assert-Eq (Get-RogueWorkspaceSlug 'not json') '' 'unparseable payload yields an empty slug'

# ── Conversation id validation ─────────────────────────────────────────────
# The id becomes a path component, so anything outside the uuid charset is
# rejected rather than looked up.
Assert-True (Test-RogueConversationId 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa') 'a uuid is a conversation id'
Assert-True (-not (Test-RogueConversationId '../../etc/passwd')) 'a traversal-shaped id is rejected'
Assert-True (-not (Test-RogueConversationId '')) 'an empty id is rejected'
Assert-True (-not (Test-RogueConversationId 'a b')) 'an id with a space is rejected'

# ── Lookup: the filename IS the key ────────────────────────────────────────
$h = New-TestHome
$childA = 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'
$parentA = '99999999-9999-4999-8999-999999999999'
New-ChildFile $h $SLUG $parentA $childA
Assert-Eq (Get-RogueCursorParent $childA $SLUG) $parentA 'parent is the agent-transcripts directory name'
Assert-Null (Get-RogueCursorParent 'ffffffff-0000-4000-8000-ffffffffffff' $SLUG) 'a child with no file resolves to nothing'

# Slug-scoping is an OPTIMIZATION: slug derivation has real exceptions on disk
# (numeric slugs, empty-window, .code-workspace-derived names), so a wrong slug
# still resolves through the global scan, which returns the SAME answer.
$h = New-TestHome
$childS = 'dddddddd-1111-4111-8111-dddddddddddd'
$parentS = '77777777-7777-4777-8777-777777777777'
New-ChildFile $h '1784115802260' $parentS $childS
Assert-Eq (Get-RogueCursorParent $childS $SLUG) $parentS 'resolved under a non-derivable slug via the global scan'
Assert-Eq (Get-RogueCursorParent $childS '') $parentS 'resolved with no slug at all'

# Two concurrent subagents under ONE parent: each carries its own id, so each
# finds its own file. Any "newest file wins" rule would hand one of them the
# other's id, which is the single outcome that would make this feature wrong.
$h = New-TestHome
$childX = 'bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb'
$childY = 'cccccccc-1111-4111-8111-cccccccccccc'
$parentXY = '88888888-8888-4888-8888-888888888888'
New-ChildFile $h $SLUG $parentXY $childX
New-ChildFile $h $SLUG $parentXY $childY
(Get-Item -LiteralPath ([System.IO.Path]::Combine($h, '.cursor', 'projects', $SLUG, 'agent-transcripts', $parentXY, 'subagents', ($childX + '.jsonl')))).LastWriteTime = (Get-Date).AddSeconds(-60)
Assert-Eq (Get-RogueCursorParent $childX $SLUG) $parentXY 'concurrent subagent X resolves the shared parent (older file)'
Assert-Eq (Get-RogueCursorParent $childY $SLUG) $parentXY 'concurrent subagent Y resolves the shared parent'

# ── Marker gate: decides WHETHER to wait, never the answer ─────────────────
$h = New-TestHome
Assert-True (-not (Test-RogueSpawnMarkerLive $SLUG)) 'no marker directory means no live marker'
New-Marker $h $SLUG '33333333-3333-4333-8333-333333333333'
Assert-True (Test-RogueSpawnMarkerLive $SLUG) 'a fresh marker is live'
Assert-True (Test-RogueSpawnMarkerLive '') 'a fresh marker is found with no slug (unscoped scan)'
Assert-True (-not (Test-RogueSpawnMarkerLive 'some-other-workspace')) 'markers are scoped per workspace'

$h = New-TestHome
New-Marker $h $SLUG '44444444-4444-4444-8444-444444444444' -AgeSeconds 600
Assert-True (-not (Test-RogueSpawnMarkerLive $SLUG)) 'a marker past the TTL is treated as absent'

# ── subagentStart writes the marker, subagentStop clears it ────────────────
# subagentStart fires ON THE PARENT, so its conversation_id IS the parent's id.
$h = New-TestHome
$parentM = '33333333-3333-4333-8333-333333333333'
Write-RogueSpawnMarker (New-Payload $parentM)
$markerPath = [System.IO.Path]::Combine($h, '.rogue', 'cursor-spawn', $SLUG, $parentM)
Assert-True (Test-Path -LiteralPath $markerPath) 'subagentStart writes ~/.rogue/cursor-spawn/<slug>/<parent id>'
Remove-RogueSpawnMarker (New-Payload $parentM)
Assert-True (-not (Test-Path -LiteralPath $markerPath)) 'subagentStop clears the marker'

# A non-uuid conversation id never becomes a path component.
$h = New-TestHome
Write-RogueSpawnMarker '{"conversation_id":"../../evil","workspace_roots":["/a"]}'
Assert-True (-not (Test-Path -LiteralPath ([System.IO.Path]::Combine($h, '.rogue', 'cursor-spawn')))) 'a traversal-shaped id writes no marker'

# ── Resolution: cache-cold hit, and the cache is written ───────────────────
$h = New-TestHome
New-ChildFile $h $SLUG $parentA $childA
$r = Resolve-RogueParentSession (New-Payload $childA)
Assert-Eq $r.Parent $parentA 'cache-cold resolution returns the parent'
Assert-Eq $r.Child $childA 'cache-cold resolution returns the child id'
$cacheFile = [System.IO.Path]::Combine($h, '.rogue', 'cursor-parent', $childA)
Assert-Eq ([System.IO.File]::ReadAllText($cacheFile)) $parentA 'resolution is cached at ~/.rogue/cursor-parent/<child>'

# A second event reuses the cache. Proven by DELETING the transcript tree first:
# only a cache read can still answer. A subagent fires 18-223 hooks per spawn and
# Cursor reuses a child id across re-spawns, so this is the common path.
Remove-Item -LiteralPath ([System.IO.Path]::Combine($h, '.cursor')) -Recurse -Force
$r = Resolve-RogueParentSession (New-Payload $childA)
Assert-Eq $r.Parent $parentA 'second event resolves from the cache, not the filesystem'

# The cache is read BEFORE any scan: seed a parent that exists nowhere on disk.
$h = New-TestHome
$childC = '2c2c2c2c-1111-4111-8111-2c2c2c2c2c2c'
Set-CachedParent $h $childC 'cached-parent-id'
$r = Resolve-RogueParentSession (New-Payload $childC)
Assert-Eq $r.Parent 'cached-parent-id' 'cache is consulted before the filesystem'

# ── Resolution: fail-open paths ────────────────────────────────────────────
# No marker means NO WAIT AT ALL. A brand-new top-level conversation has no
# directory of its own for ~9s and so looks exactly like an unresolved child;
# without this gate every session start would pay the full budget.
$h = New-TestHome
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r = Resolve-RogueParentSession (New-Payload '22222222-2222-2222-2222-222222222222')
$sw.Stop()
Assert-Null $r 'a main-agent conversation resolves to nothing'
Assert-True ($sw.Elapsed.TotalSeconds -lt 1) "no marker means no wait (took $([math]::Round($sw.Elapsed.TotalSeconds,2))s, budget is ~3s)"

# A stale marker is treated as absent, so it does not arm the wait either.
$h = New-TestHome
New-Marker $h $SLUG '44444444-4444-4444-8444-444444444444' -AgeSeconds 600
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r = Resolve-RogueParentSession (New-Payload '0a0a0a0a-1111-4111-8111-0a0a0a0a0a0a')
$sw.Stop()
Assert-Null $r 'a stale marker resolves to nothing'
Assert-True ($sw.Elapsed.TotalSeconds -lt 1) 'a stale marker does not arm the wait'

# Live marker, file never created: the budget expires and we fail open.
$h = New-TestHome
New-Marker $h $SLUG '55555555-5555-4555-8555-555555555555'
$env:ROGUE_CURSOR_PARENT_ITERS = '3'
$r = Resolve-RogueParentSession (New-Payload 'ffffffff-1111-4111-8111-ffffffffffff')
$env:ROGUE_CURSOR_PARENT_ITERS = $null
Assert-Null $r 'budget expiry resolves to nothing (fail open)'

# Live marker, file appears mid-wait: the wait pays off. File creation is
# INDEPENDENT of hook returns (one spawn's file appeared 2.40s before any
# blocking hook fired), so this wait cannot self-deadlock.
$h = New-TestHome
$childW = 'eeeeeeee-1111-4111-8111-eeeeeeeeeeee'
$parentW = '66666666-6666-4666-8666-666666666666'
New-Marker $h $SLUG $parentW
$job = Start-Job -ScriptBlock {
    param($root, $slug, $parent, $child)
    Start-Sleep -Milliseconds 700
    $dir = [System.IO.Path]::Combine($root, '.cursor', 'projects', $slug, 'agent-transcripts', $parent, 'subagents')
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($dir, ($child + '.jsonl')), '')
} -ArgumentList $h, $SLUG, $parentW, $childW
$r = Resolve-RogueParentSession (New-Payload $childW)
Receive-Job $job -Wait -AutoRemoveJob | Out-Null
Assert-Eq $r.Parent $parentW 'live marker: waited and resolved once the file appeared'
Assert-Eq $r.Child $childW 'mid-wait resolution carries the child id'

# Malformed input never throws and never resolves.
$h = New-TestHome
Assert-Null (Resolve-RogueParentSession '{"conversation_id":"../../etc/passwd"}') 'a traversal-shaped id resolves to nothing'
Assert-Null (Resolve-RogueParentSession 'not json at all') 'an unparseable payload resolves to nothing'
Assert-Null (Resolve-RogueParentSession '{}') 'a payload with no conversation_id resolves to nothing'

# --- File read capture (beforeReadFile) -----------------------------------
# Add-FileReadBytes attaches the file's own bytes as rogueFileReadB64 when the
# payload's `content` is empty. Same lockstep rule as the block above: every
# case here has a case in tests/test_hook_sh_cursor.sh.

# Extension allowlist.
Assert-True (Test-RogueReadCapturePath '/tmp/a.pdf') 'pdf is captured'
Assert-True (Test-RogueReadCapturePath '/tmp/A.PDF') 'the extension test is case-insensitive'
Assert-True (Test-RogueReadCapturePath '/tmp/a.svg') 'svg is captured'
Assert-True (-not (Test-RogueReadCapturePath '/tmp/a.png')) 'png is not captured'
Assert-True (-not (Test-RogueReadCapturePath '/tmp/a.txt')) 'txt is not captured'
Assert-True (-not (Test-RogueReadCapturePath '/tmp/noext')) 'a file with no extension is not captured'
Assert-True (-not (Test-RogueReadCapturePath '/tmp/a.pdf.gz')) 'only the LAST extension counts'

# The truncatable subset. Over the cap, only these are cut short; every other
# allowlisted type attaches nothing at all.
Assert-True (Test-RogueReadCaptureTruncatable '/tmp/a.svg') 'svg is truncatable'
Assert-True (Test-RogueReadCaptureTruncatable '/tmp/A.SVG') 'the truncatable test is case-insensitive'
Assert-True (-not (Test-RogueReadCaptureTruncatable '/tmp/a.pdf')) 'pdf is not truncatable'
Assert-True (-not (Test-RogueReadCaptureTruncatable '/tmp/noext')) 'a file with no extension is not truncatable'

$dir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(),
    'rogue-cursor-read-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null

$pdf = [System.IO.Path]::Combine($dir, 'spec.pdf')
[System.IO.File]::WriteAllBytes($pdf, [byte[]](0x25,0x50,0x44,0x46,0x2D,0x31,0x2E,0x34))
$expected = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($pdf))

$esc = $pdf.Replace('\', '\\')
$body = '{"content":"","file_path":"' + $esc + '"}'
# The WHOLE body is asserted, because a filter that dropped `content` or
# `file_path` while still appending would pass a field-only assertion.
$expectedBody = '{"content":"","file_path":"' + $esc + '","rogueFileReadB64":"' + $expected + '"}'
Assert-Eq (Add-FileReadBytes $body) $expectedBody 'the field is appended and the rest of the body survives'

$busy = '{"content":"already here","file_path":"' + $esc + '"}'
Assert-Eq (Add-FileReadBytes $busy) $busy 'non-empty content leaves the body untouched'

$png = [System.IO.Path]::Combine($dir, 'i.png')
[System.IO.File]::WriteAllBytes($png, [byte[]](1,2,3))
$pngBody = '{"content":"","file_path":"' + $png.Replace('\', '\\') + '"}'
Assert-Eq (Add-FileReadBytes $pngBody) $pngBody 'an extension outside the allowlist leaves the body untouched'

$missing = '{"content":"","file_path":"' + ([System.IO.Path]::Combine($dir, 'nope.pdf')).Replace('\', '\\') + '"}'
Assert-Eq (Add-FileReadBytes $missing) $missing 'a missing file leaves the body untouched'

$emptyFile = [System.IO.Path]::Combine($dir, 'empty.pdf')
[System.IO.File]::WriteAllBytes($emptyFile, [byte[]]@())
$emptyBody = '{"content":"","file_path":"' + $emptyFile.Replace('\', '\\') + '"}'
Assert-Eq (Add-FileReadBytes $emptyBody) $emptyBody 'a zero-byte file leaves the body untouched'

$rel = '{"content":"","file_path":"relative/x.pdf"}'
Assert-Eq (Add-FileReadBytes $rel) $rel 'a relative path leaves the body untouched'

# --- jq path == concat path -----------------------------------------------
# Only one of the two runs on a given machine. Both GitHub runner images ship
# jq and a typical Windows Cursor box has none, so emptying PATH is the only
# way to cover the concat half here.
function Invoke-WithoutJq {
    # NOT named $Body: `& $Action` resolves the scriptblock's free variables
    # against THIS scope first, so that name would shadow the caller's $body and
    # the scriptblock would pass itself.
    param([scriptblock]$Action)
    $rogueSavedPath = $env:PATH
    try { $env:PATH = ''; & $Action } finally { $env:PATH = $rogueSavedPath }
}
Assert-Null (Invoke-WithoutJq { Get-Command jq -ErrorAction SilentlyContinue }) 'emptying PATH really does hide jq'

$concat = Invoke-WithoutJq { Add-FileReadBytes $body }
Assert-Eq $concat $expectedBody 'concat path emits the documented bytes'

# Exactly ONE closing brace is stripped: a TrimEnd would eat both and corrupt a
# body whose last value is a nested object.
$nested = '{"content":"","file_path":"' + $esc + '","meta":{"a":1}}'
$nestedExpected = '{"content":"","file_path":"' + $esc + '","meta":{"a":1},"rogueFileReadB64":"' + $expected + '"}'
$nestedConcat = Invoke-WithoutJq { Add-FileReadBytes $nested }
Assert-Eq $nestedConcat $nestedExpected 'concat path keeps a nested object at the end of the body'

$trailing = $body + "`n  "
Assert-Eq (Invoke-WithoutJq { Add-FileReadBytes $trailing }) $expectedBody 'concat path trims trailing whitespace before the brace strip'

Assert-Eq (Invoke-WithoutJq { Add-FileReadBytes 'not json at all' }) 'not json at all' 'concat path leaves a body with no closing brace alone'

if (Get-Command jq -ErrorAction SilentlyContinue) {
    Assert-Eq (Add-FileReadBytes $body) $concat 'jq and concat agree byte for byte'
    Assert-Eq (Add-FileReadBytes $nested) $nestedConcat 'jq and concat agree on a nested-object body'
} else {
    Write-Host '  skip: jq not installed, jq path not exercised'
}

# --- Over the cap ---------------------------------------------------------
$bytes = New-Object byte[] ($RogueFileReadMaxBytes + 10)
for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = 0x61 }

$big = [System.IO.Path]::Combine($dir, 'big.pdf')
[System.IO.File]::WriteAllBytes($big, $bytes)
$bigBody = '{"content":"","file_path":"' + $big.Replace('\', '\\') + '"}'
Assert-Eq (Add-FileReadBytes $bigBody) $bigBody 'an over-cap non-truncatable type attaches nothing'

# The other half of the split: without this, the assertion above would pass
# just as well if the capture were disabled wholesale.
$bigSvg = [System.IO.Path]::Combine($dir, 'big.svg')
# Distinguishable first and last bytes. With a uniform fill, reading the LAST
# cap-worth of bytes would satisfy a length-only assertion identically.
$bytes[0] = 0x02
$bytes[$bytes.Length - 1] = 0x03
[System.IO.File]::WriteAllBytes($bigSvg, $bytes)
$bigSvgBody = '{"content":"","file_path":"' + $bigSvg.Replace('\', '\\') + '"}'
# A local match, not the ambient $Matches: a failed -match would leave the
# previous case's capture in place and these assertions would read that.
$bigMatch = [regex]::Match((Add-FileReadBytes $bigSvgBody), '"rogueFileReadB64":"([^"]*)"')
Assert-True $bigMatch.Success 'an over-cap truncatable type still attaches a field'
$bigDecoded = [Convert]::FromBase64String($bigMatch.Groups[1].Value)
Assert-Eq $bigDecoded.Length 1048576 'an over-cap truncatable type is cut at the cap'
Assert-Eq $bigDecoded[0] ([byte]0x02) 'the cut keeps the FIRST bytes (a prefix, not the tail)'
Assert-Eq $bigDecoded[$bigDecoded.Length - 1] ([byte]0x61) 'the file last byte is not in the prefix'

# --- Exactly at the cap ---------------------------------------------------
# One byte of slack in the dispatcher's comparison would turn this into a skip.
$atCap = [System.IO.Path]::Combine($dir, 'atcap.pdf')
[System.IO.File]::WriteAllBytes($atCap, (New-Object byte[] 1048576))
$atCapBody = '{"content":"","file_path":"' + $atCap.Replace('\', '\\') + '"}'
$atCapMatch = [regex]::Match((Add-FileReadBytes $atCapBody), '"rogueFileReadB64":"([^"]*)"')
Assert-True $atCapMatch.Success 'a non-truncatable type exactly AT the cap still attaches a field'
Assert-Eq ([Convert]::FromBase64String($atCapMatch.Groups[1].Value)).Length 1048576 'a file exactly AT the cap is sent whole'

Assert-Eq $RogueFileReadMaxBytes 1048576 'cap constant is 1 MiB'

Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue

# ── teardown ───────────────────────────────────────────────────────────────
foreach ($d in $homes) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
$env:USERPROFILE = $null

Write-Host ''
if ($fails -gt 0) {
    Write-Host "$fails of $count Cursor hook.ps1 assertions FAILED"
    exit 1
}
Write-Host "All $count Cursor hook.ps1 assertions passed."
exit 0
