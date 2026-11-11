#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef PayloadDir
  #error PayloadDir must identify the clean, allow-listed build payload.
#endif
#ifndef OutputPath
  #error OutputPath is required.
#endif

[Setup]
AppId={{6C606680-5314-4CD8-B52B-E6698920F45D}
AppName=历史粘贴板
AppVersion={#AppVersion}
AppPublisher=ztr2006JIIR
AppPublisherURL=https://github.com/ztr2006JIIR/clipboard-history
AppSupportURL=https://github.com/ztr2006JIIR/clipboard-history/issues
AppUpdatesURL=https://github.com/ztr2006JIIR/clipboard-history/releases/latest
DefaultDirName={localappdata}\Programs\ClipboardHistory
DefaultGroupName=历史粘贴板
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
MinVersion=10.0
OutputDir={#OutputPath}
OutputBaseFilename=ClipboardHistory-Setup-{#AppVersion}
SetupIconFile={#PayloadDir}\app-icon.ico
UninstallDisplayIcon={app}\ClipboardHistory.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
AppMutex=Local\ClipboardHistory.Launcher.6C606680-5314-4CD8-B52B-E6698920F45D
CloseApplications=no
RestartApplications=no
Uninstallable=yes

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "快捷方式："

; Explicit file list only. Never include data, the working tree, or wildcard subdirectories.
[Files]
Source: "{#PayloadDir}\ClipboardHistory.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\clipboard-history.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\app-icon.png"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\app-bubble.png"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\Debug-ClipboardHistory.bat"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\历史粘贴板"; Filename: "{app}\ClipboardHistory.exe"; WorkingDir: "{app}"
Name: "{group}\卸载历史粘贴板"; Filename: "{uninstallexe}"
Name: "{autodesktop}\历史粘贴板"; Filename: "{app}\ClipboardHistory.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\ClipboardHistory.exe"; Description: "启动历史粘贴板"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent

; Deliberately no [UninstallDelete]: user-generated data/history remains untouched.
