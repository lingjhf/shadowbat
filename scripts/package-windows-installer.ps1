[CmdletBinding()]
param([string]$ArchivePath, [string]$CompilerPath)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$destination=Join-Path $root 'dist\windows'
$versionLine=Get-Content (Join-Path $root 'pubspec.yaml') | Where-Object { $_ -match '^version:\s*(\S+)' } | Select-Object -First 1
$version=($versionLine -replace '^version:\s*','').Trim()
if ($version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+\d+$') { throw 'Invalid package version.' }
if (-not $ArchivePath) { $ArchivePath=Join-Path $destination "Shadowbat-$version-windows-x64-unsigned.zip" }
$ArchivePath=(Resolve-Path -LiteralPath $ArchivePath).Path
$expected=(Get-Content -LiteralPath "$ArchivePath.sha256" -Raw).Split(' ')[0].Trim()
if ((Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash -ne $expected) { throw 'Portable ZIP checksum mismatch.' }
if (-not $CompilerPath) {
  $command=Get-Command ISCC.exe -ErrorAction SilentlyContinue
  if ($command) { $CompilerPath=$command.Source }
  else {
    $candidates=@((Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
                  (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'))
    $CompilerPath=$candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  }
}
if (-not $CompilerPath -or -not (Test-Path -LiteralPath $CompilerPath)) { throw 'Install Inno Setup 6 or supply -CompilerPath.' }
# Installer remains unsigned until a trusted release certificate is configured.
$name="Shadowbat-$version-windows-x64-unsigned-setup"
$output=Join-Path $destination "$name.exe"
if (Test-Path -LiteralPath $output) { throw "Installer already exists: $output" }
$staging=Join-Path $destination ('.installer-'+[guid]::NewGuid().ToString('N'))
try {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath,$staging)
  $bundle=Join-Path $staging 'Shadowbat'
  foreach ($file in @('shadowbat.exe','flutter_windows.dll','msvcp140.dll','data\app.so','cores\sing-box.exe','cores\wintun.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $bundle $file))) { throw "Missing installer component: $file" }
  }
  & $CompilerPath "/DBundleDirectory=$bundle" "/DAppVersion=$version" "/DOutputDirectory=$destination" "/DOutputName=$name" (Join-Path $root 'packaging\windows\shadowbat.iss')
  if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed: $LASTEXITCODE" }
  if (-not (Test-Path -LiteralPath $output) -or (Get-Item -LiteralPath $output).Length -lt 1MB) { throw 'Installer was not produced.' }
  $hash=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
  Set-Content -LiteralPath "$output.sha256" -Value "$hash  $name.exe" -Encoding ASCII
  Write-Output "Verified installer: $output"
} finally {
  if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
}
