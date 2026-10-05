$ErrorActionPreference='Stop'
$root = Split-Path -Parent $PSScriptRoot
$destination = Join-Path $root 'windows\tools'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('shadowbat-core-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $temporary,$destination | Out-Null
try {
  $coreArchive = Join-Path $temporary 'core.zip'
  Invoke-WebRequest -Uri 'https://github.com/SagerNet/sing-box/releases/download/v1.14.2/sing-box-1.14.2-windows-amd64.zip' -OutFile $coreArchive
  if ((Get-FileHash $coreArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'c2d8bfff918755808781dfdeeb8581b6c91eb3a243d9a7b55483cfc0c0684d32') { throw 'sing-box archive checksum mismatch' }
  Expand-Archive -LiteralPath $coreArchive -DestinationPath $temporary
  Copy-Item (Join-Path $temporary 'sing-box-1.14.2-windows-amd64\*') -Destination $destination -Force
  $driverArchive = Join-Path $temporary 'driver.zip'
  Invoke-WebRequest -Uri 'https://www.wintun.net/builds/wintun-0.14.1.zip' -OutFile $driverArchive
  if ((Get-FileHash $driverArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne '07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51') { throw 'Wintun archive checksum mismatch' }
  Expand-Archive -LiteralPath $driverArchive -DestinationPath $temporary
  Copy-Item (Join-Path $temporary 'wintun\bin\amd64\wintun.dll') -Destination $destination -Force
  Copy-Item (Join-Path $temporary 'wintun\LICENSE.txt') -Destination (Join-Path $destination 'wintun-LICENSE.txt') -Force
  'v1.14.2 windows-amd64' | Set-Content -LiteralPath (Join-Path $destination 'core-version.txt') -Encoding ASCII
} finally { Remove-Item -LiteralPath $temporary -Recurse -Force }
