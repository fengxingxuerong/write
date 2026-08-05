; 墨匠 InkSmith - 安装脚本 (Inno Setup 7)
; 编译: ISCC.exe installer.iss

#define MyAppName "墨匠 InkSmith"
#define MyAppVersion "0.1.0"
#define MyAppPublisher "InkSmith"
#define MyAppExeName "novel_writer.exe"

[Setup]
AppId={{8A2C5F6E-9B4D-4C7A-8E1F-2D6B3A9C5D41}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\InkSmith\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=InkSmith-Setup-{#MyAppVersion}
SetupIconFile=windows\runner\resources\app_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\{#MyAppExeName}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
ShowLanguageDialog=no
CloseApplications=yes

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务:"
Name: "quicklaunchicon"; Description: "创建快速启动栏图标"; GroupDescription: "附加任务:"; Flags: unchecked

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "立即运行 {#MyAppName}"; Flags: nowait postinstall skipifsilent

[Code]
var
  DeleteData: Boolean;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
begin
  if CurUninstallStep = usUninstall then
  begin
    DataDir := ExpandConstant('{userappdata}\InkSmith\墨匠');
    if DirExists(DataDir) then
    begin
      // 静默卸载（/VERYSILENT）不弹窗，直接保留数据；交互卸载弹窗确认。
      if UninstallSilent then
      begin
        DeleteData := False;
      end
      else if MsgBox('是否同时删除本地数据（小说、设定、AI 配置）？' + #13#10 +
        '删除后不可恢复，建议先导出备份。' + #13#10 + #13#10 +
        '选择"是"删除数据，"否"保留数据。', mbConfirmation, MB_YESNO) = IDYES then
      begin
        DeleteData := True;
      end;
    end;
  end
  else if (CurUninstallStep = usPostUninstall) and DeleteData then
  begin
    DelTree(ExpandConstant('{userappdata}\InkSmith\墨匠'), True, True, True);
    // 若空目录则连品牌目录一并清理
    DelTree(ExpandConstant('{userappdata}\InkSmith'), True, False, True);
  end;
end;
