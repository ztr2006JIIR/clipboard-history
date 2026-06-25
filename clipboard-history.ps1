Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

public sealed class CtrlDoubleTapHook : IDisposable
{
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;
    private const int VK_CONTROL = 0x11;
    private const int VK_LCONTROL = 0xA2;
    private const int VK_RCONTROL = 0xA3;
    private const int DoubleTapMilliseconds = 500;

    private readonly LowLevelKeyboardProc callback;
    private IntPtr hookId = IntPtr.Zero;
    private bool leftCtrlDown;
    private bool rightCtrlDown;
    private bool ctrlUsedWithAnotherKey;
    private long firstTapAt;
    private int doubleTapPending;

    public CtrlDoubleTapHook()
    {
        callback = HookCallback;
        using (Process process = Process.GetCurrentProcess())
        using (ProcessModule module = process.MainModule)
        {
            hookId = SetWindowsHookEx(
                WH_KEYBOARD_LL,
                callback,
                GetModuleHandle(module.ModuleName),
                0);
        }

        if (hookId == IntPtr.Zero)
        {
            throw new System.ComponentModel.Win32Exception(
                Marshal.GetLastWin32Error(),
                "无法安装全局 Ctrl 双击监听。");
        }
    }

    private static bool IsControlKey(int vkCode)
    {
        return vkCode == VK_CONTROL || vkCode == VK_LCONTROL || vkCode == VK_RCONTROL;
    }

    private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            int message = wParam.ToInt32();
            int vkCode = Marshal.ReadInt32(lParam);
            bool isKeyDown = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
            bool isKeyUp = message == WM_KEYUP || message == WM_SYSKEYUP;

            if (IsControlKey(vkCode))
            {
                if (isKeyDown)
                {
                    bool wasAnyCtrlDown = leftCtrlDown || rightCtrlDown;
                    if (vkCode == VK_RCONTROL)
                        rightCtrlDown = true;
                    else
                        leftCtrlDown = true;

                    if (!wasAnyCtrlDown)
                        ctrlUsedWithAnotherKey = false;
                }
                else if (isKeyUp)
                {
                    if (vkCode == VK_RCONTROL)
                        rightCtrlDown = false;
                    else
                        leftCtrlDown = false;

                    if (!leftCtrlDown && !rightCtrlDown)
                    {
                        if (!ctrlUsedWithAnotherKey)
                            RegisterPureCtrlTap();
                        else
                            firstTapAt = 0;
                    }
                }
            }
            else if (isKeyDown && (leftCtrlDown || rightCtrlDown))
            {
                ctrlUsedWithAnotherKey = true;
                firstTapAt = 0;
            }
        }

        return CallNextHookEx(hookId, nCode, wParam, lParam);
    }

    private void RegisterPureCtrlTap()
    {
        long now = DateTime.UtcNow.Ticks / TimeSpan.TicksPerMillisecond;
        if (firstTapAt != 0 && now - firstTapAt <= DoubleTapMilliseconds)
        {
            firstTapAt = 0;
            Interlocked.Exchange(ref doubleTapPending, 1);
        }
        else
        {
            firstTapAt = now;
        }
    }

    public bool ConsumeDoubleTap()
    {
        return Interlocked.Exchange(ref doubleTapPending, 0) == 1;
    }

    public void Dispose()
    {
        if (hookId != IntPtr.Zero)
        {
            UnhookWindowsHookEx(hookId);
            hookId = IntPtr.Zero;
        }
        GC.SuppressFinalize(this);
    }

    ~CtrlDoubleTapHook()
    {
        Dispose();
    }

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(
        int idHook,
        LowLevelKeyboardProc lpfn,
        IntPtr hMod,
        uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(
        IntPtr hhk,
        int nCode,
        IntPtr wParam,
        IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);
}

[ComImport]
[Guid("A5CD92FF-29BE-454C-8D04-D82879FB3F1B")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IVirtualDesktopManager
{
    [PreserveSig]
    int IsWindowOnCurrentVirtualDesktop(IntPtr topLevelWindow, [MarshalAs(UnmanagedType.Bool)] out bool onCurrentDesktop);

    [PreserveSig]
    int GetWindowDesktopId(IntPtr topLevelWindow, out Guid desktopId);

    [PreserveSig]
    int MoveWindowToDesktop(IntPtr topLevelWindow, ref Guid desktopId);
}

public static class VirtualDesktopWindowMover
{
    private static readonly Guid ManagerClassId = new Guid("AA509086-5CA9-4C25-8F95-589D3C07B48A");

    public static void MoveToCurrentDesktop(IntPtr targetWindow)
    {
        object instance = null;
        try
        {
            Type managerType = Type.GetTypeFromCLSID(ManagerClassId, true);
            instance = Activator.CreateInstance(managerType);
            IVirtualDesktopManager manager = (IVirtualDesktopManager)instance;

            Guid desktopId;
            if (!TryGetCurrentDesktopId(manager, targetWindow, out desktopId))
                throw new InvalidOperationException("找不到当前虚拟桌面上的参考窗口。");

            int moveResult = manager.MoveWindowToDesktop(targetWindow, ref desktopId);
            if (moveResult != 0)
                Marshal.ThrowExceptionForHR(moveResult);
        }
        finally
        {
            if (instance != null && Marshal.IsComObject(instance))
                Marshal.FinalReleaseComObject(instance);
        }
    }

    private static bool TryGetCurrentDesktopId(
        IVirtualDesktopManager manager,
        IntPtr targetWindow,
        out Guid desktopId)
    {
        desktopId = Guid.Empty;
        IntPtr foreground = GetForegroundWindow();
        if (foreground != IntPtr.Zero && foreground != targetWindow)
        {
            bool onCurrentDesktop;
            if (manager.IsWindowOnCurrentVirtualDesktop(foreground, out onCurrentDesktop) == 0 &&
                onCurrentDesktop &&
                manager.GetWindowDesktopId(foreground, out desktopId) == 0)
            {
                return true;
            }
        }

        Guid foundDesktopId = Guid.Empty;
        EnumWindows(delegate(IntPtr candidate, IntPtr parameter)
        {
            if (candidate == targetWindow || !IsWindowVisible(candidate))
                return true;

            bool onCurrentDesktop;
            Guid candidateDesktopId;
            if (manager.IsWindowOnCurrentVirtualDesktop(candidate, out onCurrentDesktop) == 0 &&
                onCurrentDesktop &&
                manager.GetWindowDesktopId(candidate, out candidateDesktopId) == 0)
            {
                foundDesktopId = candidateDesktopId;
                return false;
            }
            return true;
        }, IntPtr.Zero);

        desktopId = foundDesktopId;
        return desktopId != Guid.Empty;
    }

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowVisible(IntPtr hWnd);
}
"@

$ErrorActionPreference = "Stop"

$AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $AppRoot "data"
$ImageDir = Join-Path $DataDir "images"
$AppIconFile = Join-Path $AppRoot "app-icon.png"
$BubbleIconFile = Join-Path $AppRoot "app-bubble.png"
$HistoryFile = Join-Path $DataDir "history.json"
$ErrorLogFile = Join-Path $DataDir "error.log"
$SettingsFile = Join-Path $DataDir "settings.json"
$RetentionDays = 3
$BubbleSize = 72
$TransparentColor = [System.Drawing.Color]::FromArgb(255, 1, 2, 3)
$ThemeBack = [System.Drawing.Color]::FromArgb(15, 19, 28)
$ThemePanel = [System.Drawing.Color]::FromArgb(23, 29, 42)
$ThemeCard = [System.Drawing.Color]::FromArgb(27, 35, 49)
$ThemeCardSelected = [System.Drawing.Color]::FromArgb(30, 62, 99)
$ThemeBorder = [System.Drawing.Color]::FromArgb(42, 53, 70)
$ThemeBorderSoft = [System.Drawing.Color]::FromArgb(33, 43, 58)
$ThemeBlue = [System.Drawing.Color]::FromArgb(88, 166, 255)
$ThemeBlueHover = [System.Drawing.Color]::FromArgb(110, 181, 255)
$ThemeText = [System.Drawing.Color]::FromArgb(240, 245, 252)
$ThemeMuted = [System.Drawing.Color]::FromArgb(151, 165, 186)

New-Item -ItemType Directory -Force -Path $DataDir, $ImageDir | Out-Null

function New-Id {
    return [Guid]::NewGuid().ToString("N")
}

function Get-Sha256Text([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = $sha.ComputeHash($bytes)
    return -join ($hash | ForEach-Object { $_.ToString("x2") })
}

function Get-Sha256Bytes([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash($Bytes)
    return -join ($hash | ForEach-Object { $_.ToString("x2") })
}

function Write-ErrorLog($Message, $ErrorRecord) {
    try {
        $time = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $detail = if ($null -ne $ErrorRecord) { [string]$ErrorRecord } else { "" }
        $line = "[$time] $Message $detail"
        Add-Content -LiteralPath $ErrorLogFile -Encoding UTF8 -Value $line
    }
    catch {
        # Logging must never interrupt clipboard monitoring.
    }
}

function New-RoundedRectanglePath([System.Drawing.Rectangle]$Rectangle, [int]$Radius) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $diameter = [Math]::Max(2, $Radius * 2)
    $arc = New-Object System.Drawing.Rectangle -ArgumentList $Rectangle.X, $Rectangle.Y, $diameter, $diameter
    $path.AddArc($arc, 180, 90)
    $arc.X = $Rectangle.Right - $diameter
    $path.AddArc($arc, 270, 90)
    $arc.Y = $Rectangle.Bottom - $diameter
    $path.AddArc($arc, 0, 90)
    $arc.X = $Rectangle.X
    $path.AddArc($arc, 90, 90)
    $path.CloseFigure()
    return $path
}

function Set-RoundedControlRegion($Control, [int]$Radius) {
    if ($null -eq $Control -or $Control.Width -le 0 -or $Control.Height -le 0) {
        return
    }
    $bounds = New-Object System.Drawing.Rectangle -ArgumentList 0, 0, ($Control.Width - 1), ($Control.Height - 1)
    $path = New-RoundedRectanglePath $bounds $Radius
    try {
        $oldRegion = $Control.Region
        $Control.Region = New-Object System.Drawing.Region $path
        if ($oldRegion) { $oldRegion.Dispose() }
    }
    finally {
        $path.Dispose()
    }
}

function Enable-SmoothPainting($Control) {
    if ($null -eq $Control) {
        return
    }

    try {
        $flags = [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic
        $property = $Control.GetType().GetProperty("DoubleBuffered", $flags)
        if ($property) {
            $property.SetValue($Control, $true, $null)
        }
    }
    catch {
        Write-ErrorLog "界面双缓冲启用失败。" $_
    }
}

function Test-IsPathInsideDirectory([string]$Path, [string]$Directory) {
    try {
        $resolvedPath = [System.IO.Path]::GetFullPath($Path)
        $resolvedDirectory = [System.IO.Path]::GetFullPath($Directory)

        $separator = [string][System.IO.Path]::DirectorySeparatorChar
        if (-not $resolvedDirectory.EndsWith($separator)) {
            $resolvedDirectory = [string]::Concat($resolvedDirectory, $separator)
        }

        return $resolvedPath.StartsWith($resolvedDirectory, [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        Write-ErrorLog "路径安全检查失败。" $_
        return $false
    }
}

function Get-DefaultSettings {
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    return [pscustomobject]@{
        isCollapsed = $true
        isHidden = $false
        dockSide = "none"
        bubbleX = $screen.Right - 92
        bubbleY = $screen.Bottom - 120
        expandedX = $screen.Right - 1030
        expandedY = $screen.Bottom - 700
        expandedWidth = 980
        expandedHeight = 650
        leftPanelWidth = 540
        listScale = 1.0
        imageColumns = 0
        previewZoom = 1.0
        viewMode = "all"
    }
}

function Read-Settings {
    $defaults = Get-DefaultSettings
    if (-not (Test-Path -LiteralPath $SettingsFile)) {
        return $defaults
    }

    try {
        $raw = Get-Content -LiteralPath $SettingsFile -Encoding UTF8 -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $defaults
        }

        $saved = $raw | ConvertFrom-Json
        foreach ($name in $defaults.PSObject.Properties.Name) {
            if ($null -eq $saved.PSObject.Properties[$name]) {
                $saved | Add-Member -MemberType NoteProperty -Name $name -Value $defaults.$name
            }
        }
        return $saved
    }
    catch {
        Write-ErrorLog "设置文件读取失败，已使用默认设置。" $_
        return $defaults
    }
}

function Write-Settings {
    try {
        $json = ConvertTo-Json -InputObject $script:Settings -Depth 6
        [System.IO.File]::WriteAllText($SettingsFile, $json, [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        Write-ErrorLog "设置文件保存失败。" $_
    }
}

function Clamp-Value([int]$Value, [int]$Min, [int]$Max) {
    if ($Value -lt $Min) { return $Min }
    if ($Value -gt $Max) { return $Max }
    return $Value
}

function Clamp-Double([double]$Value, [double]$Min, [double]$Max) {
    if ($Value -lt $Min) { return $Min }
    if ($Value -gt $Max) { return $Max }
    return $Value
}

function Get-VisibleScreenForPoint([System.Drawing.Point]$Point) {
    return [System.Windows.Forms.Screen]::FromPoint($Point).WorkingArea
}

function Get-AppIcon {
    $iconPath = if (Test-Path -LiteralPath $BubbleIconFile) { $BubbleIconFile } else { $AppIconFile }
    if (-not (Test-Path -LiteralPath $iconPath)) {
        return [System.Drawing.SystemIcons]::Application
    }

    try {
        $source = [System.Drawing.Image]::FromFile($iconPath)
        try {
            $bitmap = New-Object System.Drawing.Bitmap $source, 32, 32
            return [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
        }
        finally {
            $source.Dispose()
        }
    }
    catch {
        Write-ErrorLog "应用图标加载失败，已使用默认图标。" $_
        return [System.Drawing.SystemIcons]::Application
    }
}

function Get-AppIconImage {
    $imagePath = if (Test-Path -LiteralPath $BubbleIconFile) { $BubbleIconFile } else { $AppIconFile }
    if (-not (Test-Path -LiteralPath $imagePath)) {
        return $null
    }

    try {
        $source = [System.Drawing.Image]::FromFile($imagePath)
        try {
            return (New-Object System.Drawing.Bitmap $source)
        }
        finally {
            $source.Dispose()
        }
    }
    catch {
        Write-ErrorLog "悬浮球图标加载失败。" $_
        return $null
    }
}

function Read-History {
    if (-not (Test-Path -LiteralPath $HistoryFile)) {
        return @()
    }

    try {
        $raw = Get-Content -LiteralPath $HistoryFile -Encoding UTF8 -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return @()
        }
        $items = $raw | ConvertFrom-Json
        if ($null -eq $items) {
            return @()
        }
        if ($items -is [array]) {
            return @($items)
        }
        return @($items)
    }
    catch {
        $backup = Join-Path $DataDir ("history-corrupt-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".json")
        Copy-Item -LiteralPath $HistoryFile -Destination $backup -Force
        Write-ErrorLog "历史记录文件读取失败，已备份损坏文件。" $_
        return @()
    }
}

function Write-History($Items) {
    $normalized = New-Object System.Collections.Generic.List[object]
    foreach ($item in $Items) {
        $normalized.Add($item)
    }

    $json = ConvertTo-Json -InputObject $normalized.ToArray() -Depth 8
    [System.IO.File]::WriteAllText($HistoryFile, $json, [System.Text.UTF8Encoding]::new($false))
}

function Remove-Old-History {
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $items = @(Read-History)
    $kept = New-Object System.Collections.Generic.List[object]
    $removedImagePaths = New-Object System.Collections.Generic.List[string]

    foreach ($item in $items) {
        $createdAt = [DateTime]::MinValue
        if (-not [DateTime]::TryParse([string]$item.createdAt, [ref]$createdAt)) {
            Write-ErrorLog "发现一条日期无效的历史记录，已跳过。" $null
            continue
        }

        if ($createdAt -lt $cutoff) {
            if ($item.kind -eq "image" -and $item.imagePath) {
                $removedImagePaths.Add([string]$item.imagePath)
            }
        }
        else {
            $kept.Add($item)
        }
    }

    foreach ($path in $removedImagePaths) {
        $full = Join-Path $AppRoot $path
        if ((Test-Path -LiteralPath $full) -and (Test-IsPathInsideDirectory $full $ImageDir)) {
            Remove-Item -LiteralPath $full -Force
        }
    }

    Write-History $kept
    return $kept.ToArray()
}

function Get-ClipboardSnapshot {
    if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
        $image = [System.Windows.Forms.Clipboard]::GetImage()
        if ($null -ne $image) {
            $stream = New-Object System.IO.MemoryStream
            try {
                $image.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
                $bytes = $stream.ToArray()
                $hash = "image:" + (Get-Sha256Bytes $bytes)
                $width = $image.Width
                $height = $image.Height
                return [pscustomobject]@{
                    Kind = "image"
                    Hash = $hash
                    Bytes = $bytes
                    Width = $width
                    Height = $height
                    Preview = "[图片] " + $width + " x " + $height
                }
            }
            finally {
                $stream.Dispose()
                $image.Dispose()
            }
        }
    }

    if ([System.Windows.Forms.Clipboard]::ContainsFileDropList()) {
        $files = [System.Windows.Forms.Clipboard]::GetFileDropList()
        $paths = New-Object System.Collections.Generic.List[string]
        foreach ($file in $files) {
            $paths.Add([string]$file)
        }
        if ($paths.Count -gt 0) {
            $pathArray = $paths.ToArray()
            $joined = ($pathArray -join "`n")
            return [pscustomobject]@{
                Kind = "files"
                Hash = "files:" + (Get-Sha256Text $joined)
                Paths = $pathArray
                Preview = "[文件] " + $paths.Count + " 个"
            }
        }
    }

    if ([System.Windows.Forms.Clipboard]::ContainsText([System.Windows.Forms.TextDataFormat]::UnicodeText)) {
        $text = [System.Windows.Forms.Clipboard]::GetText([System.Windows.Forms.TextDataFormat]::UnicodeText)
        if (-not [string]::IsNullOrEmpty($text)) {
            return [pscustomobject]@{
                Kind = "text"
                Hash = "text:" + (Get-Sha256Text $text)
                Text = $text
                Preview = $text
            }
        }
    }

    if ([System.Windows.Forms.Clipboard]::ContainsText([System.Windows.Forms.TextDataFormat]::Html)) {
        $html = [System.Windows.Forms.Clipboard]::GetText([System.Windows.Forms.TextDataFormat]::Html)
        if (-not [string]::IsNullOrEmpty($html)) {
            return [pscustomobject]@{
                Kind = "html"
                Hash = "html:" + (Get-Sha256Text $html)
                Text = $html
                Preview = "[HTML] " + $html.Substring(0, [Math]::Min(120, $html.Length))
            }
        }
    }

    if ([System.Windows.Forms.Clipboard]::ContainsText([System.Windows.Forms.TextDataFormat]::Rtf)) {
        $rtf = [System.Windows.Forms.Clipboard]::GetText([System.Windows.Forms.TextDataFormat]::Rtf)
        if (-not [string]::IsNullOrEmpty($rtf)) {
            return [pscustomobject]@{
                Kind = "rtf"
                Hash = "rtf:" + (Get-Sha256Text $rtf)
                Text = $rtf
                Preview = "[RTF 富文本]"
            }
        }
    }

    return $null
}

function Add-HistoryItem($Snapshot) {
    $items = @(Read-History)
    if ($items.Count -gt 0 -and $items[0].hash -eq $Snapshot.Hash) {
        return $false
    }

    $id = New-Id
    $createdAt = (Get-Date).ToUniversalTime().ToString("o")
    $item = [ordered]@{
        id = $id
        createdAt = $createdAt
        kind = $Snapshot.Kind
        hash = $Snapshot.Hash
        preview = $Snapshot.Preview
    }

    if ($Snapshot.Kind -eq "image") {
        $imageName = $id + ".png"
        $relative = Join-Path "data\images" $imageName
        $full = Join-Path $AppRoot $relative
        [System.IO.File]::WriteAllBytes($full, $Snapshot.Bytes)
        $item["imagePath"] = $relative
        $item["width"] = $Snapshot.Width
        $item["height"] = $Snapshot.Height
    }
    elseif ($Snapshot.Kind -eq "files") {
        $item["paths"] = $Snapshot.Paths
    }
    else {
        $item["text"] = $Snapshot.Text
    }

    $newItems = New-Object System.Collections.Generic.List[object]
    $newItems.Add([pscustomobject]$item)
    foreach ($old in $items) {
        if ($old.hash -ne $Snapshot.Hash) {
            $newItems.Add($old)
        }
    }

    Write-History $newItems
    return $true
}

function Get-ItemTitle($Item) {
    $localTime = ([DateTime]::Parse($Item.createdAt)).ToLocalTime().ToString("MM-dd HH:mm:ss")
    $prefix = switch ($Item.kind) {
        "image" { "[图片]" }
        "files" { "[文件]" }
        "html" { "[HTML]" }
        "rtf" { "[RTF]" }
        default { "[文字]" }
    }
    $preview = [string]$Item.preview
    $preview = $preview -replace "\s+", " "
    if ($preview.Length -gt 60) {
        $preview = $preview.Substring(0, 60) + "..."
    }
    return "$localTime $prefix $preview"
}

function Set-ClipboardDataObjectReliable(
    [System.Windows.Forms.DataObject]$Data,
    [string]$RequiredFormat,
    [int]$ExpectedCount
) {
    try {
        [System.Windows.Forms.Clipboard]::SetDataObject($Data, $true, 10, 80)
        Start-Sleep -Milliseconds 60
        switch ($RequiredFormat) {
            "FileDrop" {
                if (-not [System.Windows.Forms.Clipboard]::ContainsFileDropList()) {
                    return $false
                }
                return ([System.Windows.Forms.Clipboard]::GetFileDropList().Count -ge $ExpectedCount)
            }
            "Bitmap" {
                return [System.Windows.Forms.Clipboard]::ContainsImage()
            }
            default {
                return [System.Windows.Forms.Clipboard]::ContainsText([System.Windows.Forms.TextDataFormat]::UnicodeText)
            }
        }
    }
    catch {
        Write-ErrorLog "写入剪贴板失败。" $_
        return $false
    }
}

function Add-ClipboardCopyEffect([System.Windows.Forms.DataObject]$Data) {
    $effectBytes = [byte[]](1, 0, 0, 0)
    $effectStream = New-Object System.IO.MemoryStream -ArgumentList (,$effectBytes)
    $Data.SetData("Preferred DropEffect", $false, $effectStream)
    return $effectStream
}

function Set-ClipboardFromItem($Item) {
    switch ($Item.kind) {
        "image" {
            $full = Join-Path $AppRoot ([string]$Item.imagePath)
            if (Test-Path -LiteralPath $full) {
                $img = [System.Drawing.Image]::FromFile($full)
                $bmp = $null
                try {
                    $bmp = New-Object System.Drawing.Bitmap $img
                    $data = New-Object System.Windows.Forms.DataObject
                    $data.SetImage($bmp)
                    if (Set-ClipboardDataObjectReliable $data "Bitmap" 1) {
                        return 1
                    }
                }
                finally {
                    $img.Dispose()
                    if ($bmp) {
                        $bmp.Dispose()
                    }
                }
            }
            return 0
        }
        "files" {
            $collection = New-Object System.Collections.Specialized.StringCollection
            foreach ($path in $Item.paths) {
                if (Test-Path -LiteralPath ([string]$path)) {
                    [void]$collection.Add([string]$path)
                }
            }
            if ($collection.Count -eq 0) {
                return 0
            }
            $data = New-Object System.Windows.Forms.DataObject
            $effectStream = $null
            try {
                $data.SetFileDropList($collection)
                $effectStream = Add-ClipboardCopyEffect $data
                if (Set-ClipboardDataObjectReliable $data "FileDrop" $collection.Count) {
                    return $collection.Count
                }
            }
            finally {
                if ($effectStream) { $effectStream.Dispose() }
            }
            return 0
        }
        default {
            $text = [string]$Item.text
            if ([string]::IsNullOrEmpty($text)) {
                return 0
            }
            $data = New-Object System.Windows.Forms.DataObject
            $data.SetText($text, [System.Windows.Forms.TextDataFormat]::UnicodeText)
            $data.SetText($text)
            if (Set-ClipboardDataObjectReliable $data "UnicodeText" 1) {
                return 1
            }
            return 0
        }
    }
}

function Set-ClipboardFromItems($Items) {
    $selectedItems = @($Items | Where-Object { $null -ne $_ })
    if ($selectedItems.Count -eq 0) {
        return 0
    }

    if ($selectedItems.Count -eq 1) {
        return (Set-ClipboardFromItem $selectedItems[0])
    }

    $imageItems = @($selectedItems | Where-Object { $_.kind -eq "image" })
    if ($imageItems.Count -ne $selectedItems.Count) {
        Set-ClipboardFromItem $selectedItems[0]
        return 1
    }

    $files = New-Object System.Collections.Specialized.StringCollection
    foreach ($item in $imageItems) {
        $full = Join-Path $AppRoot ([string]$item.imagePath)
        if (Test-Path -LiteralPath $full) {
            [void]$files.Add($full)
        }
    }

    if ($files.Count -eq 0) {
        return 0
    }

    $data = New-Object System.Windows.Forms.DataObject
    $effectStream = $null
    try {
        $data.SetFileDropList($files)
        $effectStream = Add-ClipboardCopyEffect $data
        if (Set-ClipboardDataObjectReliable $data "FileDrop" $files.Count) {
            return $files.Count
        }
    }
    finally {
        if ($effectStream) { $effectStream.Dispose() }
    }
    return 0
}

function Clear-ThumbnailCache {
    foreach ($thumb in $script:ThumbnailCache.Values) {
        if ($thumb) {
            $thumb.Dispose()
        }
    }
    $script:ThumbnailCache.Clear()
}

function Prune-ThumbnailCache {
    $staleKeys = New-Object System.Collections.Generic.List[string]
    foreach ($key in $script:ThumbnailCache.Keys) {
        if (-not (Test-Path -LiteralPath $key)) {
            $staleKeys.Add([string]$key)
        }
    }

    foreach ($key in $staleKeys) {
        $thumb = $script:ThumbnailCache[$key]
        if ($thumb) {
            $thumb.Dispose()
        }
        $script:ThumbnailCache.Remove($key)
    }
}

function Get-Thumbnail([string]$RelativePath) {
    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        return $null
    }

    $full = Join-Path $AppRoot $RelativePath
    if (-not (Test-Path -LiteralPath $full)) {
        return $null
    }

    if ($script:ThumbnailCache.ContainsKey($full)) {
        return $script:ThumbnailCache[$full]
    }

    try {
        $source = [System.Drawing.Image]::FromFile($full)
        try {
            $thumbWidth = [int](104 * $script:ListScale)
            $thumbHeight = [int](78 * $script:ListScale)
            $thumb = New-Object System.Drawing.Bitmap -ArgumentList $thumbWidth, $thumbHeight
            $g = [System.Drawing.Graphics]::FromImage($thumb)
            try {
                $g.Clear([System.Drawing.Color]::FromArgb(32, 32, 32))
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $scale = [Math]::Min($thumbWidth / $source.Width, $thumbHeight / $source.Height)
                $drawWidth = [int]($source.Width * $scale)
                $drawHeight = [int]($source.Height * $scale)
                $drawX = [int](($thumbWidth - $drawWidth) / 2)
                $drawY = [int](($thumbHeight - $drawHeight) / 2)
                $g.DrawImage($source, $drawX, $drawY, $drawWidth, $drawHeight)
            }
            finally {
                $g.Dispose()
            }

            $script:ThumbnailCache[$full] = $thumb
            return $thumb
        }
        finally {
            $source.Dispose()
        }
    }
    catch {
        Write-ErrorLog "图片缩略图生成失败。" $_
        return $null
    }
}

$script:HistoryItems = @(Remove-Old-History)
$script:LastHash = $null
$script:LastPurge = Get-Date
$script:Settings = Read-Settings
$script:IsCollapsed = [bool]$script:Settings.isCollapsed
$script:IsDraggingBubble = $false
$script:BubbleMouseDown = $false
$script:BubbleMouseDownPoint = [System.Drawing.Point]::Empty
$script:BubbleStartLocation = [System.Drawing.Point]::Empty
$script:AllowExit = $false
$script:LastNonMinimizedWindowState = [System.Windows.Forms.FormWindowState]::Normal
$script:IsNormalizingSplitLayout = $false
$script:ThumbnailCache = @{}
$script:DisplayItems = @()
$script:ListScale = [double]$script:Settings.listScale
$script:ImageColumns = [int]$script:Settings.imageColumns
if ($script:ImageColumns -lt 1) {
    $script:ImageColumns = [int](Clamp-Value ([Math]::Round(4 / [Math]::Max(0.75, $script:ListScale))) 1 6)
    $script:Settings.imageColumns = $script:ImageColumns
}
$script:PreviewZoom = [double]$script:Settings.previewZoom
$script:ViewMode = [string]$script:Settings.viewMode
if (@("all", "image", "text") -notcontains $script:ViewMode) {
    $script:ViewMode = "all"
    $script:Settings.viewMode = $script:ViewMode
}
$script:DragStartPoint = [System.Drawing.Point]::Empty
$script:DragItem = $null
$script:ImageSelectedIndices = New-Object 'System.Collections.Generic.HashSet[int]'
$script:ImageSelectionAnchor = -1
$script:ImageRubberStart = [System.Drawing.Point]::Empty
$script:ImageRubberRect = [System.Drawing.Rectangle]::Empty
$script:ImageRubberBaseSelection = @()
$script:IsImageRubberSelecting = $false
$script:ImageWheelAccumulator = 0
$script:UiDirty = $true
$script:SuppressPreviewRefresh = $false
$script:GridThumbnailCache = @{}
$script:GridThumbnailQueue = New-Object System.Collections.Generic.Queue[int]
$script:GridThumbnailPending = New-Object 'System.Collections.Generic.HashSet[int]'
$script:LastImageGridScrollAt = [DateTime]::MinValue
$script:DrawCardBrush = New-Object System.Drawing.SolidBrush $ThemeCard
$script:DrawSelectedCardBrush = New-Object System.Drawing.SolidBrush $ThemeCardSelected
$script:DrawBorderPen = New-Object System.Drawing.Pen $ThemeBorderSoft
$script:DrawSelectedBorderPen = New-Object System.Drawing.Pen $ThemeBlue
$script:DrawBorderPen.Width = 1
$script:DrawSelectedBorderPen.Width = 1.4
$script:DrawTitleBrush = New-Object System.Drawing.SolidBrush $ThemeText
$script:DrawBodyBrush = New-Object System.Drawing.SolidBrush $ThemeMuted
$script:DrawAccentBrush = New-Object System.Drawing.SolidBrush $ThemeBlue
$script:DrawMissingBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(36, 43, 55))
$script:DrawTextFormat = New-Object System.Drawing.StringFormat
$script:DrawTextFormat.Trimming = [System.Drawing.StringTrimming]::EllipsisWord
$script:DrawTextFormat.FormatFlags = [System.Drawing.StringFormatFlags]::LineLimit

$form = New-Object System.Windows.Forms.Form
$form.Text = "历史粘贴板 - 自动保存 3 天"
$form.Width = [int]$script:Settings.expandedWidth
$form.Height = [int]$script:Settings.expandedHeight
$form.StartPosition = "Manual"
$form.Location = New-Object System.Drawing.Point -ArgumentList ([int]$script:Settings.expandedX), ([int]$script:Settings.expandedY)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.TopMost = $true
$form.KeyPreview = $true
$form.ShowInTaskbar = $false
$form.BackColor = $ThemeBack
$form.MinimumSize = New-Object System.Drawing.Size -ArgumentList 760, 480
Enable-SmoothPainting $form

$leftPanel = New-Object System.Windows.Forms.Panel
$leftPanel.Dock = "Left"
$leftPanel.Width = [int]$script:Settings.leftPanelWidth
$leftPanel.Padding = New-Object System.Windows.Forms.Padding(12)
$leftPanel.BackColor = $ThemeBack
$leftPanel.TabStop = $true
Enable-SmoothPainting $leftPanel

$splitter = New-Object System.Windows.Forms.Splitter
$splitter.Dock = "Left"
$splitter.Width = 10
$splitter.MinSize = 260
$splitter.MinExtra = 320
$splitter.BackColor = $ThemeBack
$splitter.Cursor = [System.Windows.Forms.Cursors]::VSplit

$searchHost = New-Object System.Windows.Forms.Panel
$searchHost.Dock = "Top"
$searchHost.Height = 42
$searchHost.Padding = New-Object System.Windows.Forms.Padding(13, 8, 13, 7)
$searchHost.BackColor = $ThemeBack
Enable-SmoothPainting $searchHost

$searchBox = New-Object System.Windows.Forms.TextBox
$searchBox.Dock = "Fill"
$searchBox.BorderStyle = "None"
$searchBox.BackColor = $ThemePanel
$searchBox.ForeColor = $ThemeText
$searchBox.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)

$viewBar = New-Object System.Windows.Forms.FlowLayoutPanel
$viewBar.Dock = "Top"
$viewBar.Height = 50
$viewBar.FlowDirection = "LeftToRight"
$viewBar.BackColor = $ThemeBack
$viewBar.Padding = New-Object System.Windows.Forms.Padding(0, 12, 0, 0)
Enable-SmoothPainting $viewBar

$allModeButton = New-Object System.Windows.Forms.Button
$allModeButton.Text = "▦  全部"
$allModeButton.Width = 88
$allModeButton.Height = 32

$imageModeButton = New-Object System.Windows.Forms.Button
$imageModeButton.Text = "▣  图片"
$imageModeButton.Width = 88
$imageModeButton.Height = 32

$textModeButton = New-Object System.Windows.Forms.Button
$textModeButton.Text = "▤  文字"
$textModeButton.Width = 88
$textModeButton.Height = 32

$list = New-Object System.Windows.Forms.ListBox
$list.Dock = "Fill"
$list.HorizontalScrollbar = $false
$list.IntegralHeight = $false
$list.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawVariable
$list.BorderStyle = "None"
$list.BackColor = $ThemeBack
$list.ForeColor = $ThemeText
Enable-SmoothPainting $list

$imageGrid = New-Object System.Windows.Forms.Panel
$imageGrid.Dock = "Fill"
$imageGrid.BackColor = $ThemeBack
$imageGrid.AutoScroll = $true
$imageGrid.Visible = $false
$imageGrid.TabStop = $true
Enable-SmoothPainting $imageGrid

$panel = New-Object System.Windows.Forms.Panel
$panel.Dock = "Fill"
$panel.Padding = New-Object System.Windows.Forms.Padding(12)
$panel.BackColor = $ThemeBack
Enable-SmoothPainting $panel

$buttons = New-Object System.Windows.Forms.FlowLayoutPanel
$buttons.Dock = "Top"
$buttons.Height = 52
$buttons.FlowDirection = "LeftToRight"
$buttons.BackColor = $ThemeBack
Enable-SmoothPainting $buttons

$copyButton = New-Object System.Windows.Forms.Button
$copyButton.Text = "▣  复制回剪贴板"
$copyButton.Width = 154
$copyButton.Height = 34

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = "↻  刷新"
$refreshButton.Width = 82
$refreshButton.Height = 34

$collapseButton = New-Object System.Windows.Forms.Button
$collapseButton.Text = "—  收起"
$collapseButton.Width = 82
$collapseButton.Height = 34

$hideButton = New-Object System.Windows.Forms.Button
$hideButton.Text = "□  隐藏"
$hideButton.Width = 82
$hideButton.Height = 34

$script:ButtonPrimaryStates = @{}

function Set-ToolButtonStyle($Button, [bool]$Primary) {
    $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $Button.FlatAppearance.BorderSize = 0
    $Button.UseVisualStyleBackColor = $false
    $Button.BackColor = $ThemeBack
    $Button.ForeColor = $ThemeText
    $Button.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Button.Margin = New-Object System.Windows.Forms.Padding(0, 0, 9, 8)
    $script:ButtonPrimaryStates[$Button.GetHashCode()] = $Primary
    $Button.Invalidate()
}

Set-ToolButtonStyle $copyButton $true
Set-ToolButtonStyle $refreshButton $false
Set-ToolButtonStyle $collapseButton $false
Set-ToolButtonStyle $hideButton $false
Set-ToolButtonStyle $allModeButton ($script:ViewMode -eq "all")
Set-ToolButtonStyle $imageModeButton ($script:ViewMode -eq "image")
Set-ToolButtonStyle $textModeButton ($script:ViewMode -eq "text")

foreach ($button in @($copyButton, $refreshButton, $collapseButton, $hideButton, $allModeButton, $imageModeButton, $textModeButton)) {
    $button.Add_Paint({
        param($sender, $e)
        $primary = [bool]$script:ButtonPrimaryStates[$sender.GetHashCode()]
        $hovered = $sender.ClientRectangle.Contains($sender.PointToClient([System.Windows.Forms.Control]::MousePosition))
        $pressed = $hovered -and (([System.Windows.Forms.Control]::MouseButtons -band [System.Windows.Forms.MouseButtons]::Left) -ne 0)
        $fillColor = if ($primary) {
            if ($pressed) { [System.Drawing.Color]::FromArgb(68, 140, 226) } elseif ($hovered) { $ThemeBlueHover } else { $ThemeBlue }
        }
        else {
            if ($pressed) { $ThemeCardSelected } elseif ($hovered) { [System.Drawing.Color]::FromArgb(34, 44, 60) } else { $ThemePanel }
        }
        $rect = New-Object System.Drawing.Rectangle -ArgumentList 1, 1, ($sender.Width - 3), ($sender.Height - 3)
        $radius = [Math]::Max(10, [int](($sender.Height - 3) / 2))
        $path = New-RoundedRectanglePath $rect $radius
        $brush = New-Object System.Drawing.SolidBrush $fillColor
        try {
            $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $e.Graphics.Clear($ThemeBack)
            $e.Graphics.FillPath($brush, $path)
            [System.Windows.Forms.TextRenderer]::DrawText(
                $e.Graphics,
                $sender.Text,
                $sender.Font,
                $rect,
                $ThemeText,
                [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor
                [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor
                [System.Windows.Forms.TextFormatFlags]::NoPadding
            )
        }
        finally {
            $brush.Dispose()
            $path.Dispose()
        }
    })
    $button.Add_MouseEnter({ param($sender, $e) $sender.Invalidate() })
    $button.Add_MouseLeave({ param($sender, $e) $sender.Invalidate() })
    $button.Add_MouseDown({ param($sender, $e) $sender.Invalidate() })
    $button.Add_MouseUp({ param($sender, $e) $sender.Invalidate() })
}

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "正在监听复制内容..."
$statusLabel.AutoSize = $true
$statusLabel.Padding = New-Object System.Windows.Forms.Padding(8, 9, 0, 0)
$statusLabel.ForeColor = $ThemeMuted
$statusLabel.BackColor = $ThemeBack

$bubblePicture = New-Object System.Windows.Forms.PictureBox
$bubblePicture.Dock = "Fill"
$bubblePicture.BackColor = $TransparentColor
$bubblePicture.Cursor = [System.Windows.Forms.Cursors]::Hand
$bubblePicture.Visible = $false
$bubblePicture.Image = Get-AppIconImage
$bubblePicture.SizeMode = "StretchImage"

$previewText = New-Object System.Windows.Forms.TextBox
$previewText.Multiline = $true
$previewText.ScrollBars = "Both"
$previewText.ReadOnly = $true
$previewText.Dock = "Fill"
$previewText.Font = New-Object System.Drawing.Font("Consolas", 10)
$previewText.BackColor = $ThemePanel
$previewText.ForeColor = $ThemeText
$previewText.BorderStyle = "None"

$picture = New-Object System.Windows.Forms.PictureBox
$picture.Dock = "Fill"
$picture.SizeMode = "Zoom"
$picture.Visible = $false
$picture.BackColor = [System.Drawing.Color]::FromArgb(10, 13, 19)

$previewHost = New-Object System.Windows.Forms.Panel
$previewHost.Dock = "Fill"
$previewHost.BackColor = [System.Drawing.Color]::FromArgb(10, 13, 19)
$previewHost.AutoScroll = $true
$previewHost.Visible = $false
$previewHost.TabStop = $true
Enable-SmoothPainting $previewHost

$previewSurface = New-Object System.Windows.Forms.Panel
$previewSurface.Dock = "Fill"
$previewSurface.Padding = New-Object System.Windows.Forms.Padding(7)
$previewSurface.BackColor = $ThemeBack
Enable-SmoothPainting $previewSurface

$searchHost.Add_Paint({
    param($sender, $e)
    $rect = New-Object System.Drawing.Rectangle -ArgumentList 1, 1, ($sender.Width - 3), ($sender.Height - 3)
    $path = New-RoundedRectanglePath $rect 13
    $brush = New-Object System.Drawing.SolidBrush $ThemePanel
    $pen = New-Object System.Drawing.Pen $ThemeBorderSoft
    try {
        $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $e.Graphics.FillPath($brush, $path)
        $e.Graphics.DrawPath($pen, $path)
    }
    finally {
        $pen.Dispose()
        $brush.Dispose()
        $path.Dispose()
    }
})

$previewSurface.Add_Paint({
    param($sender, $e)
    $rect = New-Object System.Drawing.Rectangle -ArgumentList 1, 1, ($sender.Width - 3), ($sender.Height - 3)
    $path = New-RoundedRectanglePath $rect 16
    $brush = New-Object System.Drawing.SolidBrush $ThemePanel
    try {
        $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $e.Graphics.FillPath($brush, $path)
    }
    finally {
        $brush.Dispose()
        $path.Dispose()
    }
})

$splitter.Add_Paint({
    param($sender, $e)
    $lineRect = New-Object System.Drawing.Rectangle -ArgumentList ([int](($sender.Width - 2) / 2)), 10, 2, ([Math]::Max(1, $sender.Height - 20))
    $path = New-RoundedRectanglePath $lineRect 1
    $brush = New-Object System.Drawing.SolidBrush $ThemeBorderSoft
    try {
        $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $e.Graphics.FillPath($brush, $path)
    }
    finally {
        $brush.Dispose()
        $path.Dispose()
    }
})

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 8000
$toolTip.InitialDelay = 450
$toolTip.ReshowDelay = 120
$toolTip.SetToolTip($searchBox, "输入文字、文件路径或图片尺寸进行筛选")
$toolTip.SetToolTip($copyButton, "把当前选中的内容放回系统剪贴板；多张图片会作为可粘贴的文件组复制")
$toolTip.SetToolTip($allModeButton, "查看全部历史内容")
$toolTip.SetToolTip($imageModeButton, "只查看图片，并支持框选和多选")
$toolTip.SetToolTip($textModeButton, "只查看文字内容")
$toolTip.SetToolTip($collapseButton, "收起为桌面悬浮球")
$toolTip.SetToolTip($hideButton, "隐藏到系统托盘并继续监听")

$buttons.Controls.Add($copyButton)
$buttons.Controls.Add($refreshButton)
$buttons.Controls.Add($collapseButton)
$buttons.Controls.Add($hideButton)
$buttons.Controls.Add($statusLabel)
$viewBar.Controls.Add($allModeButton)
$viewBar.Controls.Add($imageModeButton)
$viewBar.Controls.Add($textModeButton)
$searchHost.Controls.Add($searchBox)
$previewHost.Controls.Add($picture)
$previewSurface.Controls.Add($previewText)
$previewSurface.Controls.Add($previewHost)
$panel.Controls.Add($previewSurface)
$panel.Controls.Add($buttons)
$leftPanel.Controls.Add($list)
$leftPanel.Controls.Add($imageGrid)
$leftPanel.Controls.Add($viewBar)
$leftPanel.Controls.Add($searchHost)
$form.Controls.Add($panel)
$form.Controls.Add($splitter)
$form.Controls.Add($leftPanel)
$form.Controls.Add($bubblePicture)

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$openMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
$openMenuItem.Text = "打开历史"
$bubbleMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
$bubbleMenuItem.Text = "显示悬浮球"
$exitMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
$exitMenuItem.Text = "退出"
[void]$trayMenu.Items.Add($openMenuItem)
[void]$trayMenu.Items.Add($bubbleMenuItem)
[void]$trayMenu.Items.Add("-")
[void]$trayMenu.Items.Add($exitMenuItem)

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = Get-AppIcon
$notifyIcon.Text = "历史粘贴板正在运行"
$notifyIcon.ContextMenuStrip = $trayMenu
$notifyIcon.Visible = $true

function Get-HistorySearchText($Item) {
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add([string]$Item.kind)
    $parts.Add([string]$Item.preview)
    if ($Item.text) {
        $parts.Add([string]$Item.text)
    }
    if ($Item.paths) {
        $parts.Add(($Item.paths -join " "))
    }
    if ($Item.kind -eq "image") {
        $parts.Add(([string]$Item.width + "x" + [string]$Item.height))
        $parts.Add(([string]$Item.width + " x " + [string]$Item.height))
    }
    return ($parts.ToArray() -join " ")
}

function Test-HistoryItemMatch($Item, [string]$Query) {
    if ([string]::IsNullOrWhiteSpace($Query)) {
        return $true
    }
    $haystack = Get-HistorySearchText $Item
    return ($haystack.IndexOf($Query, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Test-HistoryItemModeMatch($Item) {
    switch ($script:ViewMode) {
        "image" { return ($Item.kind -eq "image") }
        "text" { return ($Item.kind -eq "text" -or $Item.kind -eq "html" -or $Item.kind -eq "rtf") }
        default { return $true }
    }
}

function Get-ViewModeText {
    switch ($script:ViewMode) {
        "image" { return "图片" }
        "text" { return "文字" }
        default { return "全部" }
    }
}

function Update-ModeButtons {
    Set-ToolButtonStyle $allModeButton ($script:ViewMode -eq "all")
    Set-ToolButtonStyle $imageModeButton ($script:ViewMode -eq "image")
    Set-ToolButtonStyle $textModeButton ($script:ViewMode -eq "text")
}

function Clear-GridThumbnailCache {
    foreach ($thumb in $script:GridThumbnailCache.Values) {
        if ($thumb) { $thumb.Dispose() }
    }
    $script:GridThumbnailCache.Clear()
    $script:GridThumbnailQueue.Clear()
    $script:GridThumbnailPending.Clear()
}

function Get-GridThumbnail($Item) {
    $full = Join-Path $AppRoot ([string]$Item.imagePath)
    if (-not (Test-Path -LiteralPath $full)) {
        return $null
    }

    if ($script:GridThumbnailCache.ContainsKey($full)) {
        return $script:GridThumbnailCache[$full]
    }

    try {
        $source = [System.Drawing.Image]::FromFile($full)
        try {
            $maxSide = 360
            $scale = [Math]::Min(1.0, $maxSide / [Math]::Max($source.Width, $source.Height))
            $width = [Math]::Max(1, [int]($source.Width * $scale))
            $height = [Math]::Max(1, [int]($source.Height * $scale))
            $thumb = New-Object System.Drawing.Bitmap -ArgumentList $width, $height
            $g = [System.Drawing.Graphics]::FromImage($thumb)
            try {
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.DrawImage($source, 0, 0, $width, $height)
            }
            finally {
                $g.Dispose()
            }
            $script:GridThumbnailCache[$full] = $thumb
            return $thumb
        }
        finally {
            $source.Dispose()
        }
    }
    catch {
        Write-ErrorLog "图片网格缩略图生成失败。" $_
        return $null
    }
}

function Queue-GridThumbnail([int]$Index) {
    if ($Index -lt 0 -or $Index -ge $script:DisplayItems.Count) {
        return
    }

    $full = Join-Path $AppRoot ([string]$script:DisplayItems[$Index].imagePath)
    if ($script:GridThumbnailCache.ContainsKey($full)) {
        return
    }

    if ($script:GridThumbnailPending.Add($Index)) {
        $script:GridThumbnailQueue.Enqueue($Index)
    }
}

function Get-MaxImageColumns {
    $padding = 8
    $gap = 8
    $scrollbarAllowance = 18
    $minimumCellWidth = 54
    $usableWidth = [Math]::Max($minimumCellWidth, $imageGrid.ClientSize.Width - ($padding * 2) - $scrollbarAllowance)
    $columns = [int][Math]::Floor(($usableWidth + $gap) / ($minimumCellWidth + $gap))
    return (Clamp-Value $columns 1 12)
}

function Normalize-ImageColumns {
    $maxColumns = Get-MaxImageColumns
    $script:ImageColumns = Clamp-Value $script:ImageColumns 1 $maxColumns
    $script:Settings.imageColumns = $script:ImageColumns
}

function Get-ImageGridMetrics {
    Normalize-ImageColumns
    $padding = 8
    $gap = 8
    $scrollbarAllowance = 18
    $usableWidth = [Math]::Max(100, $imageGrid.ClientSize.Width - ($padding * 2) - $scrollbarAllowance)
    $cellWidth = [Math]::Max(54, [int][Math]::Floor(($usableWidth - (($script:ImageColumns - 1) * $gap)) / $script:ImageColumns))
    $imageHeight = [Math]::Max(42, [int]($cellWidth * 0.68))
    $cellHeight = $imageHeight + 42
    $rowHeight = $cellHeight + $gap
    $rows = if ($script:DisplayItems.Count -gt 0) { [int][Math]::Ceiling($script:DisplayItems.Count / [double]$script:ImageColumns) } else { 0 }
    return [pscustomobject]@{
        Padding = $padding
        Gap = $gap
        CellWidth = $cellWidth
        ImageHeight = $imageHeight
        CellHeight = $cellHeight
        RowHeight = $rowHeight
        Rows = $rows
        ContentHeight = ($padding * 2) + ($rows * $rowHeight)
    }
}

function Get-ImageCellRectangle([int]$Index, $Metrics) {
    $row = [int][Math]::Floor($Index / $script:ImageColumns)
    $column = $Index % $script:ImageColumns
    $x = $Metrics.Padding + ($column * ($Metrics.CellWidth + $Metrics.Gap))
    $y = $Metrics.Padding + ($row * $Metrics.RowHeight)
    return New-Object System.Drawing.Rectangle -ArgumentList $x, $y, $Metrics.CellWidth, $Metrics.CellHeight
}

function Update-ImageGridLayout([bool]$KeepScroll) {
    $oldY = if ($KeepScroll) { -$imageGrid.AutoScrollPosition.Y } else { 0 }
    $metrics = Get-ImageGridMetrics
    $imageGrid.AutoScrollMinSize = New-Object System.Drawing.Size -ArgumentList 0, $metrics.ContentHeight
    if ($KeepScroll -and $oldY -gt 0) {
        $imageGrid.AutoScrollPosition = New-Object System.Drawing.Point -ArgumentList 0, $oldY
    }
    $imageGrid.Invalidate()
}

function Set-HistoryViewVisibility {
    $showImageGrid = ($script:ViewMode -eq "image")
    $imageGrid.Visible = $showImageGrid
    $list.Visible = -not $showImageGrid
    if ($showImageGrid) {
        $imageGrid.BringToFront()
    }
    else {
        $list.BringToFront()
    }
    $viewBar.BringToFront()
    $searchHost.BringToFront()
}

function Adjust-ImageGridColumns([int]$Direction) {
    $oldColumns = $script:ImageColumns
    # Positive direction enlarges cards, so fewer pictures are shown per row.
    $script:ImageColumns = $script:ImageColumns - $Direction
    Normalize-ImageColumns
    if ($script:ImageColumns -ne $oldColumns) {
        Write-Settings
        Set-HistoryViewVisibility
        Update-ImageGridLayout $true
        $statusLabel.Text = "图片排版：每行 " + $script:ImageColumns + " 张"
    }
}

function Populate-ImageGrid([string]$SelectedId) {
    $previousIds = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($id in @($script:PendingImageSelectionIds)) {
        if ($id) { [void]$previousIds.Add([string]$id) }
    }
    if ($SelectedId) { [void]$previousIds.Add($SelectedId) }

    $script:ImageSelectedIndices.Clear()
    for ($i = 0; $i -lt $script:DisplayItems.Count; $i++) {
        if ($previousIds.Contains([string]$script:DisplayItems[$i].id)) {
            [void]$script:ImageSelectedIndices.Add($i)
        }
    }
    if ($script:ImageSelectedIndices.Count -eq 0 -and $script:DisplayItems.Count -gt 0) {
        [void]$script:ImageSelectedIndices.Add(0)
        $script:ImageSelectionAnchor = 0
    }
    $script:PendingImageSelectionIds = @()
    $script:GridThumbnailQueue.Clear()
    $script:GridThumbnailPending.Clear()
    Update-ImageGridLayout $false
}

function Populate-List([string]$SelectedId) {
    $list.BeginUpdate()
    try {
        $list.Items.Clear()
        foreach ($item in $script:DisplayItems) {
            [void]$list.Items.Add((Get-ItemTitle $item))
        }

        if ($SelectedId) {
            for ($i = 0; $i -lt $script:DisplayItems.Count; $i++) {
                if ([string]$script:DisplayItems[$i].id -eq $SelectedId) {
                    $list.SelectedIndex = $i
                    break
                }
            }
        }

        if ($list.SelectedIndex -lt 0 -and $list.Items.Count -gt 0) {
            $list.SelectedIndex = 0
        }
    }
    finally {
        $list.EndUpdate()
    }
    $list.Invalidate()
}

function Get-SelectedDisplayIndex {
    if ($script:ViewMode -eq "image") {
        if ($script:ImageSelectedIndices.Count -gt 0) {
            return [int](@($script:ImageSelectedIndices | Sort-Object)[0])
        }
        return -1
    }
    return $list.SelectedIndex
}

function Get-SelectedHistoryItem {
    $idx = Get-SelectedDisplayIndex
    if ($idx -lt 0 -or $idx -ge $script:DisplayItems.Count) {
        return $null
    }
    return $script:DisplayItems[$idx]
}

function Get-SelectedHistoryItems {
    $items = New-Object System.Collections.Generic.List[object]

    if ($script:ViewMode -eq "image") {
        foreach ($idx in @($script:ImageSelectedIndices | Sort-Object)) {
            if ($idx -ge 0 -and $idx -lt $script:DisplayItems.Count) {
                $items.Add($script:DisplayItems[$idx])
            }
        }
        return @($items.ToArray())
    }

    $single = Get-SelectedHistoryItem
    if ($null -ne $single) {
        $items.Add($single)
    }
    return @($items.ToArray())
}

function Apply-Filter {
    $query = $searchBox.Text.Trim()
    $selected = Get-SelectedHistoryItem
    $selectedId = if ($selected) { [string]$selected.id } else { $null }
    $script:PendingImageSelectionIds = @(
        foreach ($idx in $script:ImageSelectedIndices) {
            if ($idx -ge 0 -and $idx -lt $script:DisplayItems.Count) {
                [string]$script:DisplayItems[$idx].id
            }
        }
    )
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($item in $script:HistoryItems) {
        if ((Test-HistoryItemModeMatch $item) -and (Test-HistoryItemMatch $item $query)) {
            $items.Add($item)
        }
    }

    $script:DisplayItems = @($items.ToArray())
    Set-HistoryViewVisibility

    if ($script:ViewMode -eq "image") {
        Populate-ImageGrid $selectedId
    }
    else {
        Populate-List $selectedId
    }

    if ($script:DisplayItems.Count -eq 0) {
        $previewText.Visible = $true
        $previewHost.Visible = $false
        $picture.Visible = $false
        $previewText.Text = "没有匹配的历史记录。"
    }
    elseif (-not $script:SuppressPreviewRefresh) {
        Show-Selected
    }

    $modeText = Get-ViewModeText
    if ([string]::IsNullOrWhiteSpace($query)) {
        $statusLabel.Text = $modeText + "：共 " + $script:DisplayItems.Count + " 条，保留最近 3 天"
    }
    else {
        $statusLabel.Text = $modeText + "：匹配 " + $script:DisplayItems.Count + " / " + $script:HistoryItems.Count + " 条"
    }
}

function Refresh-List {
    $script:HistoryItems = @(Remove-Old-History)
    # Keep already-rendered thumbnails. Recreating them from large source images
    # during every refresh was the main cause of stutter while scrolling.
    Prune-ThumbnailCache
    Apply-Filter
}

function Refresh-ListLayout {
    $selected = Get-SelectedHistoryItem
    $selectedId = if ($selected) { [string]$selected.id } else { $null }

    if ($script:ViewMode -eq "image") {
        Update-ImageGridLayout $true
    }
    else {
        Clear-ThumbnailCache
        Populate-List $selectedId
    }
}

function Adjust-LeftLayout([int]$WheelDelta) {
    if ($script:ViewMode -eq "image") {
        $script:ImageWheelAccumulator += $WheelDelta
        if ([Math]::Abs($script:ImageWheelAccumulator) -lt 120) {
            return
        }
        $steps = [int][Math]::Truncate($script:ImageWheelAccumulator / 120)
        $script:ImageWheelAccumulator -= ($steps * 120)
        Adjust-ImageGridColumns $steps
        return
    }

    $direction = if ($WheelDelta -gt 0) { 1 } else { -1 }
    $script:ListScale = Clamp-Double ($script:ListScale + (0.08 * $direction)) 0.75 1.65
    $minLeft = 280
    $maxLeft = [Math]::Max($minLeft, $form.ClientSize.Width - 360)
    $leftPanel.Width = Clamp-Value ($leftPanel.Width + (36 * $direction)) $minLeft $maxLeft
    $script:Settings.listScale = [Math]::Round($script:ListScale, 2)
    $script:Settings.leftPanelWidth = $leftPanel.Width
    Write-Settings
    Refresh-ListLayout
}

function Update-PreviewZoom {
    if ($null -eq $picture.Image) {
        return
    }

    if ($script:PreviewZoom -le 1.02) {
        $previewHost.AutoScroll = $false
        $picture.Dock = "Fill"
        $picture.SizeMode = "Zoom"
        return
    }

    $previewHost.AutoScroll = $true
    $picture.Dock = "None"
    $picture.SizeMode = "StretchImage"

    $availableWidth = [Math]::Max(80, $previewHost.ClientSize.Width - 8)
    $availableHeight = [Math]::Max(80, $previewHost.ClientSize.Height - 8)
    $fitScale = [Math]::Min($availableWidth / $picture.Image.Width, $availableHeight / $picture.Image.Height)
    $scale = $fitScale * $script:PreviewZoom
    $newWidth = [Math]::Max(20, [int]($picture.Image.Width * $scale))
    $newHeight = [Math]::Max(20, [int]($picture.Image.Height * $scale))
    $x = [Math]::Max(0, [int](($availableWidth - $newWidth) / 2))
    $y = [Math]::Max(0, [int](($availableHeight - $newHeight) / 2))

    $picture.Size = New-Object System.Drawing.Size -ArgumentList $newWidth, $newHeight
    $picture.Location = New-Object System.Drawing.Point -ArgumentList $x, $y
}

function Adjust-PreviewZoom([int]$WheelDelta) {
    $direction = if ($WheelDelta -gt 0) { 1 } else { -1 }
    $script:PreviewZoom = Clamp-Double ($script:PreviewZoom + (0.15 * $direction)) 0.6 4.0
    $script:Settings.previewZoom = [Math]::Round($script:PreviewZoom, 2)
    Write-Settings
    Update-PreviewZoom
    $statusLabel.Text = "图片缩放 " + [int]($script:PreviewZoom * 100) + "%"
}

function Get-ListItemHeight($Item) {
    if ($null -eq $Item) {
        return 72
    }
    if ($Item.kind -eq "image") {
        return [int](104 * $script:ListScale)
    }
    return [int](82 * $script:ListScale)
}

function Draw-HistoryListItem($EventArgs) {
    $idx = $EventArgs.Index
    if ($idx -lt 0 -or $idx -ge $script:DisplayItems.Count) {
        return
    }

    $item = $script:DisplayItems[$idx]
    $bounds = $EventArgs.Bounds
    $graphics = $EventArgs.Graphics
    $selected = (($EventArgs.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0)

    $backBrush = if ($selected) { $script:DrawSelectedCardBrush } else { $script:DrawCardBrush }
    $borderPen = if ($selected) { $script:DrawSelectedBorderPen } else { $script:DrawBorderPen }
    $titleBrush = $script:DrawTitleBrush
    $bodyBrush = $script:DrawBodyBrush
    $mutedBrush = $script:DrawAccentBrush
    $format = $script:DrawTextFormat
    $clipState = $null
    $cardPath = $null

    try {
        $card = New-Object System.Drawing.Rectangle -ArgumentList ($bounds.X + 4), ($bounds.Y + 4), ($bounds.Width - 8), ($bounds.Height - 8)
        $cardPath = New-RoundedRectanglePath $card 14
        $graphics.FillPath($backBrush, $cardPath)
        $graphics.DrawPath($borderPen, $cardPath)
        $clipState = $graphics.Save()
        $graphics.SetClip($card)

        $time = ([DateTime]::Parse($item.createdAt)).ToLocalTime().ToString("MM-dd HH:mm:ss")
        $kindText = switch ($item.kind) {
            "image" { "图片" }
            "files" { "文件" }
            "html" { "HTML" }
            "rtf" { "RTF" }
            default { "文字" }
        }
        $title = "$time  $kindText"
        $titleRect = New-Object System.Drawing.RectangleF -ArgumentList ($card.X + 10), ($card.Y + 8), ($card.Width - 20), 20
        $graphics.DrawString($title, $list.Font, $titleBrush, $titleRect, $format)

        if ($item.kind -eq "image") {
            $thumbWidth = [int](104 * $script:ListScale)
            $thumbHeight = [int](78 * $script:ListScale)
            $thumbRect = New-Object System.Drawing.Rectangle -ArgumentList ($card.X + 10), ($card.Y + 32), $thumbWidth, $thumbHeight
            $thumbPath = New-RoundedRectanglePath $thumbRect 9
            $thumbClip = $graphics.Save()
            $graphics.SetClip($thumbPath)
            $thumb = Get-Thumbnail ([string]$item.imagePath)
            if ($thumb) {
                $graphics.DrawImage($thumb, $thumbRect)
            }
            else {
                $graphics.FillPath($script:DrawMissingBrush, $thumbPath)
            }
            $graphics.Restore($thumbClip)
            $thumbPath.Dispose()
            $textRect = New-Object System.Drawing.RectangleF -ArgumentList ($card.X + 20 + $thumbWidth), ($card.Y + 34), ($card.Width - 30 - $thumbWidth), ([int](56 * $script:ListScale))
            $imageInfo = "图片尺寸: " + $item.width + " x " + $item.height
            $graphics.DrawString($imageInfo, $list.Font, $bodyBrush, $textRect, $format)
        }
        elseif ($item.kind -eq "files") {
            $body = ($item.paths -join [Environment]::NewLine)
            $bodyRect = New-Object System.Drawing.RectangleF -ArgumentList ($card.X + 10), ($card.Y + 34), ($card.Width - 20), 38
            $graphics.DrawString($body, $list.Font, $bodyBrush, $bodyRect, $format)
        }
        else {
            $body = [string]$item.text
            if ([string]::IsNullOrWhiteSpace($body)) {
                $body = [string]$item.preview
            }
            $body = $body -replace "\s+", " "
            $bodyRect = New-Object System.Drawing.RectangleF -ArgumentList ($card.X + 10), ($card.Y + 34), ($card.Width - 20), 38
            $graphics.DrawString($body, $list.Font, $bodyBrush, $bodyRect, $format)
        }

        if ($idx -eq 0) {
            $latestRect = New-Object System.Drawing.RectangleF -ArgumentList ($card.Right - 52), ($card.Y + 8), 42, 18
            $graphics.DrawString("最新", $list.Font, $mutedBrush, $latestRect, $format)
        }
    }
    finally {
        if ($clipState) {
            $graphics.Restore($clipState)
        }
        if ($cardPath) {
            $cardPath.Dispose()
        }
    }
}

function Show-Selected {
    $selectedItems = @(Get-SelectedHistoryItems)
    if ($script:ViewMode -eq "image" -and $selectedItems.Count -gt 1) {
        $picture.Visible = $false
        $previewHost.Visible = $false
        $previewText.Visible = $true
        $previewText.Text = "已选择 " + $selectedItems.Count + " 张图片。" + [Environment]::NewLine + "点击复制回剪贴板会把这些图片作为文件列表复制；也可以直接从左侧拖出去。"
        return
    }

    $item = Get-SelectedHistoryItem
    if ($null -eq $item) {
        return
    }
    $picture.Visible = $false
    $previewHost.Visible = $false
    $previewText.Visible = $true

    if ($item.kind -eq "image") {
        $full = Join-Path $AppRoot ([string]$item.imagePath)
        if (Test-Path -LiteralPath $full) {
            if ($picture.Image) {
                $picture.Image.Dispose()
            }
            $img = [System.Drawing.Image]::FromFile($full)
            try {
                $picture.Image = New-Object System.Drawing.Bitmap $img
            }
            finally {
                $img.Dispose()
            }
            $previewText.Visible = $false
            $previewHost.Visible = $true
            $picture.Visible = $true
            Update-PreviewZoom
        }
        else {
            $previewText.Text = "图片文件已经不存在。"
        }
    }
    elseif ($item.kind -eq "files") {
        $previewHost.Visible = $false
        $previewText.Text = ($item.paths -join [Environment]::NewLine)
    }
    else {
        $previewHost.Visible = $false
        $previewText.Text = [string]$item.text
    }
}

function Start-HistoryDrag($Item, $Control) {
    if ($null -eq $Item -or $null -eq $Control) {
        return
    }

    $data = New-Object System.Windows.Forms.DataObject
    $dragImage = $null

    try {
        switch ($Item.kind) {
            "image" {
                $full = Join-Path $AppRoot ([string]$Item.imagePath)
                if (-not (Test-Path -LiteralPath $full)) {
                    return
                }

                $files = New-Object System.Collections.Specialized.StringCollection
                [void]$files.Add($full)
                $data.SetFileDropList($files)

                $source = [System.Drawing.Image]::FromFile($full)
                try {
                    $dragImage = New-Object System.Drawing.Bitmap $source
                    $data.SetImage($dragImage)
                }
                finally {
                    $source.Dispose()
                }
            }
            "files" {
                $files = New-Object System.Collections.Specialized.StringCollection
                foreach ($path in $Item.paths) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$path)) {
                        [void]$files.Add([string]$path)
                    }
                }
                if ($files.Count -eq 0) {
                    return
                }
                $data.SetFileDropList($files)
            }
            default {
                $text = [string]$Item.text
                if ([string]::IsNullOrEmpty($text)) {
                    $text = [string]$Item.preview
                }
                if ([string]::IsNullOrEmpty($text)) {
                    return
                }
                $data.SetText($text, [System.Windows.Forms.TextDataFormat]::UnicodeText)
                $data.SetText($text)
            }
        }

        [void]$Control.DoDragDrop($data, [System.Windows.Forms.DragDropEffects]::Copy)
    }
    catch {
        Write-ErrorLog "拖拽复制失败。" $_
        $statusLabel.Text = "拖拽复制失败，可以先点复制回剪贴板"
    }
    finally {
        if ($dragImage) {
            $dragImage.Dispose()
        }
    }
}

function Start-HistoryDragItems($Items, $Control) {
    $selectedItems = @($Items | Where-Object { $null -ne $_ })
    if ($selectedItems.Count -eq 0 -or $null -eq $Control) {
        return
    }

    if ($selectedItems.Count -eq 1) {
        Start-HistoryDrag $selectedItems[0] $Control
        return
    }

    $imageItems = @($selectedItems | Where-Object { $_.kind -eq "image" })
    if ($imageItems.Count -ne $selectedItems.Count) {
        Start-HistoryDrag $selectedItems[0] $Control
        return
    }

    $data = New-Object System.Windows.Forms.DataObject
    $files = New-Object System.Collections.Specialized.StringCollection
    foreach ($item in $imageItems) {
        $full = Join-Path $AppRoot ([string]$item.imagePath)
        if (Test-Path -LiteralPath $full) {
            [void]$files.Add($full)
        }
    }

    if ($files.Count -eq 0) {
        return
    }

    try {
        $data.SetFileDropList($files)
        [void]$Control.DoDragDrop($data, [System.Windows.Forms.DragDropEffects]::Copy)
    }
    catch {
        Write-ErrorLog "多图拖拽复制失败。" $_
        $statusLabel.Text = "多图拖拽失败，可以先点复制回剪贴板"
    }
}

function Test-DragDistance {
    if ($null -eq $script:DragItem) {
        return $false
    }

    $current = [System.Windows.Forms.Control]::MousePosition
    $dx = [Math]::Abs($current.X - $script:DragStartPoint.X)
    $dy = [Math]::Abs($current.Y - $script:DragStartPoint.Y)
    return ($dx -ge 5 -or $dy -ge 5)
}

function Begin-DragCandidate($Item) {
    $script:DragItem = $Item
    $script:DragStartPoint = [System.Windows.Forms.Control]::MousePosition
}

function Clear-DragCandidate {
    $script:DragItem = $null
    $script:DragStartPoint = [System.Drawing.Point]::Empty
}

function Save-ExpandedBounds {
    if (-not $script:IsCollapsed -and $form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal) {
        $script:Settings.expandedX = $form.Location.X
        $script:Settings.expandedY = $form.Location.Y
        $script:Settings.expandedWidth = $form.Width
        $script:Settings.expandedHeight = $form.Height
        $script:Settings.leftPanelWidth = $leftPanel.Width
    }
}

function Normalize-SplitLayout([bool]$SaveSetting) {
    if ($script:IsCollapsed -or $script:IsNormalizingSplitLayout -or $form.ClientSize.Width -le 0) {
        return
    }

    $minLeft = 280
    $minRight = 360
    $maxLeft = [Math]::Max($minLeft, $form.ClientSize.Width - $splitter.Width - $minRight)
    $normalizedWidth = Clamp-Value ([int]$leftPanel.Width) $minLeft $maxLeft

    if ($leftPanel.Width -ne $normalizedWidth) {
        $script:IsNormalizingSplitLayout = $true
        try {
            $leftPanel.Width = $normalizedWidth
        }
        finally {
            $script:IsNormalizingSplitLayout = $false
        }
    }

    if ($SaveSetting -and $form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal) {
        $script:Settings.leftPanelWidth = $leftPanel.Width
        Write-Settings
    }

    if ($imageGrid.Visible) {
        Update-ImageGridLayout $true
    }
}

function Save-BubbleBounds {
    $script:Settings.bubbleX = $form.Location.X
    $script:Settings.bubbleY = $form.Location.Y
}

function Snap-BubbleToScreenEdge {
    $centerPoint = New-Object System.Drawing.Point -ArgumentList ([int]($form.Location.X + 28)), ([int]($form.Location.Y + 28))
    $screen = Get-VisibleScreenForPoint $centerPoint
    $x = $form.Location.X
    $y = $form.Location.Y
    $dockSide = "none"
    $snapDistance = 24
    $half = [int]($BubbleSize / 2)

    if ([Math]::Abs($x - $screen.Left) -le $snapDistance) {
        $x = $screen.Left - $half
        $dockSide = "left"
    }
    elseif ([Math]::Abs(($x + $BubbleSize) - $screen.Right) -le $snapDistance) {
        $x = $screen.Right - $half
        $dockSide = "right"
    }
    elseif ([Math]::Abs($y - $screen.Top) -le $snapDistance) {
        $y = $screen.Top - $half
        $dockSide = "top"
    }
    elseif ([Math]::Abs(($y + $BubbleSize) - $screen.Bottom) -le $snapDistance) {
        $y = $screen.Bottom - $half
        $dockSide = "bottom"
    }
    else {
        $x = Clamp-Value $x $screen.Left ($screen.Right - $BubbleSize)
        $y = Clamp-Value $y $screen.Top ($screen.Bottom - $BubbleSize)
    }

    if ($dockSide -eq "left" -or $dockSide -eq "right") {
        $y = Clamp-Value $y $screen.Top ($screen.Bottom - $BubbleSize)
    }
    elseif ($dockSide -eq "top" -or $dockSide -eq "bottom") {
        $x = Clamp-Value $x $screen.Left ($screen.Right - $BubbleSize)
    }

    $form.Location = New-Object System.Drawing.Point -ArgumentList ([int]$x), ([int]$y)
    $script:Settings.dockSide = $dockSide
    Save-BubbleBounds
    Write-Settings
}

function Show-Bubble {
    Save-ExpandedBounds
    if ($form.WindowState -ne [System.Windows.Forms.FormWindowState]::Minimized) {
        $script:LastNonMinimizedWindowState = $form.WindowState
    }
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $script:IsCollapsed = $true
    $script:Settings.isCollapsed = $true
    $script:Settings.isHidden = $false

    if ($form.Region) {
        $form.Region.Dispose()
        $form.Region = $null
    }

    $form.SuspendLayout()
    $leftPanel.Visible = $false
    $splitter.Visible = $false
    $list.Visible = $false
    $panel.Visible = $false
    $bubblePicture.Visible = $true
    $bubblePicture.BringToFront()
    $form.FormBorderStyle = "None"
    $form.ControlBox = $false
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.BackColor = $TransparentColor
    $form.TransparencyKey = $TransparentColor
    $form.Size = New-Object System.Drawing.Size -ArgumentList ([int]$BubbleSize), ([int]$BubbleSize)
    $form.MinimumSize = New-Object System.Drawing.Size -ArgumentList ([int]$BubbleSize), ([int]$BubbleSize)
    $form.MaximumSize = New-Object System.Drawing.Size -ArgumentList ([int]$BubbleSize), ([int]$BubbleSize)
    $form.Location = New-Object System.Drawing.Point -ArgumentList ([int]$script:Settings.bubbleX), ([int]$script:Settings.bubbleY)
    $form.ResumeLayout($true)

    Snap-BubbleToScreenEdge
    $form.Show()
    $bubblePicture.Invalidate()
    $form.Invalidate()
    $form.Activate()
}

function Show-HistoryPanel {
    if ($script:IsCollapsed) {
        Save-BubbleBounds
    }
    $script:IsCollapsed = $false
    $script:Settings.isCollapsed = $false
    $script:Settings.isHidden = $false

    if ($form.Region) {
        $form.Region.Dispose()
        $form.Region = $null
    }

    $bubblePoint = New-Object System.Drawing.Point -ArgumentList ([int]$script:Settings.bubbleX), ([int]$script:Settings.bubbleY)
    $screen = Get-VisibleScreenForPoint $bubblePoint
    $width = Clamp-Value ([int]$script:Settings.expandedWidth) 640 $screen.Width
    $height = Clamp-Value ([int]$script:Settings.expandedHeight) 420 $screen.Height
    $x = Clamp-Value ([int]$script:Settings.expandedX) $screen.Left ($screen.Right - $width)
    $y = Clamp-Value ([int]$script:Settings.expandedY) $screen.Top ($screen.Bottom - $height)

    # Hide the 72px bubble before changing the same form into a large window.
    # This prevents the old bubble and splitter from being visibly stretched.
    $form.Hide()
    Move-HistoryWindowToCurrentDesktop
    $form.SuspendLayout()
    $form.MinimumSize = New-Object System.Drawing.Size -ArgumentList 640, 420
    $form.MaximumSize = New-Object System.Drawing.Size -ArgumentList 0, 0
    $form.FormBorderStyle = "Sizable"
    $form.ControlBox = $true
    $form.MinimizeBox = $true
    $form.MaximizeBox = $true
    $form.BackColor = $ThemeBack
    $form.TransparencyKey = [System.Drawing.Color]::Empty
    $form.Size = New-Object System.Drawing.Size -ArgumentList ([int]$width), ([int]$height)
    $form.Location = New-Object System.Drawing.Point -ArgumentList ([int]$x), ([int]$y)
    $leftPanel.Width = [int]$script:Settings.leftPanelWidth
    $bubblePicture.Visible = $false
    $leftPanel.Visible = $true
    $splitter.Visible = $true
    Set-HistoryViewVisibility
    $panel.Visible = $true
    $form.ResumeLayout($true)
    Normalize-SplitLayout $true

    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $form.WindowState = $script:LastNonMinimizedWindowState
    }
    elseif ($script:LastNonMinimizedWindowState -eq [System.Windows.Forms.FormWindowState]::Maximized) {
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
    }

    if ($script:UiDirty) {
        $script:SuppressPreviewRefresh = $true
        try {
            Apply-Filter
        }
        finally {
            $script:SuppressPreviewRefresh = $false
        }
        $script:UiDirty = $false
    }
    elseif ($imageGrid.Visible) {
        Update-ImageGridLayout $true
    }
    Write-Settings
    $form.Show()
    $form.Activate()
    [void]$form.BeginInvoke([System.Action]{
        Show-Selected
    })
}

function Move-HistoryWindowToCurrentDesktop {
    try {
        # The foreground application is already on the virtual desktop the
        # user is viewing. Reuse its desktop id without creating any helper
        # window, which avoids a Desktop Window Manager refresh/flash.
        [VirtualDesktopWindowMover]::MoveToCurrentDesktop($form.Handle)
    }
    catch {
        Write-ErrorLog "把历史窗口移动到当前虚拟桌面失败。" $_
    }
}

function Hide-ToTray {
    if ($script:IsCollapsed) {
        Save-BubbleBounds
    }
    else {
        Save-ExpandedBounds
    }

    $script:Settings.isHidden = $true
    Write-Settings
    $form.Hide()
}

function Exit-App {
    $script:AllowExit = $true
    $notifyIcon.Visible = $false
    $form.Close()
}

try {
    $script:CtrlDoubleTapHook = New-Object CtrlDoubleTapHook
    $ctrlShortcutTimer = New-Object System.Windows.Forms.Timer
    $ctrlShortcutTimer.Interval = 60
    $ctrlShortcutTimer.Add_Tick({
        if ($script:CtrlDoubleTapHook -and $script:CtrlDoubleTapHook.ConsumeDoubleTap()) {
            Show-HistoryPanel
        }
    })
    $ctrlShortcutTimer.Start()
}
catch {
    $script:CtrlDoubleTapHook = $null
    $ctrlShortcutTimer = $null
    Write-ErrorLog "Ctrl 双击快捷键监听启动失败。" $_
}

$list.Add_SelectedIndexChanged({ Show-Selected })

$imageGrid.Add_Paint({
    param($sender, $e)
    $metrics = Get-ImageGridMetrics
    $scrollY = -$imageGrid.AutoScrollPosition.Y
    $firstRow = [Math]::Max(0, [int][Math]::Floor($scrollY / $metrics.RowHeight))
    $lastRow = [Math]::Min($metrics.Rows - 1, [int][Math]::Ceiling(($scrollY + $imageGrid.ClientSize.Height) / $metrics.RowHeight))
    if ($lastRow -lt $firstRow) { return }

    $e.Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $textFormat = New-Object System.Drawing.StringFormat
    $textFormat.Alignment = [System.Drawing.StringAlignment]::Center
    $textFormat.LineAlignment = [System.Drawing.StringAlignment]::Center
    try {
        $firstIndex = $firstRow * $script:ImageColumns
        $lastIndex = [Math]::Min($script:DisplayItems.Count - 1, (($lastRow + 1) * $script:ImageColumns) - 1)
        for ($i = $firstIndex; $i -le $lastIndex; $i++) {
            $contentRect = Get-ImageCellRectangle $i $metrics
            $card = New-Object System.Drawing.Rectangle -ArgumentList $contentRect.X, ($contentRect.Y - $scrollY), $contentRect.Width, $contentRect.Height
            $selected = $script:ImageSelectedIndices.Contains($i)
            $cardBrush = if ($selected) { $script:DrawSelectedCardBrush } else { $script:DrawCardBrush }
            $cardPen = if ($selected) { $script:DrawSelectedBorderPen } else { $script:DrawBorderPen }
            $path = New-RoundedRectanglePath $card 14
            try {
                $e.Graphics.FillPath($cardBrush, $path)
                $e.Graphics.DrawPath($cardPen, $path)
            }
            finally { $path.Dispose() }

            $imageRect = New-Object System.Drawing.Rectangle -ArgumentList ($card.X + 7), ($card.Y + 7), ($card.Width - 14), ($metrics.ImageHeight - 10)
            $imagePath = New-RoundedRectanglePath $imageRect 10
            $e.Graphics.FillPath($script:DrawMissingBrush, $imagePath)
            $oldClip = $e.Graphics.Save()
            $e.Graphics.SetClip($imagePath)
            $item = $script:DisplayItems[$i]
            $full = Join-Path $AppRoot ([string]$item.imagePath)
            $thumb = if ($script:GridThumbnailCache.ContainsKey($full)) { $script:GridThumbnailCache[$full] } else { $null }
            if ($thumb) {
                $scale = [Math]::Min($imageRect.Width / $thumb.Width, $imageRect.Height / $thumb.Height)
                $drawWidth = [Math]::Max(1, [int]($thumb.Width * $scale))
                $drawHeight = [Math]::Max(1, [int]($thumb.Height * $scale))
                $drawX = $imageRect.X + [int](($imageRect.Width - $drawWidth) / 2)
                $drawY = $imageRect.Y + [int](($imageRect.Height - $drawHeight) / 2)
                $e.Graphics.DrawImage($thumb, $drawX, $drawY, $drawWidth, $drawHeight)
            }
            else {
                Queue-GridThumbnail $i
            }
            $e.Graphics.Restore($oldClip)
            $imagePath.Dispose()

            $localTime = ([DateTime]::Parse($item.createdAt)).ToLocalTime()
            if ($metrics.CellWidth -lt 82) {
                $label = $localTime.ToString("MM-dd") + [Environment]::NewLine + $localTime.ToString("HH:mm")
            }
            else {
                $label = $localTime.ToString("MM-dd HH:mm") + [Environment]::NewLine + $item.width + " × " + $item.height
            }
            $labelRect = New-Object System.Drawing.RectangleF -ArgumentList $card.X, ($card.Y + $metrics.ImageHeight), $card.Width, 42
            $e.Graphics.DrawString($label, $form.Font, $script:DrawTitleBrush, $labelRect, $textFormat)
        }

        if (-not $script:ImageRubberRect.IsEmpty) {
            $rubber = New-Object System.Drawing.Rectangle -ArgumentList $script:ImageRubberRect.X, ($script:ImageRubberRect.Y - $scrollY), $script:ImageRubberRect.Width, $script:ImageRubberRect.Height
            $rubberBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(45, $ThemeBlue))
            $rubberPen = New-Object System.Drawing.Pen $ThemeBlue
            try {
                $e.Graphics.FillRectangle($rubberBrush, $rubber)
                $e.Graphics.DrawRectangle($rubberPen, $rubber)
            }
            finally {
                $rubberBrush.Dispose()
                $rubberPen.Dispose()
            }
        }
    }
    finally {
        $textFormat.Dispose()
    }
})

$list.Add_MeasureItem({
    param($sender, $e)
    if ($e.Index -ge 0 -and $e.Index -lt $script:DisplayItems.Count) {
        $e.ItemHeight = Get-ListItemHeight $script:DisplayItems[$e.Index]
    }
    else {
        $e.ItemHeight = 72
    }
})

$list.Add_DrawItem({
    param($sender, $e)
    Draw-HistoryListItem $e
})

$list.Add_MouseDown({
    param($sender, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) {
        return
    }

    $idx = $list.IndexFromPoint($e.Location)
    if ($idx -ge 0 -and $idx -lt $script:DisplayItems.Count) {
        $list.SelectedIndex = $idx
        Begin-DragCandidate $script:DisplayItems[$idx]
    }
})

$list.Add_MouseMove({
    param($sender, $e)
    if (($e.Button -band [System.Windows.Forms.MouseButtons]::Left) -ne 0 -and (Test-DragDistance)) {
        $item = $script:DragItem
        Clear-DragCandidate
        Start-HistoryDrag $item $list
    }
})

$list.Add_MouseUp({ Clear-DragCandidate })

function Get-ImageIndexAtPoint([System.Drawing.Point]$Point) {
    $metrics = Get-ImageGridMetrics
    $contentPoint = New-Object System.Drawing.Point -ArgumentList $Point.X, ($Point.Y - $imageGrid.AutoScrollPosition.Y)
    for ($i = 0; $i -lt $script:DisplayItems.Count; $i++) {
        if ((Get-ImageCellRectangle $i $metrics).Contains($contentPoint)) {
            return $i
        }
    }
    return -1
}

$imageGrid.Add_MouseDown({
    param($sender, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) {
        return
    }

    $imageGrid.Focus()
    $idx = Get-ImageIndexAtPoint $e.Location
    $modifiers = [System.Windows.Forms.Control]::ModifierKeys
    if ($idx -ge 0) {
        if (($modifiers -band [System.Windows.Forms.Keys]::Shift) -ne 0 -and $script:ImageSelectionAnchor -ge 0) {
            $start = [Math]::Min($script:ImageSelectionAnchor, $idx)
            $end = [Math]::Max($script:ImageSelectionAnchor, $idx)
            if (($modifiers -band [System.Windows.Forms.Keys]::Control) -eq 0) {
                $script:ImageSelectedIndices.Clear()
            }
            for ($i = $start; $i -le $end; $i++) { [void]$script:ImageSelectedIndices.Add($i) }
        }
        elseif (($modifiers -band [System.Windows.Forms.Keys]::Control) -ne 0) {
            if ($script:ImageSelectedIndices.Contains($idx)) {
                [void]$script:ImageSelectedIndices.Remove($idx)
            }
            else {
                [void]$script:ImageSelectedIndices.Add($idx)
            }
            $script:ImageSelectionAnchor = $idx
        }
        else {
            if (-not $script:ImageSelectedIndices.Contains($idx)) {
                $script:ImageSelectedIndices.Clear()
                [void]$script:ImageSelectedIndices.Add($idx)
            }
            $script:ImageSelectionAnchor = $idx
        }
        Begin-DragCandidate @(Get-SelectedHistoryItems)
        $script:IsImageRubberSelecting = $false
    }
    else {
        $script:IsImageRubberSelecting = $true
        $script:ImageRubberStart = New-Object System.Drawing.Point -ArgumentList $e.X, ($e.Y - $imageGrid.AutoScrollPosition.Y)
        $script:ImageRubberRect = New-Object System.Drawing.Rectangle -ArgumentList $script:ImageRubberStart.X, $script:ImageRubberStart.Y, 0, 0
        $script:ImageRubberBaseSelection = if (($modifiers -band [System.Windows.Forms.Keys]::Control) -ne 0) { @($script:ImageSelectedIndices) } else { @() }
        if (($modifiers -band [System.Windows.Forms.Keys]::Control) -eq 0) {
            $script:ImageSelectedIndices.Clear()
        }
    }
    $imageGrid.Invalidate()
    Show-Selected
})

$imageGrid.Add_MouseMove({
    param($sender, $e)
    if (($e.Button -band [System.Windows.Forms.MouseButtons]::Left) -eq 0) { return }

    if ($script:IsImageRubberSelecting) {
        $current = New-Object System.Drawing.Point -ArgumentList $e.X, ($e.Y - $imageGrid.AutoScrollPosition.Y)
        $left = [Math]::Min($script:ImageRubberStart.X, $current.X)
        $top = [Math]::Min($script:ImageRubberStart.Y, $current.Y)
        $width = [Math]::Abs($current.X - $script:ImageRubberStart.X)
        $height = [Math]::Abs($current.Y - $script:ImageRubberStart.Y)
        $script:ImageRubberRect = New-Object System.Drawing.Rectangle -ArgumentList $left, $top, $width, $height
        $script:ImageSelectedIndices.Clear()
        foreach ($baseIndex in $script:ImageRubberBaseSelection) { [void]$script:ImageSelectedIndices.Add([int]$baseIndex) }
        $metrics = Get-ImageGridMetrics
        for ($i = 0; $i -lt $script:DisplayItems.Count; $i++) {
            if ($script:ImageRubberRect.IntersectsWith((Get-ImageCellRectangle $i $metrics))) {
                [void]$script:ImageSelectedIndices.Add($i)
            }
        }
        $imageGrid.Invalidate()
        Show-Selected
    }
    elseif (Test-DragDistance) {
        $items = @($script:DragItem)
        Clear-DragCandidate
        Start-HistoryDragItems $items $imageGrid
    }
})

$imageGrid.Add_MouseUp({
    $script:IsImageRubberSelecting = $false
    $script:ImageRubberRect = [System.Drawing.Rectangle]::Empty
    Clear-DragCandidate
    $imageGrid.Invalidate()
})

$previewText.Add_MouseDown({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Begin-DragCandidate (Get-SelectedHistoryItem)
    }
})

$previewText.Add_MouseMove({
    param($sender, $e)
    if (($e.Button -band [System.Windows.Forms.MouseButtons]::Left) -ne 0 -and (Test-DragDistance)) {
        $item = $script:DragItem
        Clear-DragCandidate
        Start-HistoryDrag $item $previewText
    }
})

$previewText.Add_MouseUp({ Clear-DragCandidate })

$picture.Add_MouseDown({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Begin-DragCandidate (Get-SelectedHistoryItem)
    }
})

$picture.Add_MouseMove({
    param($sender, $e)
    if (($e.Button -band [System.Windows.Forms.MouseButtons]::Left) -ne 0 -and (Test-DragDistance)) {
        $item = $script:DragItem
        Clear-DragCandidate
        Start-HistoryDrag $item $picture
    }
})

$picture.Add_MouseUp({ Clear-DragCandidate })

$previewHost.Add_MouseDown({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Begin-DragCandidate (Get-SelectedHistoryItem)
    }
})

$previewHost.Add_MouseMove({
    param($sender, $e)
    if (($e.Button -band [System.Windows.Forms.MouseButtons]::Left) -ne 0 -and (Test-DragDistance)) {
        $item = $script:DragItem
        Clear-DragCandidate
        Start-HistoryDrag $item $previewHost
    }
})

$previewHost.Add_MouseUp({ Clear-DragCandidate })

$leftPanel.Add_MouseEnter({ $leftPanel.Focus() })
$list.Add_MouseEnter({ $list.Focus() })
$imageGrid.Add_MouseEnter({ $imageGrid.Focus() })
$searchBox.Add_MouseEnter({ $searchBox.Focus() })
$previewHost.Add_MouseEnter({ $previewHost.Focus() })
$picture.Add_MouseEnter({ $previewHost.Focus() })

$leftPanel.Add_MouseWheel({
    param($sender, $e)
    if (([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Control) -ne 0) {
        Adjust-LeftLayout $e.Delta
    }
})

$list.Add_MouseWheel({
    param($sender, $e)
    if (([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Control) -ne 0) {
        Adjust-LeftLayout $e.Delta
    }
})

$imageGrid.Add_MouseWheel({
    param($sender, $e)
    $script:LastImageGridScrollAt = [DateTime]::UtcNow
    if (([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Control) -ne 0) {
        Adjust-LeftLayout $e.Delta
    }
})

$imageGrid.Add_Scroll({
    $script:LastImageGridScrollAt = [DateTime]::UtcNow
})

$imageGrid.Add_Resize({
    if ($imageGrid.Visible) {
        Update-ImageGridLayout $true
    }
})

$gridThumbnailTimer = New-Object System.Windows.Forms.Timer
$gridThumbnailTimer.Interval = 40
$gridThumbnailTimer.Add_Tick({
    if (-not $imageGrid.Visible -or $script:GridThumbnailQueue.Count -eq 0) {
        return
    }

    # Disk image decoding on the UI thread competes directly with scrolling.
    # Wait until the wheel/scrollbar has been idle briefly before decoding.
    if (([DateTime]::UtcNow - $script:LastImageGridScrollAt).TotalMilliseconds -lt 140) {
        return
    }

    $idx = $script:GridThumbnailQueue.Dequeue()
    [void]$script:GridThumbnailPending.Remove($idx)
    if ($idx -ge 0 -and $idx -lt $script:DisplayItems.Count) {
        [void](Get-GridThumbnail $script:DisplayItems[$idx])
        $metrics = Get-ImageGridMetrics
        $contentRect = Get-ImageCellRectangle $idx $metrics
        $visibleRect = New-Object System.Drawing.Rectangle -ArgumentList $contentRect.X, ($contentRect.Y + $imageGrid.AutoScrollPosition.Y), $contentRect.Width, $contentRect.Height
        if ($imageGrid.ClientRectangle.IntersectsWith($visibleRect)) {
            $imageGrid.Invalidate($visibleRect)
        }
    }
})
$gridThumbnailTimer.Start()

$searchBox.Add_MouseWheel({
    param($sender, $e)
    if (([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Control) -ne 0) {
        Adjust-LeftLayout $e.Delta
    }
})

$previewHost.Add_MouseWheel({
    param($sender, $e)
    if (([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Control) -ne 0) {
        Adjust-PreviewZoom $e.Delta
    }
})

$picture.Add_MouseWheel({
    param($sender, $e)
    if (([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Control) -ne 0) {
        Adjust-PreviewZoom $e.Delta
    }
})

$previewHost.Add_Resize({ Update-PreviewZoom })

foreach ($button in @($copyButton, $refreshButton, $collapseButton, $hideButton, $allModeButton, $imageModeButton, $textModeButton)) {
    $button.Add_Resize({
        param($sender, $e)
        $sender.Invalidate()
    })
}

$copyButton.Add_Click({
    $items = @(Get-SelectedHistoryItems)
    if ($items.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("请先在左侧选一条历史记录。", "历史粘贴板") | Out-Null
        return
    }
    try {
        $copiedCount = Set-ClipboardFromItems $items
    }
    catch {
        Write-ErrorLog "恢复历史内容到剪贴板失败。" $_
        $statusLabel.Text = "复制失败：剪贴板正被其他程序占用，请再试一次"
        return
    }
    if ($copiedCount -gt 1) {
        $statusLabel.Text = "已复制 " + $copiedCount + " 张图片，可切换到目标位置直接粘贴"
    }
    elseif ($copiedCount -eq 1) {
        $statusLabel.Text = "已复制回剪贴板"
    }
    else {
        $statusLabel.Text = "复制失败：图片文件不存在或剪贴板暂时不可用"
    }
})

$refreshButton.Add_Click({ Refresh-List; Show-Selected })

$searchBox.Add_TextChanged({ Apply-Filter })

$allModeButton.Add_Click({
    $script:ViewMode = "all"
    $script:Settings.viewMode = $script:ViewMode
    Update-ModeButtons
    Write-Settings
    Apply-Filter
})

$imageModeButton.Add_Click({
    $script:ViewMode = "image"
    $script:Settings.viewMode = $script:ViewMode
    Update-ModeButtons
    Write-Settings
    Apply-Filter
})

$textModeButton.Add_Click({
    $script:ViewMode = "text"
    $script:Settings.viewMode = $script:ViewMode
    Update-ModeButtons
    Write-Settings
    Apply-Filter
})

$collapseButton.Add_Click({ Show-Bubble })

$hideButton.Add_Click({ Hide-ToTray })

$openMenuItem.Add_Click({ Show-HistoryPanel })

$bubbleMenuItem.Add_Click({ Show-Bubble })

$exitMenuItem.Add_Click({ Exit-App })

$notifyIcon.Add_DoubleClick({ Show-HistoryPanel })

$notifyIcon.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Show-Bubble
    }
})

$splitter.Add_SplitterMoved({
    if (
        -not $script:IsCollapsed -and
        -not $script:IsNormalizingSplitLayout -and
        $form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal
    ) {
        Normalize-SplitLayout $false
        $script:Settings.leftPanelWidth = $leftPanel.Width
        Write-Settings
    }
})

$form.Add_ResizeEnd({
    if (-not $script:IsCollapsed) {
        Save-ExpandedBounds
        if ($imageGrid.Visible) {
            Update-ImageGridLayout $true
        }
        Write-Settings
    }
})

$form.Add_Resize({
    if (-not $script:IsCollapsed -and $form.WindowState -ne [System.Windows.Forms.FormWindowState]::Minimized) {
        $script:LastNonMinimizedWindowState = $form.WindowState
        [void]$form.BeginInvoke([System.Action]{
            Normalize-SplitLayout ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal)
        })
    }
})

$form.Add_KeyDown({
    param($sender, $e)

    if (
        $e.Control -and
        -not $script:IsCollapsed -and
        $script:ViewMode -eq "image" -and
        $e.KeyCode -in @(
            [System.Windows.Forms.Keys]::Oemplus,
            [System.Windows.Forms.Keys]::Add,
            [System.Windows.Forms.Keys]::OemMinus,
            [System.Windows.Forms.Keys]::Subtract
        )
    ) {
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Oemplus -or $e.KeyCode -eq [System.Windows.Forms.Keys]::Add) {
            Adjust-ImageGridColumns 1
        }
        else {
            Adjust-ImageGridColumns -1
        }
        $imageGrid.Focus()
        $e.SuppressKeyPress = $true
        $e.Handled = $true
        return
    }

    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape -and -not $script:IsCollapsed) {
        $e.SuppressKeyPress = $true
        $e.Handled = $true
        Show-Bubble
    }
})

$form.Add_Move({
    if (-not $script:IsCollapsed) {
        Save-ExpandedBounds
    }
})

$bubblePicture.Add_MouseDown({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:BubbleMouseDown = $true
        $script:IsDraggingBubble = $false
        $script:BubbleMouseDownPoint = [System.Windows.Forms.Control]::MousePosition
        $script:BubbleStartLocation = $form.Location
    }
})

$bubblePicture.Add_MouseMove({
    param($sender, $e)
    if (-not $script:BubbleMouseDown) {
        return
    }

    $current = [System.Windows.Forms.Control]::MousePosition
    $dx = $current.X - $script:BubbleMouseDownPoint.X
    $dy = $current.Y - $script:BubbleMouseDownPoint.Y

    if ([Math]::Abs($dx) -gt 3 -or [Math]::Abs($dy) -gt 3) {
        $script:IsDraggingBubble = $true
        $newX = [int]($script:BubbleStartLocation.X + $dx)
        $newY = [int]($script:BubbleStartLocation.Y + $dy)
        $form.Location = New-Object System.Drawing.Point -ArgumentList $newX, $newY
    }
})

$bubblePicture.Add_MouseUp({
    param($sender, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) {
        return
    }

    $wasDragging = $script:IsDraggingBubble
    $script:BubbleMouseDown = $false
    $script:IsDraggingBubble = $false

    if ($wasDragging) {
        Snap-BubbleToScreenEdge
    }
    else {
        Show-HistoryPanel
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 900
$timer.Add_Tick({
    try {
        if (((Get-Date) - $script:LastPurge).TotalMinutes -ge 10) {
            $script:LastPurge = Get-Date
            $script:HistoryItems = @(Remove-Old-History)
            $script:UiDirty = $true
            if (-not $script:IsCollapsed -and $form.Visible) {
                Apply-Filter
                $script:UiDirty = $false
            }
        }

        $snapshot = Get-ClipboardSnapshot
        if ($null -eq $snapshot) {
            return
        }
        if ($snapshot.Hash -eq $script:LastHash) {
            return
        }
        $script:LastHash = $snapshot.Hash
        if (Add-HistoryItem $snapshot) {
            $script:HistoryItems = @(Read-History)
            $script:UiDirty = $true
            if (-not $script:IsCollapsed -and $form.Visible) {
                Apply-Filter
                $script:UiDirty = $false
                if ($list.Visible -and $list.Items.Count -gt 0) {
                    $list.SelectedIndex = 0
                }
            }
            $statusLabel.Text = "刚刚保存了一条复制内容"
        }
    }
    catch {
        Write-ErrorLog "监听剪贴板时出现异常。" $_
        $statusLabel.Text = "监听中遇到临时占用，稍后会继续"
    }
})

$form.Add_Shown({
    $script:UiDirty = $true
    if ($script:Settings.isHidden) {
        Hide-ToTray
    }
    elseif ($script:Settings.isCollapsed) {
        Show-Bubble
    }
    else {
        Show-HistoryPanel
    }
    $timer.Start()
})

$form.Add_FormClosing({
    param($sender, $e)

    if (-not $script:AllowExit) {
        $e.Cancel = $true
        if (-not $script:IsCollapsed) {
            [void]$form.BeginInvoke([System.Action]{
                Show-Bubble
            })
        }
        return
    }

    $timer.Stop()
    $gridThumbnailTimer.Stop()
    if ($ctrlShortcutTimer) {
        $ctrlShortcutTimer.Stop()
    }
    if ($script:IsCollapsed) {
        Save-BubbleBounds
    }
    else {
        Save-ExpandedBounds
    }
    $script:Settings.isCollapsed = $script:IsCollapsed
    Write-Settings

    if ($picture.Image) {
        $picture.Image.Dispose()
    }
    Clear-ThumbnailCache
    Clear-GridThumbnailCache
    $gridThumbnailTimer.Dispose()
    if ($form.Region) {
        $form.Region.Dispose()
    }
    if ($bubblePicture.Image) {
        $bubblePicture.Image.Dispose()
    }
    foreach ($resource in @(
        $script:DrawCardBrush,
        $script:DrawSelectedCardBrush,
        $script:DrawBorderPen,
        $script:DrawSelectedBorderPen,
        $script:DrawTitleBrush,
        $script:DrawBodyBrush,
        $script:DrawAccentBrush,
        $script:DrawMissingBrush,
        $script:DrawTextFormat
    )) {
        if ($resource) {
            $resource.Dispose()
        }
    }
    if ($script:CtrlDoubleTapHook) {
        $script:CtrlDoubleTapHook.Dispose()
        $script:CtrlDoubleTapHook = $null
    }
    if ($ctrlShortcutTimer) {
        $ctrlShortcutTimer.Dispose()
    }
    $notifyIcon.Dispose()
    $trayMenu.Dispose()
})

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
