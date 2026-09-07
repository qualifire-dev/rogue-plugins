$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts/shared/env-file.ps1')
$dir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory $dir | Out-Null
$file = Join-Path $dir 'env'
try {
    [System.IO.File]::WriteAllText($file, 'ROGUE_TEST_VALUE=trusted')
    $unix = $PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows
    if ($unix) { & chmod 600 $file }
    else { $null = Protect-RogueEnvFile $file }
    if (-not (Test-RogueEnvFile $file)) { throw 'owner-only env was rejected' }
    if ((Read-RogueEnvFile $file) -ne 'ROGUE_TEST_VALUE=trusted') { throw 'trusted env not read' }
    if ($unix) { & chmod 666 $file }
    else {
        $acl = Get-Acl -LiteralPath $file
        $everyone = New-Object System.Security.Principal.SecurityIdentifier('S-1-1-0')
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($everyone, 'Write', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $file -AclObject $acl
    }
    if (Test-RogueEnvFile $file) { throw 'world-writable env was trusted' }
    if (@(Read-RogueEnvFile $file).Count -ne 0) { throw 'unsafe env was read' }
    if (Test-RogueEnvFile (Join-Path $dir 'missing')) { throw 'missing env was trusted' }
    Write-Host 'env-file trust: all checks passed'
} finally { Remove-Item -Recurse -Force $dir }
