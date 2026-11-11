[CmdletBinding()]
param(
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')]
    [string]$Version = '1.0.0',
    [switch]$SkipInstaller
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root ('build\' + $Version)
$payload = Join-Path $build 'payload'
$output = Join-Path $root 'dist'
if (Test-Path -LiteralPath $build) { throw "Use a fresh build directory: $build" }
[void][System.IO.Directory]::CreateDirectory($payload)
[void][System.IO.Directory]::CreateDirectory($output)

$tokens = $null; $parseErrors = $null
$sourceScript = Join-Path $root 'clipboard-history.ps1'
[void][System.Management.Automation.Language.Parser]::ParseFile($sourceScript, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors -join "`n") }

# Copy only application files, never the local data folder or repository metadata.
$files = @('clipboard-history.ps1', 'app-icon.png', 'app-bubble.png', 'README.md', 'Debug-ClipboardHistory.bat')
foreach ($name in $files) { Copy-Item -LiteralPath (Join-Path $root $name) -Destination $payload }

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BuildIconHandle {
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr handle);
}
'@
$bitmap = New-Object System.Drawing.Bitmap((Join-Path $root 'app-icon.png'))
$small = New-Object System.Drawing.Bitmap($bitmap, 32, 32)
$handle = $small.GetHicon()
$icon = [System.Drawing.Icon]::FromHandle($handle)
$stream = [System.IO.File]::Create((Join-Path $payload 'app-icon.ico'))
try { $icon.Save($stream) }
finally {
    $stream.Dispose(); $icon.Dispose(); [void][BuildIconHandle]::DestroyIcon($handle)
    $small.Dispose(); $bitmap.Dispose()
}

$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The Windows .NET Framework compiler was not found.' }
& $compiler /nologo /target:winexe /platform:anycpu /optimize+ /codepage:65001 /reference:System.Windows.Forms.dll "/win32icon:$(Join-Path $payload 'app-icon.ico')" "/win32manifest:$(Join-Path $PSScriptRoot 'launcher.manifest')" "/out:$(Join-Path $payload 'ClipboardHistory.exe')" (Join-Path $PSScriptRoot 'Launcher.cs')
if ($LASTEXITCODE -ne 0) { throw 'Launcher compilation failed.' }

$expected = @($files + @('app-icon.ico', 'ClipboardHistory.exe')) | Sort-Object
$actual = @(Get-ChildItem -LiteralPath $payload -File | Select-Object -ExpandProperty Name) | Sort-Object
if (Compare-Object $expected $actual) { throw 'Unexpected payload file list.' }
$manifest = @(Get-ChildItem -LiteralPath $payload -File | ForEach-Object {
    [ordered]@{ name = $_.Name; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
}) | ConvertTo-Json
[System.IO.File]::WriteAllText((Join-Path $build 'payload-manifest.json'), $manifest, [System.Text.UTF8Encoding]::new($false))

$check = Start-Process -FilePath (Join-Path $payload 'ClipboardHistory.exe') -ArgumentList '--check' -Wait -PassThru -WindowStyle Hidden
if ($check.ExitCode -ne 0) { throw 'Launcher prerequisite check failed.' }
if (Test-Path -LiteralPath (Join-Path $payload 'data')) { throw 'Prerequisite check unexpectedly created user data.' }
if ($SkipInstaller) { Write-Output "Verified launcher and clean payload: $payload"; return }

$inno = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $inno) { throw 'Inno Setup 6 is required. The GitHub release workflow includes it.' }
& $inno "/DAppVersion=$Version" "/DPayloadDir=$payload" "/DOutputPath=$output" (Join-Path $PSScriptRoot 'installer.iss')
if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
$installer = Join-Path $output "ClipboardHistory-Setup-$Version.exe"
$hashLine = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + [System.IO.Path]::GetFileName($installer) + "`n"
[System.IO.File]::WriteAllText(($installer + '.sha256'), $hashLine, [System.Text.UTF8Encoding]::new($false))
Write-Output "Built installer: $installer"
