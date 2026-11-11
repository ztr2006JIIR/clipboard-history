[CmdletBinding()]
param(
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')]
    [string]$Version = '1.0.0'
)

$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Run installation/uninstallation tests only on the disposable GitHub runner.' }
$root = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $root "dist\ClipboardHistory-Setup-$Version.exe"
$testRoot = Join-Path $env:RUNNER_TEMP ('clipboard-installer-test-' + [Guid]::NewGuid().ToString('N'))
$installDir = Join-Path $testRoot 'app'
[void][System.IO.Directory]::CreateDirectory($testRoot)

function Install-TestPackage([string]$LogName) {
    $arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /DIR="' + $installDir + '" /LOG="' + (Join-Path $testRoot $LogName) + '"'
    $process = Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) { throw "Installer failed ($($process.ExitCode))." }
}

Install-TestPackage 'install.log'
$expected = @('ClipboardHistory.exe', 'clipboard-history.ps1', 'app-icon.png', 'app-bubble.png', 'README.md', 'Debug-ClipboardHistory.bat')
foreach ($name in $expected) {
    if (-not (Test-Path -LiteralPath (Join-Path $installDir $name))) { throw "Missing installed file: $name" }
}
if (Test-Path -LiteralPath (Join-Path $installDir 'data')) { throw 'Installer included user history.' }
foreach ($forbidden in @('.git', '.agents', '.codex')) {
    if (Test-Path -LiteralPath (Join-Path $installDir $forbidden)) { throw "Unexpected private directory: $forbidden" }
}
$shortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) '历史粘贴板.lnk'
if (-not (Test-Path -LiteralPath $shortcut)) { throw 'Desktop shortcut is missing.' }
$shell = New-Object -ComObject WScript.Shell
if ($shell.CreateShortcut($shortcut).TargetPath -ne (Join-Path $installDir 'ClipboardHistory.exe')) { throw 'Incorrect shortcut target.' }
$launcher = Start-Process -FilePath (Join-Path $installDir 'ClipboardHistory.exe') -ArgumentList '--check' -PassThru -Wait -WindowStyle Hidden
if ($launcher.ExitCode -ne 0) { throw 'Installed launcher check failed.' }

# Compile the embedded Windows interop helpers without starting clipboard capture.
$text = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes((Join-Path $installDir 'clipboard-history.ps1')))
$embedded = [regex]::Match($text, '(?s)Add-Type -TypeDefinition @"\r?\n(.*?)\r?\n"@')
if (-not $embedded.Success) { throw 'Cannot locate Windows helper source.' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition $embedded.Groups[1].Value

# Run the actual application only in a clean, disposable copy on the CI runner.
# Stop capture timers before exercising layout; no developer clipboard is read.
$smokeDir = Join-Path $testRoot 'smoke'
[void][System.IO.Directory]::CreateDirectory($smokeDir)
foreach ($name in @('app-icon.png', 'app-bubble.png')) {
    Copy-Item -LiteralPath (Join-Path $installDir $name) -Destination $smokeDir
}
$runStatement = '[System.Windows.Forms.Application]::Run($form)'
if (-not $text.Contains($runStatement)) { throw 'Application entry point changed; update the smoke test.' }
$smokeTest = @'
$script:Settings.isHidden = $false
$script:Settings.isCollapsed = $false
try {
    $form.Show()
    $timer.Stop()
    $gridThumbnailTimer.Stop()
    if ($ctrlShortcutTimer) { $ctrlShortcutTimer.Stop() }
    foreach ($size in @(@(1200, 760), @(1600, 900), @(900, 640), @(1200, 760))) {
        $form.Size = New-Object System.Drawing.Size($size[0], $size[1])
        foreach ($mode in @('image', 'text', 'all', 'image')) {
            $script:ViewMode = $mode
            Set-HistoryViewVisibility
            [System.Windows.Forms.Application]::DoEvents()
            $leftLayout.PerformLayout()
            if ($searchHost.Bottom -gt $leftContentHost.Top) { throw 'Search overlaps history content.' }
            if ($viewBar.Bottom -gt $searchHost.Top) { throw 'Categories overlap the search field.' }
            if ($leftContentHost.Height -le 0 -or $imageGrid.Width -le 0) { throw 'Invalid content size.' }
        }
    }
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
    [System.Windows.Forms.Application]::DoEvents()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    [System.Windows.Forms.Application]::DoEvents()
    if ($searchHost.Bottom -gt $leftContentHost.Top) { throw 'Restore overlaps the first image row.' }
    Write-Output 'PASS: application startup, category switching, resizing and maximize/restore layout.'
}
finally {
    $script:AllowExit = $true
    $form.Close()
    $form.Dispose()
}
'@
$smokeFile = Join-Path $smokeDir 'clipboard-history.ps1'
[System.IO.File]::WriteAllText($smokeFile, $text.Replace($runStatement, $smokeTest), [System.Text.UTF8Encoding]::new($true))
& (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -STA -ExecutionPolicy Bypass -File $smokeFile
if ($LASTEXITCODE -ne 0) { throw 'Application startup/layout smoke test failed.' }

# Synthetic history proves reinstall and uninstall never delete user data.
$data = Join-Path $installDir 'data'
[void][System.IO.Directory]::CreateDirectory((Join-Path $data 'images'))
$history = Join-Path $data 'history.json'
$settings = Join-Path $data 'settings.json'
$image = Join-Path $data 'images\synthetic.png'
[System.IO.File]::WriteAllText($history, '[{"kind":"text","text":"installer test only"}]')
[System.IO.File]::WriteAllText($settings, '{"test":true}')
[System.IO.File]::WriteAllBytes($image, [System.IO.File]::ReadAllBytes((Join-Path $installDir 'app-icon.png')))
$before = @{}; foreach ($path in @($history, $settings, $image)) { $before[$path] = (Get-FileHash -LiteralPath $path).Hash }
Install-TestPackage 'reinstall.log'
foreach ($path in $before.Keys) { if ((Get-FileHash -LiteralPath $path).Hash -ne $before[$path]) { throw 'Reinstallation changed history.' } }
$uninstall = Start-Process -FilePath (Join-Path $installDir 'unins000.exe') -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -Wait -PassThru -WindowStyle Hidden
if ($uninstall.ExitCode -ne 0) { throw 'Uninstaller failed.' }
Start-Sleep -Seconds 2
foreach ($path in $before.Keys) { if ((Get-FileHash -LiteralPath $path).Hash -ne $before[$path]) { throw 'Uninstallation removed history.' } }
foreach ($name in $expected) { if (Test-Path -LiteralPath (Join-Path $installDir $name)) { throw "Uninstaller left application file: $name" } }
if (Test-Path -LiteralPath $shortcut) { throw 'Uninstaller left the desktop shortcut.' }
Write-Output 'PASS: installation, shortcut, launcher, Windows helper compilation, reinstall and uninstall history preservation.'
