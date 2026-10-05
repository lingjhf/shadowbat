# Sign a copy of the Release bundle; keep the running development build intact.
[CmdletBinding()]
param(
  [string]$Thumbprint,
  [uri]$TimestampUrl,
  [string]$SignToolPath,
  [switch]$MachineStore,
  [switch]$CheckOnly
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Split-Path -Parent $PSScriptRoot
$bundle=Join-Path $root 'build\windows\x64\runner\Release'
if (-not $SignToolPath) {
  $kitRoots=@(
    'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots'
  ) | ForEach-Object {
    (Get-ItemProperty $_ -ErrorAction SilentlyContinue).KitsRoot10
  } | Where-Object { $_ } | Select-Object -Unique
  $SignToolPath=$kitRoots | ForEach-Object {
    Get-ChildItem (Join-Path $_ 'bin') -Filter signtool.exe -Recurse -ErrorAction SilentlyContinue
  } | Where-Object { $_.FullName -match '\\x64\\' } |
      Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $SignToolPath -or -not (Test-Path -LiteralPath $SignToolPath)) {
  throw 'SignTool not found. Install Windows SDK or pass -SignToolPath.'
}
Write-Output "SignTool: $SignToolPath"
$store='Cert:\CurrentUser\My'
if ($MachineStore) { $store='Cert:\LocalMachine\My' }
if ($CheckOnly) {
  $certificates=@(Get-ChildItem $store -CodeSigningCert | Where-Object { $_.HasPrivateKey })
  Write-Output ('Code-signing certificates with private keys: '+$certificates.Count)
  $certificates | Select-Object Subject,Issuer,Thumbprint,NotAfter
  return
}
if (-not $Thumbprint) { throw 'A trusted code-signing certificate thumbprint is required.' }
$Thumbprint=$Thumbprint -replace '\s',''
if ($Thumbprint -notmatch '^[0-9a-fA-F]{40}$') { throw 'Invalid certificate thumbprint.' }
if (-not $TimestampUrl -or $TimestampUrl.Scheme -notin @('http','https')) {
  throw 'Pass the RFC 3161 timestamp URL supplied by your certificate provider.'
}
$certificate=Get-Item -LiteralPath "$store\$Thumbprint" -ErrorAction SilentlyContinue
if (-not $certificate -or -not $certificate.HasPrivateKey) {
  throw 'Certificate/private key unavailable in this logon session. Connect the token and use the Windows desktop session if required.'
}
if ($certificate.NotBefore -gt (Get-Date) -or $certificate.NotAfter -lt (Get-Date)) {
  throw 'Certificate is not currently valid.'
}
if ($certificate.Subject -eq $certificate.Issuer) {
  throw 'Self-signed certificates are not accepted by this public-release signing script.'
}
if (-not ($certificate.EnhancedKeyUsageList | Where-Object { [string]$_.ObjectId -eq '1.3.6.1.5.5.7.3.3' })) {
  throw 'Certificate does not have the Code Signing usage.'
}
if (-not (Test-Path -LiteralPath (Join-Path $bundle 'shadowbat.exe'))) {
  throw 'Build first with flutter build windows --release.'
}
$releaseRoot=Join-Path $root 'dist\windows'
New-Item -ItemType Directory -Force $releaseRoot | Out-Null
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$output=Join-Path $releaseRoot "Shadowbat-windows-x64-$stamp"
$staging=Join-Path $releaseRoot ('.signing-'+[guid]::NewGuid().ToString('N'))
$archive="$output.zip"
try {
  New-Item -ItemType Directory $staging | Out-Null
  Copy-Item (Join-Path $bundle '*') -Destination $staging -Recurse
  $targets=@((Join-Path $staging 'shadowbat.exe'))
  $aot=Join-Path $staging 'data\app.so'
  if (Test-Path -LiteralPath $aot) { $targets+=$aot }
  $options=@('sign','/sha1',$Thumbprint,'/s','My','/fd','SHA256',
             '/tr',$TimestampUrl.AbsoluteUri,'/td','SHA256','/d','Shadowbat')
  if ($MachineStore) { $options+='/sm' }
  # Third-party core/driver files retain their original signatures and licenses.
  foreach ($target in $targets) {
    & $SignToolPath @options $target
    if ($LASTEXITCODE -ne 0) { throw "Signing failed: $target" }
    & $SignToolPath verify /pa /all /v $target
    if ($LASTEXITCODE -ne 0) { throw "Signature verification failed: $target" }
    $signature=Get-AuthenticodeSignature -FilePath $target
    if ($signature.Status -ne 'Valid' -or -not $signature.TimeStamperCertificate) {
      throw "A valid timestamped signature is required: $target"
    }
  }
  Move-Item -LiteralPath $staging -Destination $output
  Compress-Archive -Path (Join-Path $output '*') -DestinationPath $archive
  Write-Output "Signed bundle: $output"
  Write-Output "Signed portable archive: $archive"
} finally {
  if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
}
