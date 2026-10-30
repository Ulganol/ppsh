[Setup]
AppName=P2P Chat
AppVersion=1.0.0
DefaultDirName={autopf}\P2PChat
DefaultGroupName=P2P Chat
OutputBaseFilename=P2PChat-Setup
OutputDir=Output
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
UninstallDisplayIcon={app}\p2pchat.exe

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "Создать ярлык на рабочем столе"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\P2P Chat"; Filename: "{app}\p2pchat.exe"
Name: "{autodesktop}\P2P Chat"; Filename: "{app}\p2pchat.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\p2pchat.exe"; Description: "Запустить P2P Chat"; Flags: nowait postinstall skipifsilent
