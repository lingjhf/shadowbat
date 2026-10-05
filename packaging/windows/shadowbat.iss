[Setup]
AppId={{6BC70A29-41F6-4B29-AF78-078903C53E0D}
AppName=Shadowbat
AppVersion={#AppVersion}
AppPublisher=lingjhf
AppPublisherURL=https://github.com/lingjhf/shadowbat
DefaultDirName={localappdata}\Programs\Shadowbat
DefaultGroupName=Shadowbat
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDirectory}
OutputBaseFilename={#OutputName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\shadowbat.exe
CloseApplications=yes
RestartApplications=no

[Files]
Source: "{#BundleDirectory}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Shadowbat"; Filename: "{app}\shadowbat.exe"

[Run]
Filename: "{app}\shadowbat.exe"; Description: "Launch Shadowbat"; Flags: nowait postinstall skipifsilent unchecked
