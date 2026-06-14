Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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
$ThemeBack = [System.Drawing.Color]::FromArgb(10, 14, 22)
$ThemePanel = [System.Drawing.Color]::FromArgb(15, 22, 34)
$ThemeCard = [System.Drawing.Color]::FromArgb(20, 30, 46)
$ThemeCardSelected = [System.Drawing.Color]::FromArgb(24, 70, 124)
$ThemeBorder = [System.Drawing.Color]::FromArgb(43, 60, 82)
$ThemeBlue = [System.Drawing.Color]::FromArgb(63, 150, 255)
$ThemeText = [System.Drawing.Color]::FromArgb(236, 244, 255)
$ThemeMuted = [System.Drawing.Color]::FromArgb(145, 164, 190)

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

function Set-ClipboardFromItem($Item) {
    switch ($Item.kind) {
        "image" {
            $full = Join-Path $AppRoot ([string]$Item.imagePath)
            if (Test-Path -LiteralPath $full) {
                $img = [System.Drawing.Image]::FromFile($full)
                try {
                    $bmp = New-Object System.Drawing.Bitmap $img
                    [System.Windows.Forms.Clipboard]::SetImage($bmp)
                }
                finally {
                    $img.Dispose()
                    if ($bmp) {
                        $bmp.Dispose()
                    }
                }
            }
        }
        "files" {
            $collection = New-Object System.Collections.Specialized.StringCollection
            foreach ($path in $Item.paths) {
                [void]$collection.Add([string]$path)
            }
            [System.Windows.Forms.Clipboard]::SetFileDropList($collection)
        }
        default {
            [System.Windows.Forms.Clipboard]::SetText([string]$Item.text)
        }
    }
}

function Clear-ThumbnailCache {
    foreach ($thumb in $script:ThumbnailCache.Values) {
        if ($thumb) {
            $thumb.Dispose()
        }
    }
    $script:ThumbnailCache.Clear()
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
$script:ThumbnailCache = @{}
$script:DisplayItems = @()
$script:ListScale = [double]$script:Settings.listScale
$script:PreviewZoom = [double]$script:Settings.previewZoom
$script:ViewMode = [string]$script:Settings.viewMode
if (@("all", "image", "text") -notcontains $script:ViewMode) {
    $script:ViewMode = "all"
    $script:Settings.viewMode = $script:ViewMode
}
$script:DragStartPoint = [System.Drawing.Point]::Empty
$script:DragItem = $null

$form = New-Object System.Windows.Forms.Form
$form.Text = "历史粘贴板 - 自动保存 3 天"
$form.Width = [int]$script:Settings.expandedWidth
$form.Height = [int]$script:Settings.expandedHeight
$form.StartPosition = "Manual"
$form.Location = New-Object System.Drawing.Point -ArgumentList ([int]$script:Settings.expandedX), ([int]$script:Settings.expandedY)
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.BackColor = $ThemeBack

$leftPanel = New-Object System.Windows.Forms.Panel
$leftPanel.Dock = "Left"
$leftPanel.Width = [int]$script:Settings.leftPanelWidth
$leftPanel.Padding = New-Object System.Windows.Forms.Padding(12)
$leftPanel.BackColor = $ThemeBack
$leftPanel.TabStop = $true

$splitter = New-Object System.Windows.Forms.Splitter
$splitter.Dock = "Left"
$splitter.Width = 8
$splitter.MinSize = 260
$splitter.MinExtra = 320
$splitter.BackColor = $ThemeBorder
$splitter.Cursor = [System.Windows.Forms.Cursors]::VSplit

$searchBox = New-Object System.Windows.Forms.TextBox
$searchBox.Dock = "Top"
$searchBox.Height = 32
$searchBox.BorderStyle = "FixedSingle"
$searchBox.BackColor = [System.Drawing.Color]::FromArgb(22, 32, 48)
$searchBox.ForeColor = $ThemeText
$searchBox.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)

$viewBar = New-Object System.Windows.Forms.FlowLayoutPanel
$viewBar.Dock = "Top"
$viewBar.Height = 40
$viewBar.FlowDirection = "LeftToRight"
$viewBar.BackColor = $ThemeBack
$viewBar.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)

$allModeButton = New-Object System.Windows.Forms.Button
$allModeButton.Text = "全部"
$allModeButton.Width = 70
$allModeButton.Height = 26

$imageModeButton = New-Object System.Windows.Forms.Button
$imageModeButton.Text = "图片"
$imageModeButton.Width = 70
$imageModeButton.Height = 26

$textModeButton = New-Object System.Windows.Forms.Button
$textModeButton.Text = "文字"
$textModeButton.Width = 70
$textModeButton.Height = 26

$list = New-Object System.Windows.Forms.ListBox
$list.Dock = "Fill"
$list.Width = 520
$list.HorizontalScrollbar = $false
$list.IntegralHeight = $false
$list.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawVariable
$list.BorderStyle = "None"
$list.BackColor = $ThemeBack
$list.ForeColor = $ThemeText

$imageGrid = New-Object System.Windows.Forms.ListView
$imageGrid.Dock = "Fill"
$imageGrid.View = [System.Windows.Forms.View]::LargeIcon
$imageGrid.BorderStyle = "None"
$imageGrid.BackColor = $ThemeBack
$imageGrid.ForeColor = $ThemeText
$imageGrid.HideSelection = $false
$imageGrid.MultiSelect = $false
$imageGrid.Visible = $false
$imageGrid.TabStop = $true

$imageGridImages = New-Object System.Windows.Forms.ImageList
$imageGridImages.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit
$imageGridImages.ImageSize = New-Object System.Drawing.Size -ArgumentList 128, 128
$imageGrid.LargeImageList = $imageGridImages

$panel = New-Object System.Windows.Forms.Panel
$panel.Dock = "Fill"
$panel.Padding = New-Object System.Windows.Forms.Padding(12)
$panel.BackColor = $ThemeBack

$buttons = New-Object System.Windows.Forms.FlowLayoutPanel
$buttons.Dock = "Top"
$buttons.Height = 46
$buttons.FlowDirection = "LeftToRight"
$buttons.BackColor = $ThemeBack

$copyButton = New-Object System.Windows.Forms.Button
$copyButton.Text = "复制回剪贴板"
$copyButton.Width = 130
$copyButton.Height = 30

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = "刷新"
$refreshButton.Width = 80
$refreshButton.Height = 30

$collapseButton = New-Object System.Windows.Forms.Button
$collapseButton.Text = "收起"
$collapseButton.Width = 80
$collapseButton.Height = 30

$hideButton = New-Object System.Windows.Forms.Button
$hideButton.Text = "隐藏"
$hideButton.Width = 80
$hideButton.Height = 30

function Set-ToolButtonStyle($Button, [bool]$Primary) {
    $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $Button.FlatAppearance.BorderSize = 1
    $Button.FlatAppearance.BorderColor = if ($Primary) { $ThemeBlue } else { $ThemeBorder }
    $Button.BackColor = if ($Primary) { [System.Drawing.Color]::FromArgb(18, 65, 118) } else { $ThemePanel }
    $Button.ForeColor = $ThemeText
    $Button.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
    $Button.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 8)
}

Set-ToolButtonStyle $copyButton $true
Set-ToolButtonStyle $refreshButton $false
Set-ToolButtonStyle $collapseButton $false
Set-ToolButtonStyle $hideButton $false
Set-ToolButtonStyle $allModeButton ($script:ViewMode -eq "all")
Set-ToolButtonStyle $imageModeButton ($script:ViewMode -eq "image")
Set-ToolButtonStyle $textModeButton ($script:ViewMode -eq "text")

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "正在监听复制内容..."
$statusLabel.AutoSize = $true
$statusLabel.Padding = New-Object System.Windows.Forms.Padding(8, 7, 0, 0)
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
$picture.BackColor = [System.Drawing.Color]::Black

$previewHost = New-Object System.Windows.Forms.Panel
$previewHost.Dock = "Fill"
$previewHost.BackColor = [System.Drawing.Color]::Black
$previewHost.AutoScroll = $true
$previewHost.Visible = $false
$previewHost.TabStop = $true

$buttons.Controls.Add($copyButton)
$buttons.Controls.Add($refreshButton)
$buttons.Controls.Add($collapseButton)
$buttons.Controls.Add($hideButton)
$buttons.Controls.Add($statusLabel)
$viewBar.Controls.Add($allModeButton)
$viewBar.Controls.Add($imageModeButton)
$viewBar.Controls.Add($textModeButton)
$previewHost.Controls.Add($picture)
$panel.Controls.Add($previewText)
$panel.Controls.Add($previewHost)
$panel.Controls.Add($buttons)
$leftPanel.Controls.Add($list)
$leftPanel.Controls.Add($imageGrid)
$leftPanel.Controls.Add($viewBar)
$leftPanel.Controls.Add($searchBox)
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

function Get-GridThumbnail($Item, [int]$Size) {
    $full = Join-Path $AppRoot ([string]$Item.imagePath)
    if (-not (Test-Path -LiteralPath $full)) {
        return $null
    }

    try {
        $source = [System.Drawing.Image]::FromFile($full)
        try {
            $thumb = New-Object System.Drawing.Bitmap -ArgumentList $Size, $Size
            $g = [System.Drawing.Graphics]::FromImage($thumb)
            try {
                $g.Clear([System.Drawing.Color]::FromArgb(24, 24, 24))
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $scale = [Math]::Min(($Size - 10) / $source.Width, ($Size - 10) / $source.Height)
                $drawWidth = [int]($source.Width * $scale)
                $drawHeight = [int]($source.Height * $scale)
                $drawX = [int](($Size - $drawWidth) / 2)
                $drawY = [int](($Size - $drawHeight) / 2)
                $g.DrawImage($source, $drawX, $drawY, $drawWidth, $drawHeight)
            }
            finally {
                $g.Dispose()
            }
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

function Populate-ImageGrid([string]$SelectedId) {
    $oldImageList = $imageGrid.LargeImageList
    $newImageList = New-Object System.Windows.Forms.ImageList
    $newImageList.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit
    $size = [int](Clamp-Value ([int](118 * $script:ListScale)) 72 210)
    $newImageList.ImageSize = New-Object System.Drawing.Size -ArgumentList $size, $size

    $imageGrid.BeginUpdate()
    try {
        $imageGrid.Items.Clear()
        for ($i = 0; $i -lt $script:DisplayItems.Count; $i++) {
            $item = $script:DisplayItems[$i]
            $thumb = Get-GridThumbnail $item $size
            if ($null -eq $thumb) {
                $thumb = New-Object System.Drawing.Bitmap -ArgumentList $size, $size
            }
            [void]$newImageList.Images.Add($thumb)
            $thumb.Dispose()

            $time = ([DateTime]::Parse($item.createdAt)).ToLocalTime().ToString("MM-dd HH:mm")
            $text = $time + [Environment]::NewLine + $item.width + " x " + $item.height
            $gridItem = New-Object System.Windows.Forms.ListViewItem -ArgumentList $text, $i
            $gridItem.Tag = $i
            [void]$imageGrid.Items.Add($gridItem)
        }

        $imageGrid.LargeImageList = $newImageList
        if ($oldImageList) {
            $oldImageList.Dispose()
        }

        if ($SelectedId) {
            foreach ($gridItem in $imageGrid.Items) {
                $idx = [int]$gridItem.Tag
                if ([string]$script:DisplayItems[$idx].id -eq $SelectedId) {
                    $gridItem.Selected = $true
                    $gridItem.Focused = $true
                    $gridItem.EnsureVisible()
                    break
                }
            }
        }

        if ($imageGrid.SelectedItems.Count -eq 0 -and $imageGrid.Items.Count -gt 0) {
            $imageGrid.Items[0].Selected = $true
            $imageGrid.Items[0].Focused = $true
        }
    }
    finally {
        $imageGrid.EndUpdate()
    }
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
    if ($script:ViewMode -eq "image" -and $imageGrid.Visible) {
        if ($imageGrid.SelectedItems.Count -gt 0) {
            return [int]$imageGrid.SelectedItems[0].Tag
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

function Apply-Filter {
    $query = $searchBox.Text.Trim()
    $selected = Get-SelectedHistoryItem
    $selectedId = if ($selected) { [string]$selected.id } else { $null }
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($item in $script:HistoryItems) {
        if ((Test-HistoryItemModeMatch $item) -and (Test-HistoryItemMatch $item $query)) {
            $items.Add($item)
        }
    }

    $script:DisplayItems = @($items.ToArray())
    $imageGrid.Visible = ($script:ViewMode -eq "image")
    $list.Visible = -not $imageGrid.Visible

    if ($imageGrid.Visible) {
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
    else {
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
    Clear-ThumbnailCache
    Apply-Filter
}

function Refresh-ListLayout {
    $selected = Get-SelectedHistoryItem
    $selectedId = if ($selected) { [string]$selected.id } else { $null }

    Clear-ThumbnailCache
    if ($script:ViewMode -eq "image" -and $imageGrid.Visible) {
        Populate-ImageGrid $selectedId
    }
    else {
        Populate-List $selectedId
    }
}

function Adjust-LeftLayout([int]$WheelDelta) {
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

    $backColor = if ($selected) { $ThemeCardSelected } else { $ThemeCard }
    $borderColor = if ($selected) { $ThemeBlue } else { $ThemeBorder }
    $titleColor = $ThemeText
    $bodyColor = $ThemeMuted

    $backBrush = New-Object System.Drawing.SolidBrush $backColor
    $borderPen = New-Object System.Drawing.Pen $borderColor
    $titleBrush = New-Object System.Drawing.SolidBrush $titleColor
    $bodyBrush = New-Object System.Drawing.SolidBrush $bodyColor
    $mutedBrush = New-Object System.Drawing.SolidBrush $ThemeBlue
    $format = New-Object System.Drawing.StringFormat
    $clipState = $null

    try {
        $format.Trimming = [System.Drawing.StringTrimming]::EllipsisWord
        $format.FormatFlags = [System.Drawing.StringFormatFlags]::LineLimit

        $card = New-Object System.Drawing.Rectangle -ArgumentList ($bounds.X + 4), ($bounds.Y + 4), ($bounds.Width - 8), ($bounds.Height - 8)
        $graphics.FillRectangle($backBrush, $card)
        $graphics.DrawRectangle($borderPen, $card)
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
            $thumb = Get-Thumbnail ([string]$item.imagePath)
            if ($thumb) {
                $graphics.DrawImage($thumb, $thumbRect)
            }
            else {
                $missingBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(40, 40, 40))
                try {
                    $graphics.FillRectangle($missingBrush, $thumbRect)
                }
                finally {
                    $missingBrush.Dispose()
                }
            }
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
        $format.Dispose()
        $mutedBrush.Dispose()
        $bodyBrush.Dispose()
        $titleBrush.Dispose()
        $borderPen.Dispose()
        $backBrush.Dispose()
    }
}

function Show-Selected {
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
    if (-not $script:IsCollapsed) {
        $script:Settings.expandedX = $form.Location.X
        $script:Settings.expandedY = $form.Location.Y
        $script:Settings.expandedWidth = $form.Width
        $script:Settings.expandedHeight = $form.Height
        $script:Settings.leftPanelWidth = $leftPanel.Width
    }
}

function Save-BubbleBounds {
    $script:Settings.bubbleX = $form.Location.X
    $script:Settings.bubbleY = $form.Location.Y
}

function Set-BubbleShape {
    if ($form.Region) {
        $form.Region.Dispose()
        $form.Region = $null
    }
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

    Set-BubbleShape
    Snap-BubbleToScreenEdge
    $form.Show()
    $bubblePicture.Invalidate()
    $form.Invalidate()
    $form.Activate()
}

function Show-HistoryPanel {
    Save-BubbleBounds
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

    $form.SuspendLayout()
    $form.MinimumSize = New-Object System.Drawing.Size -ArgumentList 640, 420
    $form.MaximumSize = New-Object System.Drawing.Size -ArgumentList 0, 0
    $form.FormBorderStyle = "SizableToolWindow"
    $form.ControlBox = $true
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.BackColor = $ThemeBack
    $form.TransparencyKey = [System.Drawing.Color]::Empty
    $form.Size = New-Object System.Drawing.Size -ArgumentList ([int]$width), ([int]$height)
    $form.Location = New-Object System.Drawing.Point -ArgumentList ([int]$x), ([int]$y)
    $bubblePicture.Visible = $false
    $leftPanel.Visible = $true
    $splitter.Visible = $true
    $imageGrid.Visible = ($script:ViewMode -eq "image")
    $list.Visible = -not $imageGrid.Visible
    $panel.Visible = $true
    $form.ResumeLayout($true)

    Refresh-List
    Show-Selected
    $form.Activate()
    Write-Settings
    $form.Show()
    $form.Activate()
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

$list.Add_SelectedIndexChanged({ Show-Selected })

$imageGrid.Add_SelectedIndexChanged({ Show-Selected })

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

$imageGrid.Add_MouseDown({
    param($sender, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) {
        return
    }

    $gridItem = $imageGrid.GetItemAt($e.X, $e.Y)
    if ($null -ne $gridItem) {
        $gridItem.Selected = $true
        $gridItem.Focused = $true
        $idx = [int]$gridItem.Tag
        if ($idx -ge 0 -and $idx -lt $script:DisplayItems.Count) {
            Begin-DragCandidate $script:DisplayItems[$idx]
        }
    }
})

$imageGrid.Add_MouseMove({
    param($sender, $e)
    if (($e.Button -band [System.Windows.Forms.MouseButtons]::Left) -ne 0 -and (Test-DragDistance)) {
        $item = $script:DragItem
        Clear-DragCandidate
        Start-HistoryDrag $item $imageGrid
    }
})

$imageGrid.Add_MouseUp({ Clear-DragCandidate })

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
    if (([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Control) -ne 0) {
        Adjust-LeftLayout $e.Delta
    }
})

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

$copyButton.Add_Click({
    $item = Get-SelectedHistoryItem
    if ($null -eq $item) {
        [System.Windows.Forms.MessageBox]::Show("请先在左侧选一条历史记录。", "历史粘贴板") | Out-Null
        return
    }
    Set-ClipboardFromItem $item
    $statusLabel.Text = "已复制回剪贴板"
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
    if (-not $script:IsCollapsed) {
        $script:Settings.leftPanelWidth = $leftPanel.Width
        Write-Settings
    }
})

$form.Add_ResizeEnd({
    if (-not $script:IsCollapsed) {
        Save-ExpandedBounds
        Write-Settings
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
            Refresh-List
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
            Refresh-List
            if ($list.Visible -and $list.Items.Count -gt 0) {
                $list.SelectedIndex = 0
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
    Refresh-List
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
        Hide-ToTray
        return
    }

    $timer.Stop()
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
    if ($form.Region) {
        $form.Region.Dispose()
    }
    if ($bubblePicture.Image) {
        $bubblePicture.Image.Dispose()
    }
    $notifyIcon.Dispose()
    $trayMenu.Dispose()
})

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
