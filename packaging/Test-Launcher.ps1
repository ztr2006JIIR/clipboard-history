[CmdletBinding()]
param(
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')]
    [string]$Version = '1.0.0'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root ("build\$Version")
$payload = Join-Path $build 'payload'
$testRoot = Join-Path $build ('启动测试 with spaces ' + [Guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($testRoot)
foreach ($name in @('ClipboardHistory.exe', 'app-icon.png', 'app-bubble.png')) {
    Copy-Item -LiteralPath (Join-Path $payload $name) -Destination $testRoot
}
$exe = Join-Path $testRoot 'ClipboardHistory.exe'
$missing = Start-Process -FilePath $exe -ArgumentList '--check' -Wait -PassThru -WindowStyle Hidden
if ($missing.ExitCode -ne 1) { throw 'Incomplete installation was not detected.' }
$fakeScript = @'
$ErrorActionPreference = 'Stop'
$result = [ordered]@{
    apartment = [Threading.Thread]::CurrentThread.GetApartmentState().ToString()
    powershell = $PSVersionTable.PSVersion.Major
    root = $PSScriptRoot
}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'result.json'), ($result | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
Write-Output 'synthetic launcher test'
'@
[System.IO.File]::WriteAllText((Join-Path $testRoot 'clipboard-history.ps1'), $fakeScript, [System.Text.UTF8Encoding]::new($true))
$check = Start-Process -FilePath $exe -ArgumentList '--check' -Wait -PassThru -WindowStyle Hidden
if ($check.ExitCode -ne 0 -or (Test-Path -LiteralPath (Join-Path $testRoot 'data'))) { throw 'Check-only mode started the application.' }
$launch = Start-Process -FilePath $exe -Wait -PassThru -WindowStyle Hidden
if ($launch.ExitCode -ne 0) { throw 'Launcher execution failed.' }
$resultPath = Join-Path $testRoot 'result.json'
$result = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($resultPath)) | ConvertFrom-Json
if ($result.apartment -ne 'STA' -or $result.powershell -ne 5 -or $result.root -ne $testRoot) { throw 'Wrong PowerShell apartment, version, or application path.' }
$log = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes((Join-Path $testRoot 'data\launch.log')))
if ($log -notmatch 'synthetic launcher test') { throw 'Application output was not logged.' }
Write-Output 'PASS: missing-file detection, check-only mode, hidden STA launch, Unicode/spaced paths and logging. No clipboard capture was started.'
