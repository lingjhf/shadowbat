param([string]$Configuration='Release', [switch]$TunnelOnly)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding
$root=Split-Path -Parent $PSScriptRoot
$exe=Join-Path $root "build\windows\x64\runner\$Configuration\shadowbat.exe"
$resultFile=Join-Path $root 'build\windows-self-test.json'
if (-not (Test-Path $exe)) { throw 'Build Windows first.' }
if (Test-Path $resultFile) { Remove-Item $resultFile }
# OpenSSH key logons lack the desktop Credential Manager session. Run this
# temporary development test in the already logged-in user's interactive session.
$name='ShadowbatIntegration-'+[guid]::NewGuid().ToString('N')
$user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
$arguments='--isolated-preview --self-test --self-test-result="'+$resultFile+'"'
$action=New-ScheduledTaskAction -Execute $exe -Argument $arguments
$runLevel='Limited'
if ($TunnelOnly) {
  $runLevel='Highest'
  $arguments+=' --self-test-tun-only'
  $action=New-ScheduledTaskAction -Execute $exe -Argument $arguments
}
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel $runLevel
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
try {
  Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings | Out-Null
  Start-ScheduledTask -TaskName $name
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while (-not (Test-Path $resultFile) -and $watch.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 250 }
  if (-not (Test-Path $resultFile)) { throw ('Interactive test produced no report. Task result: '+(Get-ScheduledTaskInfo -TaskName $name).LastTaskResult) }
  Start-Sleep -Milliseconds 300
  $report=Get-Content -LiteralPath $resultFile -Raw -Encoding UTF8 | ConvertFrom-Json
  $report.checks | ForEach-Object { Write-Output "PASS: $_" }
  if (-not $report.passed) { throw $report.failure }
  Write-Output 'Windows native integration checks passed.'
} finally {
  $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  if ($task -and $task.State -eq 'Running') { Stop-ScheduledTask -TaskName $name }
  Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
}
