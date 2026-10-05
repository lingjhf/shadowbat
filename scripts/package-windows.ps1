[CmdletBinding()]
param([string]$RuntimeDirectory)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Split-Path -Parent $PSScriptRoot
$release=Join-Path $root 'build\windows\x64\runner\Release'
$required=@('shadowbat.exe','flutter_windows.dll','data\app.so','data\icudtl.dat',
            'data\flutter_assets','cores\sing-box.exe','cores\wintun.dll',
            'cores\libcronet.dll','cores\terminal-proxy.ps1','cores\wintun-LICENSE.txt',
            'cores\sing-box-LICENSE.txt')
foreach ($name in $required) {
  if (-not (Test-Path -LiteralPath (Join-Path $release $name))) {
    throw "Release component missing: $name. Build with flutter build windows --release."
  }
}
$runtimes=@('msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll')
foreach ($name in $runtimes) {
  if (-not (Test-Path -LiteralPath (Join-Path $release $name)) -and
      (-not $RuntimeDirectory -or -not (Test-Path -LiteralPath (Join-Path $RuntimeDirectory $name)))) {
    throw "Supply -RuntimeDirectory pointing to Visual Studio's redistributable x64 CRT directory ($name missing)."
  }
}
$versionLine=Get-Content (Join-Path $root 'pubspec.yaml') | Where-Object { $_ -match '^version:\s*(\S+)' } | Select-Object -First 1
if (-not $versionLine) { throw 'pubspec.yaml has no version.' }
$version=($versionLine -replace '^version:\s*','').Trim()
if ($version -notmatch '^[0-9A-Za-z.+-]+$') { throw 'Invalid package version.' }
$status=(Get-AuthenticodeSignature -FilePath (Join-Path $release 'shadowbat.exe')).Status
$suffix='unsigned'
if ($status -eq 'Valid') { $suffix='signed' }
$destination=Join-Path $root 'dist\windows'
New-Item -ItemType Directory -Force $destination | Out-Null
$archive=Join-Path $destination "Shadowbat-$version-windows-x64-$suffix.zip"
if (Test-Path -LiteralPath $archive) { throw "Archive already exists: $archive. Move it before repackaging." }
$staging=Join-Path $destination ('.package-'+[guid]::NewGuid().ToString('N'))
$bundle=Join-Path $staging 'Shadowbat'
try {
  New-Item -ItemType Directory -Force $bundle | Out-Null
  Copy-Item (Join-Path $release '*') -Destination $bundle -Recurse
  if ($RuntimeDirectory) {
    # Use the redistributable CRT binaries, not arbitrary DLLs from System32.
    Copy-Item (Join-Path $RuntimeDirectory '*.dll') -Destination $bundle
  }
  $instructions=@"
Shadowbat $version - Windows x64 portable edition

Extract the entire ZIP, then run Shadowbat\shadowbat.exe.
Keep data, cores, and all DLL files beside the executable.
The bundle includes the app-local Visual C++ runtime.

The application signature status for this package is: $status.
Configure your own Shadowsocks nodes and passwords in the app.
For TUN, enable it in Settings, restart as administrator, and approve UAC.
Closing the window keeps the app running in the native system tray.
Use the tray Quit action to stop the proxy and restore settings.

Settings: %LOCALAPPDATA%\Shadowbat
Passwords: Windows Credential Manager
Core/driver licenses and version information: cores\
"@
  Set-Content -LiteralPath (Join-Path $bundle 'README.txt') -Value $instructions -Encoding UTF8
  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $writer=[IO.Compression.ZipFile]::Open($archive,[IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($file in Get-ChildItem $bundle -File -Recurse) {
      $relative='Shadowbat/'+$file.FullName.Substring($bundle.Length+1).Replace('\','/')
      [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
        $writer,$file.FullName,$relative,[IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
  } finally { $writer.Dispose() }
  $zip=[IO.Compression.ZipFile]::OpenRead($archive)
  try {
    # Compare every archived file to its staging copy, including CRT and assets.
    $expected=@(Get-ChildItem $bundle -File -Recurse)
    $entries=@($zip.Entries | Where-Object { $_.Name })
    if ($entries.Count -ne $expected.Count) { throw 'ZIP file count mismatch.' }
    foreach ($file in $expected) {
      $relative='Shadowbat/'+$file.FullName.Substring($bundle.Length+1).Replace('\','/')
      $entry=$zip.GetEntry($relative)
      if (-not $entry -or $entry.Length -ne $file.Length) { throw "ZIP component mismatch: $relative" }
      $stream=$entry.Open()
      $sha=[Security.Cryptography.SHA256]::Create()
      try { $actual=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','') }
      finally { $stream.Dispose(); $sha.Dispose() }
      if ($actual -ne (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) {
        throw "ZIP checksum mismatch: $relative"
      }
    }
    Write-Output ("Verified all {0} archived files." -f $expected.Count)
  } finally { $zip.Dispose() }
  $hash=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
  Set-Content -LiteralPath "$archive.sha256" -Value ($hash+'  '+[IO.Path]::GetFileName($archive)) -Encoding ASCII
  Get-Item $archive | Select-Object FullName,Length
  Write-Output "SHA256: $hash"
} catch {
  if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive }
  throw
} finally {
  if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
}
