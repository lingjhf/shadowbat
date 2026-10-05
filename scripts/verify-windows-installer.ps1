[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$InstallerPath)
$ErrorActionPreference='Stop'
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('shadowbat-install-check-'+[guid]::NewGuid().ToString('N'))
$install=Join-Path $temporary 'app'
$group='Shadowbat packaging verification '+[guid]::NewGuid().ToString('N')
$uninstaller=Join-Path $install 'unins000.exe'
try {
  $process=Start-Process -FilePath $InstallerPath -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/DIR="'+$install+'"'),('/GROUP="'+$group+'"')) -Wait -PassThru
  if ($process.ExitCode -ne 0) { throw "Installation failed: $($process.ExitCode)" }
  $required=@('shadowbat.exe','flutter_windows.dll','msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll','data\app.so','data\icudtl.dat','cores\sing-box.exe','cores\libcronet.dll','cores\wintun.dll','cores\terminal-proxy.ps1','cores\sing-box-LICENSE.txt','cores\wintun-LICENSE.txt')
  foreach ($file in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $install $file))) { throw "Installed component missing: $file" }
  }
  if (-not (Test-Path -LiteralPath (Join-Path $install 'data\flutter_assets'))) { throw 'Flutter assets missing.' }
  Write-Output 'Silent installation and runtime/core components verified. App was not launched.'
} finally {
  if (Test-Path -LiteralPath $uninstaller) {
    $process=Start-Process -FilePath $uninstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART') -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Uninstallation failed: $($process.ExitCode)" }
  }
}
if (Test-Path -LiteralPath (Join-Path $install 'shadowbat.exe')) { throw 'Uninstaller left the application executable behind.' }
if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
Write-Output 'Uninstallation verified.'
