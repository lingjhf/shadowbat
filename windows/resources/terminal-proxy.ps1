# Shadowbat PowerShell integration. State is data; never Invoke-Expression.
if (-not $global:ShadowbatOriginalPrompt) {
  $global:ShadowbatOriginalPrompt = (Get-Command prompt -CommandType Function).ScriptBlock
}
if (-not $global:ShadowbatBefore) { $global:ShadowbatBefore = @{}; $global:ShadowbatApplied = @{} }
function global:Sync-ShadowbatProxy {
  $state = $null
  try { $state = Get-Content -LiteralPath '__STATE_PATH__' -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch {}
  $active = $false
  if ($state -and $state.enabled) {
    $app = Get-Process -Id $state.appPID -ErrorAction SilentlyContinue
    $core = Get-Process -Id $state.corePID -ErrorAction SilentlyContinue
    $active = ($null -ne $app -and $app.ProcessName -eq 'shadowbat' -and $null -ne $core -and $core.ProcessName -eq 'sing-box')
  }
  $desired = @{}
  if ($active) {
    $desired = @{ http_proxy="http://127.0.0.1:$($state.http)"; https_proxy="http://127.0.0.1:$($state.http)"; all_proxy="socks5h://127.0.0.1:$($state.socks)" }
  }
  foreach ($name in @('http_proxy','https_proxy','all_proxy')) {
    $current = [Environment]::GetEnvironmentVariable($name, 'Process')
    if ($active) {
      if (-not $global:ShadowbatApplied.ContainsKey($name)) { $global:ShadowbatBefore[$name] = $current }
      elseif ($current -ne $global:ShadowbatApplied[$name]) { continue }
      [Environment]::SetEnvironmentVariable($name, $desired[$name], 'Process')
      $global:ShadowbatApplied[$name] = $desired[$name]
    } elseif ($global:ShadowbatApplied.ContainsKey($name)) {
      if ($current -eq $global:ShadowbatApplied[$name]) { [Environment]::SetEnvironmentVariable($name, $global:ShadowbatBefore[$name], 'Process') }
      $global:ShadowbatBefore.Remove($name); $global:ShadowbatApplied.Remove($name)
    }
  }
}
function global:prompt { Sync-ShadowbatProxy; & $global:ShadowbatOriginalPrompt }
Sync-ShadowbatProxy
