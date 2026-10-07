param([string]$Configuration='Release')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Split-Path -Parent $PSScriptRoot
$reportFile=Join-Path $root 'build\windows-tray-test.json'
$inner=Join-Path $root 'build\windows-tray-test-interactive.ps1'
$exe=Join-Path $root "build\windows\x64\runner\$Configuration\shadowbat.exe"
if (Test-Path $reportFile) { Remove-Item $reportFile }
$script=@'
param([string]$Exe,[string]$Report)
$ErrorActionPreference='Stop'
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class TrayUI {
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent,IntPtr after,string cls,IntPtr title);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window,out uint pid);
 [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr window);
 [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr window,uint command);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint x,uint y,uint data,UIntPtr extra);
 [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window,IntPtr after,int x,int y,int width,int height,uint flags);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr window,StringBuilder text,int count);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
 [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr window,uint message,IntPtr wp,IntPtr lp);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window,uint message,IntPtr wp,IntPtr lp);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window,out Rect rect);
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
}
"@
[TrayUI]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
# Flutter's Windows engine currently exposes MSAA rather than UIA. Exercise the
# rendered controls with desktop input, then assert the main repository's state.
function Click-Panel([double]$X,[double]$Y) {
 $area=New-Object TrayUI+Rect; [TrayUI]::GetWindowRect($script:panel,[ref]$area) | Out-Null
 $scale=($area.Right-$area.Left)/320.0
 [TrayUI]::SetCursorPos([int]($area.Left+$X*$scale),[int]($area.Top+$Y*$scale)) | Out-Null
 [TrayUI]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
 [TrayUI]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
 Start-Sleep -Milliseconds 600
}
$checks=New-Object System.Collections.Generic.List[string]
$process=$null
try {
 $process=Start-Process -FilePath $Exe -ArgumentList '--isolated-preview' -PassThru
 for ($i=0;$i -lt 80;$i++) { Start-Sleep -Milliseconds 100; $process.Refresh(); if ($process.MainWindowHandle -ne [IntPtr]::Zero) { break } }
 $main=$process.MainWindowHandle
 if ($main -eq [IntPtr]::Zero) { throw 'Preview main window missing.' }
 Start-Sleep -Seconds 2
 [TrayUI]::SetWindowPos($main,[IntPtr](-1),0,0,0,0,0x43) | Out-Null
 [TrayUI]::SetForegroundWindow($main) | Out-Null
 Start-Sleep -Milliseconds 200
 $mainRect=New-Object TrayUI+Rect; [TrayUI]::GetWindowRect($main,[ref]$mainRect) | Out-Null
 [TrayUI]::SetCursorPos($mainRect.Left+80,$mainRect.Top+15) | Out-Null
 [TrayUI]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
 [TrayUI]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
 Start-Sleep -Milliseconds 200
 $mainView=[TrayUI]::GetWindow($main,5)
 $mainArea=New-Object TrayUI+Rect; [TrayUI]::GetWindowRect($mainView,[ref]$mainArea) | Out-Null
 $dpiScale=[TrayUI]::GetDpiForWindow($mainView)/96.0
 [TrayUI]::SetCursorPos([int]($mainArea.Left+($mainArea.Right-$mainArea.Left)*0.625),[int]($mainArea.Bottom-33*$dpiScale)) | Out-Null
 Start-Sleep -Milliseconds 100
 for($click=0;$click -lt 2;$click++) {
  [TrayUI]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
  Start-Sleep -Milliseconds 80
  [TrayUI]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
  Start-Sleep -Milliseconds 250
 }
 Start-Sleep -Milliseconds 600
 Add-Type -AssemblyName System.Drawing
 $routingBitmap=New-Object Drawing.Bitmap ($mainArea.Right-$mainArea.Left),($mainArea.Bottom-$mainArea.Top)
 $routingGraphics=[Drawing.Graphics]::FromImage($routingBitmap)
 try { $routingGraphics.CopyFromScreen($mainArea.Left,$mainArea.Top,0,0,$routingBitmap.Size); $routingBitmap.Save((Join-Path (Split-Path $Report -Parent) 'windows-routing-page.png')) }
 finally { $routingGraphics.Dispose(); $routingBitmap.Dispose() }
 [TrayUI]::SendMessage($main,0x10,[IntPtr]::Zero,[IntPtr]::Zero) | Out-Null
 if ([TrayUI]::IsWindowVisible($main)) { throw 'Main window did not hide on close.' }
 Start-Sleep -Milliseconds 300
 [TrayUI]::SendMessage($main,0x802a,[IntPtr]::Zero,[IntPtr]0x10401) | Out-Null
 Start-Sleep -Milliseconds 400
 $panel=[IntPtr]::Zero
 do {
  $panel=[TrayUI]::FindWindowEx([IntPtr]::Zero,$panel,'ShadowbatTrayPanel',[IntPtr]::Zero)
  $ownerPID=0; [TrayUI]::GetWindowThreadProcessId($panel,[ref]$ownerPID) | Out-Null
 } while ($panel -ne [IntPtr]::Zero -and $ownerPID -ne $process.Id)
 $cls=New-Object Text.StringBuilder 128; [TrayUI]::GetClassName($main,$cls,128) | Out-Null
 if (-not [TrayUI]::IsWindowVisible($panel)) { throw ('Tray panel did not open. Main='+$main+' Panel='+$panel+' Class='+$cls+' Foreground='+[TrayUI]::GetForegroundWindow()) }
 $checks.Add('Native tray panel opens while main window is hidden')
 $view=[TrayUI]::GetWindow($panel,5)
 $viewClass=New-Object Text.StringBuilder 128
 [TrayUI]::GetClassName($view,$viewClass,128) | Out-Null
 if ($viewClass.ToString() -ne 'FLUTTERVIEW') { throw 'Tray must host a Flutter view.' }
 $checks.Add('Panel content is rendered by FLUTTERVIEW rather than GDI controls')
 $preview=Join-Path $env:LOCALAPPDATA ('Shadowbat\preview-'+$process.Id+'\preferences.json')
 $before=@{useSystemProxy=$false}
 if (Test-Path $preview) { $before=Get-Content $preview -Raw -Encoding UTF8 | ConvertFrom-Json }
 Click-Panel 279 114
 $after=Get-Content $preview -Raw -Encoding UTF8 | ConvertFrom-Json
 if ($before.useSystemProxy -eq $after.useSystemProxy) { throw 'Flutter switch did not update the main repository.' }
 $checks.Add('Flutter switch forwards command to the main repository without closing the panel')
 Click-Panel 230 250
 $state=Get-Content $preview -Raw -Encoding UTF8 | ConvertFrom-Json
 if ($state.selectionMode -ne 'manual') { throw 'Manual segment did not reach the main repository.' }
 $checks.Add('Flutter manual selection forwards to the main repository')
 Click-Panel 90 250
 $state=Get-Content $preview -Raw -Encoding UTF8 | ConvertFrom-Json
 if ($state.selectionMode -ne 'automatic') { throw 'Automatic segment did not reach the main repository.' }
 $checks.Add('Flutter automatic selection forwards to the main repository')
 Add-Type -AssemblyName System.Drawing
 $rect=New-Object TrayUI+Rect
 [TrayUI]::GetWindowRect($panel,[ref]$rect) | Out-Null
 $bitmap=New-Object Drawing.Bitmap ($rect.Right-$rect.Left),($rect.Bottom-$rect.Top)
 $graphics=[Drawing.Graphics]::FromImage($bitmap)
 try { $graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,$bitmap.Size); $bitmap.Save(($Report -replace '\.json$','.png')) }
 finally { $graphics.Dispose(); $bitmap.Dispose() }
 [TrayUI]::PostMessage($view,0x100,[IntPtr]27,[IntPtr]0x10001) | Out-Null
 [TrayUI]::PostMessage($view,0x101,[IntPtr]27,[IntPtr]0xc0010001) | Out-Null
 Start-Sleep -Milliseconds 300
 if ([TrayUI]::IsWindowVisible($panel)) { throw 'Escape must dismiss panel.' }
 $checks.Add('Escape dismisses panel while retaining tray process')
 Start-Sleep -Milliseconds 300
 [TrayUI]::SendMessage($main,0x802a,[IntPtr]::Zero,[IntPtr]0x10400) | Out-Null
 Start-Sleep -Milliseconds 300
 Click-Panel 95 342
 Start-Sleep -Milliseconds 300
 if ([TrayUI]::IsWindowVisible($panel) -or -not [TrayUI]::IsWindowVisible($main)) { throw 'Open action did not dismiss panel and reveal main window.' }
 $checks.Add('Open Shadowbat reveals main window and dismisses tray panel')
 Start-Sleep -Milliseconds 300
 [TrayUI]::SendMessage($main,0x802a,[IntPtr]::Zero,[IntPtr]0x10400) | Out-Null
 Start-Sleep -Milliseconds 300
 Click-Panel 283 342
 if (-not $process.WaitForExit(10000)) { throw 'Tray Quit did not terminate preview.' }
 $checks.Add('Tray Quit exits through repository cleanup')
 @{passed=$true;checks=@($checks);mainDpi=[int]($dpiScale*96);scale=$dpiScale} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Report -Encoding UTF8
} catch {
 @{passed=$false;checks=@($checks);failure=$_.Exception.Message} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Report -Encoding UTF8
} finally {
 if ($process -and -not $process.HasExited) { $process.Kill() }
}
'@
Set-Content -LiteralPath $inner -Value $script -Encoding UTF8
$name='ShadowbatTray-'+[guid]::NewGuid().ToString('N')
$user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
$log=Join-Path $root 'build\windows-tray-test.log'
$launch="try { & '$inner' -Exe '$exe' -Report '$reportFile' *> '$log' } catch { @{passed=`$false;failure=`$_.Exception.Message;checks=@()} | ConvertTo-Json | Set-Content -LiteralPath '$reportFile' -Encoding UTF8 }"
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launch))
$arguments='-NoProfile -ExecutionPolicy Bypass -EncodedCommand '+$encoded
$action=New-ScheduledTaskAction -Execute (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument $arguments
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
try {
 Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings | Out-Null
 Start-ScheduledTask -TaskName $name
 $watch=[Diagnostics.Stopwatch]::StartNew()
 while (-not (Test-Path $reportFile) -and $watch.Elapsed.TotalSeconds -lt 60) { Start-Sleep -Milliseconds 250 }
 if (-not (Test-Path $reportFile)) { throw ('Tray test produced no report. Task result: '+(Get-ScheduledTaskInfo -TaskName $name).LastTaskResult+' Log: '+(Get-Content $log -Raw -ErrorAction SilentlyContinue)) }
 $report=Get-Content -LiteralPath $reportFile -Raw -Encoding UTF8 | ConvertFrom-Json
 $report.checks | ForEach-Object { Write-Output "PASS: $_" }
 if (-not $report.passed) { throw $report.failure }
} finally {
 Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
 Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
 Remove-Item -LiteralPath $inner -ErrorAction SilentlyContinue
}
