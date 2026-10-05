param([string]$Configuration='Release')
$ErrorActionPreference='Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root "build\windows\x64\runner\$Configuration\shadowbat.exe"
$resultFile = Join-Path $root 'build\windows-self-test.json'
if (-not (Test-Path $exe)) { throw 'Build the Windows application first: flutter build windows --release' }
if (Test-Path $resultFile) { Remove-Item $resultFile }
$arguments = '--isolated-preview --self-test --self-test-result="' + $resultFile + '"'
$process = Start-Process -FilePath $exe -ArgumentList $arguments -PassThru
if (-not $process.WaitForExit(120000)) { Stop-Process -Id $process.Id -Force; throw 'Windows self-test timed out' }
if (-not (Test-Path $resultFile)) { throw "Self-test exited without a report (exit $($process.ExitCode))" }
$report = Get-Content -LiteralPath $resultFile -Raw -Encoding UTF8 | ConvertFrom-Json
$report.checks | ForEach-Object { Write-Output "PASS: $_" }
if (-not $report.passed) { throw $report.failure }
Write-Output 'Windows native integration checks passed.'
