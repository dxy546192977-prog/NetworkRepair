param(
    [switch]$NoDnsChange,
    [switch]$ForceRepair,
    [switch]$Doctor,
    [switch]$ProbeHttp2,
    [switch]$InstallCursorWrapper,
    [switch]$OneClickFix,
    [switch]$Silent,
    [switch]$FixStoreOnlyNoReboot
)

$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSEdition -eq "Desktop") {
    $script:IsWindowsOS = $true
}
else {
    $script:IsWindowsOS = [bool]$IsWindows
}

$script:DefaultTargets = @(
    "api.openai.com",
    "chat.openai.com",
    "api.anthropic.com",
    "claude.ai",
    "openrouter.ai",
    "api2.cursor.sh",
    "api.cursor.sh"
)
$script:DefaultProbeUrl = "https://api2.cursor.sh/"
$script:DefaultCursorHttp2Targets = @(
    "https://api2.cursor.sh/",
    "https://api.cursor.sh/"
)

function Get-ToolSettings {
    param([string]$ScriptDir)

    $settingsPath = Join-Path $ScriptDir "support/settings.json"
    if (-not (Test-Path $settingsPath)) {
        return $null
    }

    try {
        return (Get-Content -Path $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        Write-Host "  [WARN] Failed to parse settings.json, using defaults: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Get-StringArraySetting {
    param(
        [object]$Value,
        [string[]]$Fallback
    )

    if ($null -eq $Value) {
        return $Fallback
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @($Value | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        if ($items.Count -gt 0) {
            return $items
        }
    }

    return $Fallback
}

function Get-StringSetting {
    param(
        [object]$Value,
        [string]$Fallback
    )

    if ($null -eq $Value) {
        return $Fallback
    }

    $text = "$Value".Trim()
    if ($text) {
        return $text
    }

    return $Fallback
}

function Get-CursorWrapperStatus {
    param([string]$ScriptDir)

    $packageWrapperPath = Join-Path $ScriptDir "bin/cursor-company.cmd"
    $homeLocalBin = Join-Path $HOME ".local/bin"
    $installedWrapperPath = Join-Path $homeLocalBin "cursor-company.cmd"
    $pathCommand = $null
    $pathValue = $null
    try {
        $pathCommand = Get-Command -Name "cursor-company.cmd" -ErrorAction Stop
        $pathValue = $pathCommand.Source
    }
    catch {
        $pathValue = $null
    }

    $cursorCandidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Cursor\Cursor.exe"),
        (Join-Path $env:ProgramFiles "Cursor\Cursor.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Cursor\Cursor.exe")
    ) | Where-Object { $_ -and (Test-Path $_) }

    [PSCustomObject]@{
        PackageWrapperExists   = Test-Path $packageWrapperPath
        PackageWrapperPath     = $packageWrapperPath
        InstalledWrapperExists = Test-Path $installedWrapperPath
        InstalledWrapperPath   = $installedWrapperPath
        OnPath                 = [bool]$pathValue
        OnPathSource           = $pathValue
        CursorInstalled        = ($cursorCandidates.Count -gt 0)
        CursorCandidates       = $cursorCandidates
    }
}

function Install-CursorWrapper {
    param([string]$ScriptDir)

    $sourceCmd = Join-Path $ScriptDir "bin/cursor-company.cmd"
    $sourcePs1 = Join-Path $ScriptDir "bin/cursor-company.ps1"
    $sourceRepair = Join-Path $ScriptDir "cursor-model-network-repair.ps1"
    $sourceSettings = Join-Path $ScriptDir "support/settings.json"
    if (-not (Test-Path $sourceCmd) -or -not (Test-Path $sourcePs1)) {
        throw "Wrapper files are missing under src/bin (cursor-company.cmd / cursor-company.ps1)."
    }

    $targetDir = Join-Path $HOME ".local/bin"
    if (-not (Test-Path $targetDir)) {
        New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
    }

    Copy-Item -Path $sourceCmd -Destination (Join-Path $targetDir "cursor-company.cmd") -Force
    Copy-Item -Path $sourcePs1 -Destination (Join-Path $targetDir "cursor-company.ps1") -Force
    if (Test-Path $sourceRepair) {
        Copy-Item -Path $sourceRepair -Destination (Join-Path $targetDir "cursor-model-network-repair.ps1") -Force
    }
    if (Test-Path $sourceSettings) {
        Copy-Item -Path $sourceSettings -Destination (Join-Path $targetDir "settings.json") -Force
    }

    Write-Section "Cursor Wrapper"
    Write-Host "  [OK] Installed cursor-company wrapper to $targetDir" -ForegroundColor Green
    Write-Host "  [INFO] If command not found, add this directory to PATH and reopen terminal:" -ForegroundColor Yellow
    Write-Host "         $targetDir" -ForegroundColor White
}

function Set-ConsoleTheme {
    try {
        $Host.UI.RawUI.BackgroundColor = "Black"
        $Host.UI.RawUI.ForegroundColor = "Gray"
        Clear-Host
    }
    catch {
    }
}

function Initialize-ConsoleEncoding {
    if (-not $script:IsWindowsOS) {
        return
    }

    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        [Console]::InputEncoding = [System.Text.Encoding]::UTF8
        $global:OutputEncoding = [System.Text.Encoding]::UTF8
    }
    catch {
    }
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor DarkGray
    Write-Host $Title -ForegroundColor White
    Write-Host ("=" * 72) -ForegroundColor DarkGray
}

function Write-Banner {
    Write-Host ""
    Write-Host "########################################################################" -ForegroundColor DarkGray
    Write-Host "#                  Cursor Network Repair Assistant                     #" -ForegroundColor White
    Write-Host "########################################################################" -ForegroundColor DarkGray
    Write-Host "  Checks DNS, TCP 443, HTTPS (Cursor + OpenRouter), HTTP/2, and stack health." -ForegroundColor Gray
}

function Write-InfoLine {
    param(
        [string]$Label,
        [string]$Value
    )

    Write-Host ("  {0,-18} : {1}" -f $Label, $Value) -ForegroundColor Gray
}

function Write-Step {
    param(
        [int]$Number,
        [int]$Total = 6,
        [string]$Title
    )

    Write-Host ""
    Write-Host ("[{0}/{1}] {2}" -f $Number, $Total, $Title) -ForegroundColor White
}

function Write-EndpointTable {
    param(
        [object[]]$Rows,
        [string]$Title
    )

    Write-Section $Title
    foreach ($row in $Rows) {
        $status = if ($row.Passed) { "[PASS]" } else { "[FAIL]" }
        $color = if ($row.Passed) { "Green" } else { "Red" }
        $dns = if ($row.DnsOK) { "DNS OK " } else { "DNS ERR" }
        $tcp = if ($row.Tcp443OK) { "TCP OK " } else { "TCP ERR" }
        Write-Host ("  {0}  {1,-22}  {2}  {3}" -f $status, $row.Host, $dns, $tcp) -ForegroundColor $color
    }
}

function Write-HttpsProbeCard {
    param(
        [object]$Probe,
        [string]$Title
    )

    Write-Section $Title
    Write-InfoLine -Label "URL" -Value $Probe.Uri
    Write-InfoLine -Label "TLS / HTTP" -Value $(if ($Probe.TcpLayerReachable) { "Response received" } else { "No HTTP response" })
    Write-InfoLine -Label "HTTP status" -Value $(if ($null -ne $Probe.HttpStatus) { [string]$Probe.HttpStatus } else { "N/A" })
    Write-InfoLine -Label "Region hint" -Value $(if ($Probe.LooksLikeRegionBlock) { "Likely policy / region related" } else { "No obvious region hint" })
    if ($Probe.Error) {
        Write-InfoLine -Label "Error detail" -Value $Probe.Error
    }
}

function Write-FinalSummary {
    param(
        [int]$FailCount,
        [object]$Probe
    )

    Write-Section "Summary"
    if ($FailCount -eq 0) {
        Write-Host "  [OK] DNS/TCP checks passed." -ForegroundColor Green
    }
    else {
        Write-Host "  [WARN] $FailCount target(s) still have DNS/TCP problems." -ForegroundColor Yellow
    }

    if ($Probe -and $Probe.LooksLikeRegionBlock) {
        Write-Host "  [INFO] HTTPS looks more like a provider policy / region limitation." -ForegroundColor Yellow
        Write-Host "         https://cursor.com/docs/account/regions" -ForegroundColor White
    }
    elseif ($Probe -and -not $Probe.TcpLayerReachable) {
        Write-Host "  [INFO] HTTPS failed before policy evaluation. Focus on proxy/TLS/connectivity." -ForegroundColor Yellow
    }
}

function Ensure-Admin {
    if (-not $script:IsWindowsOS) {
        return
    }

    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        Write-Host "Not running as Administrator. Relaunching with elevation..." -ForegroundColor Yellow
        $elevArgs = @("-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
        if ($NoDnsChange) { $elevArgs += "-NoDnsChange" }
        if ($ForceRepair) { $elevArgs += "-ForceRepair" }
        if ($Doctor) { $elevArgs += "-Doctor" }
        if ($ProbeHttp2) { $elevArgs += "-ProbeHttp2" }
        if ($InstallCursorWrapper) { $elevArgs += "-InstallCursorWrapper" }
        if ($OneClickFix) { $elevArgs += "-OneClickFix" }
        if ($FixStoreOnlyNoReboot) { $elevArgs += "-FixStoreOnlyNoReboot" }

        $psExe = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh.exe" } else { "powershell.exe" }
        Start-Process -FilePath $psExe -Verb RunAs -ArgumentList ($elevArgs -join " ")
        exit 0
    }
}

function Test-TcpPort {
    param(
        [string]$HostName,
        [int]$Port = 443,
        [int]$TimeoutMs = 12000
    )

    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        $waited = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $waited) {
            try { $client.Close() } catch { }
            return $false
        }
        $client.EndConnect($iar)
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($client) {
            try { $client.Close() } catch { }
        }
    }
}

function Test-Endpoint {
    param(
        [string]$HostName,
        [int]$Port = 443
    )

    $dnsOk = $false
    $tcpOk = $false
    $dnsError = ""
    $tcpError = ""

    try {
        [void][System.Net.Dns]::GetHostAddresses($HostName)
        $dnsOk = $true
    }
    catch {
        $dnsError = $_.Exception.Message
    }

    try {
        $tcpOk = Test-TcpPort -HostName $HostName -Port $Port
        if (-not $tcpOk) {
            $tcpError = "TCP connect to port $Port failed or timed out"
        }
    }
    catch {
        $tcpError = $_.Exception.Message
    }

    [PSCustomObject]@{
        Host     = $HostName
        DnsOK    = $dnsOk
        Tcp443OK = $tcpOk
        Passed   = ($dnsOk -and $tcpOk)
        DnsError = $dnsError
        TcpError = $tcpError
    }
}

function Get-CursorHttpsProbe {
    param(
        [string]$Uri = "https://api2.cursor.sh/"
    )

    $result = [ordered]@{
        Uri                  = $Uri
        TcpLayerReachable    = $false
        HttpStatus           = $null
        Error                = ""
        BodySnippet          = ""
        LooksLikeRegionBlock = $false
    }

    try {
        $response = Invoke-WebRequest -Uri $Uri -Method Get -TimeoutSec 25 -UseBasicParsing -MaximumRedirection 5 -ErrorAction Stop
        $result.TcpLayerReachable = $true
        $result.HttpStatus = [int]$response.StatusCode
        if ($response.Content) {
            $len = [Math]::Min(2000, $response.Content.Length)
            $result.BodySnippet = $response.Content.Substring(0, $len)
        }
    }
    catch {
        $ex = $_.Exception
        if ($ex.Response) {
            $result.TcpLayerReachable = $true
            $result.HttpStatus = [int]$ex.Response.StatusCode
            try {
                $stream = $ex.Response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $body = $reader.ReadToEnd()
                    $reader.Close()
                    if ($body) {
                        $len = [Math]::Min(2000, $body.Length)
                        $result.BodySnippet = $body.Substring(0, $len)
                    }
                }
            }
            catch {
                $result.Error = $_.Exception.Message
            }
        }
        else {
            $result.Error = $ex.Message
        }
    }

    $haystack = (($result.BodySnippet + " " + $result.Error)).ToLowerInvariant()
    if ($result.HttpStatus -eq 403 -or $result.HttpStatus -eq 451) {
        $result.LooksLikeRegionBlock = $true
    }
    if ($haystack -match 'region|does not serve|not available|unsupported country|unavailable in your|doesn''t serve|not supported in your region|model provider') {
        $result.LooksLikeRegionBlock = $true
    }

    [PSCustomObject]$result
}

function Get-OpenRouterHttpsProbe {
    return Get-CursorHttpsProbe -Uri "https://openrouter.ai/api/v1/models"
}

function Write-OpenRouterHttpsInterpretation {
    param(
        [object]$Probe,
        [object]$OpenRouterTcpRow
    )

    Write-Host ""
    if (-not $Probe.TcpLayerReachable) {
        Write-Host "OpenRouter HTTPS: no HTTP response (TLS/connectivity/proxy issue). Claude Code via OpenRouter will fail until this is green." -ForegroundColor Yellow
        if ($Probe.Error) {
            Write-Host "  Detail: $($Probe.Error)" -ForegroundColor DarkGray
        }
        return
    }

    Write-Host "OpenRouter HTTPS: got HTTP response. Status: $($Probe.HttpStatus)" -ForegroundColor $(if ($Probe.LooksLikeRegionBlock) { "Yellow" } else { "Green" })

    if ($OpenRouterTcpRow -and $OpenRouterTcpRow.Passed -and $Probe.LooksLikeRegionBlock) {
        Write-Host ""
        Write-Host "TCP to openrouter.ai is OK but HTTP hints policy/region. Claude Code may still show 'not available in your region' for some Anthropic models." -ForegroundColor Yellow
        Write-Host "OpenRouter + Claude Code: https://openrouter.ai/docs/guides/coding-agents/claude-code-integration" -ForegroundColor White
        Write-Host "Provider routing: https://openrouter.ai/docs/guides/routing/provider-selection" -ForegroundColor White
    }
    elseif ($OpenRouterTcpRow -and $OpenRouterTcpRow.Passed -and -not $Probe.LooksLikeRegionBlock) {
        Write-Host "OpenRouter endpoint reachable. If Claude Code still errors, check model ID, API key, and upstream region policy (not local TCP)." -ForegroundColor DarkGray
    }
}

function Read-ClaudeSettingsEnvMap {
    $map = [ordered]@{}
    $path = Join-Path $env:USERPROFILE ".claude\settings.json"
    if (-not (Test-Path -LiteralPath $path)) {
        return $map
    }
    try {
        $j = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $j -and $null -ne $j.env) {
            foreach ($prop in $j.env.PSObject.Properties) {
                $map[$prop.Name] = [string]$prop.Value
            }
        }
    }
    catch {
        Write-Host "  [WARN] Could not read ~/.claude/settings.json: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    return $map
}

function Read-OptionalClaudeLaunchOverrideEnvMap {
    param([string]$ScriptDirectory)
    $map = [ordered]@{}
    $path = Join-Path $ScriptDirectory "claude-code-launch.json"
    if (-not (Test-Path -LiteralPath $path)) {
        return $map
    }
    try {
        $j = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $j -and $null -ne $j.env) {
            foreach ($prop in $j.env.PSObject.Properties) {
                $map[$prop.Name] = [string]$prop.Value
            }
        }
    }
    catch {
        Write-Host "  [WARN] Could not read claude-code-launch.json: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    return $map
}

function Merge-OpenRouterClaudeDefaults {
    param([System.Collections.Specialized.OrderedDictionary]$Map)
    if (-not $Map.Contains("ANTHROPIC_BASE_URL") -or [string]::IsNullOrWhiteSpace([string]$Map["ANTHROPIC_BASE_URL"])) {
        $Map["ANTHROPIC_BASE_URL"] = "https://openrouter.ai/api"
    }
    $Map["ANTHROPIC_API_KEY"] = ""
    if (-not $Map.Contains("ANTHROPIC_DEFAULT_SONNET_MODEL") -or [string]::IsNullOrWhiteSpace([string]$Map["ANTHROPIC_DEFAULT_SONNET_MODEL"])) {
        $Map["ANTHROPIC_DEFAULT_SONNET_MODEL"] = "anthropic/claude-sonnet-4.6"
    }
    if (-not $Map.Contains("ANTHROPIC_DEFAULT_OPUS_MODEL") -or [string]::IsNullOrWhiteSpace([string]$Map["ANTHROPIC_DEFAULT_OPUS_MODEL"])) {
        $Map["ANTHROPIC_DEFAULT_OPUS_MODEL"] = "anthropic/claude-opus-4.6"
    }
    if (-not $Map.Contains("ANTHROPIC_DEFAULT_HAIKU_MODEL") -or [string]::IsNullOrWhiteSpace([string]$Map["ANTHROPIC_DEFAULT_HAIKU_MODEL"])) {
        $Map["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = "anthropic/claude-haiku-4.5"
    }
    if (-not $Map.Contains("ANTHROPIC_MODEL") -or [string]::IsNullOrWhiteSpace([string]$Map["ANTHROPIC_MODEL"])) {
        $Map["ANTHROPIC_MODEL"] = [string]$Map["ANTHROPIC_DEFAULT_SONNET_MODEL"]
    }
}

function Escape-CmdSetValue {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    return (($Value -replace '\^', '^^') -replace '%', '%%')
}

function Show-NetworkRepairTrayBalloon {
    param(
        [string]$Title,
        [string]$Body,
        [bool]$IsError = $false
    )
    if (-not $script:IsWindowsOS) {
        return
    }
    try {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        Add-Type -AssemblyName System.Drawing | Out-Null
        $ico = [System.Drawing.SystemIcons]::Information
        if ($IsError) {
            $ico = [System.Drawing.SystemIcons]::Warning
        }
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = $ico
        $ni.Visible = $true
        $ni.Text = $Title
        $tip = [System.Windows.Forms.ToolTipIcon]::Information
        if ($IsError) {
            $tip = [System.Windows.Forms.ToolTipIcon]::Warning
        }
        $ni.ShowBalloonTip(5000, $Title, $Body, $tip)
        Start-Sleep -Milliseconds 900
        $ni.Visible = $false
        $ni.Dispose()
    }
    catch {
    }
}

function Test-LaunchClaudeCodeOnExeSuccess {
    param([object]$ToolSettings)
    if ($null -eq $ToolSettings -or $null -eq $ToolSettings.integrations) {
        return $false
    }
    $v = $ToolSettings.integrations.launchClaudeCodeOnExeSuccess
    if ($null -eq $v) {
        return $false
    }
    return [bool]$v
}

function Test-ShowTrayBalloonOnExeFinish {
    param([object]$ToolSettings)
    if ($null -eq $ToolSettings -or $null -eq $ToolSettings.integrations) {
        return $true
    }
    $v = $ToolSettings.integrations.showTrayBalloonOnExeFinish
    if ($null -eq $v) {
        return $true
    }
    return [bool]$v
}

function New-ClaudeOpenRouterLaunchCmd {
    param(
        [string]$ClaudeExe,
        [string]$WorkDir,
        [System.Collections.IDictionary]$EnvMap
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("@echo off")
    $lines.Add("chcp 65001 >nul")
    $lines.Add("title Claude Code (OpenRouter)")
    $lines.Add(('cd /d "{0}"' -f ($WorkDir -replace '"', '""')))
    foreach ($key in @($EnvMap.Keys)) {
        $val = Escape-CmdSetValue -Value ([string]$EnvMap[$key])
        $lines.Add(('set "{0}={1}"' -f $key, $val))
    }
    $exeQ = $ClaudeExe -replace '"', '""'
    $lines.Add(('"{0}"' -f $exeQ))
    $tmp = Join-Path $env:TEMP ("claude-or-launch-{0}.cmd" -f [Guid]::NewGuid().ToString("N"))
    $enc = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllLines($tmp, $lines.ToArray(), $enc)
    return $tmp
}

function Start-ClaudeCodeWithOpenRouterEnv {
    param([string]$ScriptRoot)

    Write-Section "Launch Claude Code (OpenRouter env)"
    $startDir = Split-Path -Parent $ScriptRoot
    if (-not (Test-Path -LiteralPath $startDir)) {
        $startDir = Join-Path $env:USERPROFILE "Desktop\AI"
        if (-not (Test-Path -LiteralPath $startDir)) {
            $startDir = Join-Path $env:USERPROFILE "Desktop"
        }
    }
    $claudeCmd = $null
    try {
        $claudeCmd = (Get-Command claude -ErrorAction Stop).Source
    }
    catch {
        $candidates = @(
            (Join-Path $env:USERPROFILE ".local\bin\claude.exe"),
            (Join-Path $env:APPDATA "npm\claude.cmd")
        )
        foreach ($p in $candidates) {
            if (Test-Path -LiteralPath $p) {
                $claudeCmd = $p
                break
            }
        }
    }

    if (-not $claudeCmd) {
        Write-Host "  [SKIP] Could not find 'claude'. Install Claude Code first." -ForegroundColor Yellow
        Write-Host "         https://code.claude.com/docs/en/overview" -ForegroundColor White
        return
    }

    $envMap = Read-ClaudeSettingsEnvMap
    foreach ($kv in (Read-OptionalClaudeLaunchOverrideEnvMap -ScriptDirectory $ScriptRoot).GetEnumerator()) {
        $envMap[$kv.Key] = $kv.Value
    }
    Merge-OpenRouterClaudeDefaults -Map $envMap
    if (-not $envMap.Contains("ANTHROPIC_AUTH_TOKEN") -or [string]::IsNullOrWhiteSpace([string]$envMap["ANTHROPIC_AUTH_TOKEN"])) {
        Write-Host "  [WARN] No ANTHROPIC_AUTH_TOKEN (OpenRouter key). Set it in %USERPROFILE%\.claude\settings.json -> env, or src\claude-code-launch.json" -ForegroundColor Yellow
    }
    Write-Host "  Working dir: $startDir" -ForegroundColor Gray
    Write-Host "  Executable:  $claudeCmd" -ForegroundColor Gray
    Write-Host "  ANTHROPIC_BASE_URL -> $($envMap['ANTHROPIC_BASE_URL'])" -ForegroundColor DarkGray
    $launchBat = New-ClaudeOpenRouterLaunchCmd -ClaudeExe $claudeCmd -WorkDir $startDir -EnvMap $envMap
    Start-Process -FilePath "cmd.exe" -ArgumentList @("/k", "`"$launchBat`"") -WorkingDirectory $startDir | Out-Null
    Write-Host "  [OK] Opened Command Prompt with Claude Code (temp launcher written)." -ForegroundColor Green
}

function Test-Http2TargetsWithPwsh {
    param(
        [string[]]$Targets,
        [int]$TimeoutSec = 20
    )

    $pwshPath = $null
    $pwshCmd = Get-Command -Name "pwsh.exe" -ErrorAction SilentlyContinue
    if ($pwshCmd) {
        $pwshPath = $pwshCmd.Source
    }
    if (-not $pwshPath) {
        $pwshCmd = Get-Command -Name "pwsh" -ErrorAction SilentlyContinue
        if ($pwshCmd) {
            $pwshPath = $pwshCmd.Source
        }
    }
    if (-not $pwshPath) {
        $defaultPwsh = Join-Path $env:ProgramFiles "PowerShell\7\pwsh.exe"
        if (Test-Path $defaultPwsh) {
            $pwshPath = $defaultPwsh
        }
    }

    if (-not $pwshPath) {
        return $null
    }

    $tempScript = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), ".ps1")
    $targetsFile = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), ".json")
    $scriptBody = @'
param(
    [string]$TargetsFile,
    [int]$TimeoutSec = 20
)

$ErrorActionPreference = "Stop"
$targets = @()
if ($TargetsFile -and (Test-Path $TargetsFile)) {
    $targetsRaw = Get-Content -Path $TargetsFile -Raw -Encoding UTF8
    if ($targetsRaw) {
        $targets = @((ConvertFrom-Json -InputObject $targetsRaw))
    }
}

$rows = @()
foreach ($target in $targets) {
    $url = "$target".Trim()
    if (-not $url) {
        continue
    }
    if ($url -notmatch "^https?://") {
        $url = "https://$url/"
    }

    $httpVersion = "n/a"
    $httpCode = "n/a"
    $ready = $false
    $errorText = ""

    try {
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)

        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $url)
        $request.Version = [Version]::new(2, 0)
        if ([System.Net.Http.HttpVersionPolicy]) {
            $request.VersionPolicy = [System.Net.Http.HttpVersionPolicy]::RequestVersionOrHigher
        }

        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $httpVersion = $response.Version.ToString()
        $httpCode = [int]$response.StatusCode
        $ready = ($response.Version.Major -ge 2)
        $response.Dispose()
        $request.Dispose()
        $client.Dispose()
        $handler.Dispose()
    }
    catch {
        $errorText = $_.Exception.Message
    }

    $rows += [PSCustomObject]@{
        Target      = $url
        HttpVersion = $httpVersion
        HttpCode    = "$httpCode"
        Ready       = $ready
        Error       = $errorText
        Method      = "pwsh"
        CanVerify   = $true
    }
}

$rows | ConvertTo-Json -Depth 5 -Compress
'@

    try {
        Set-Content -Path $tempScript -Value $scriptBody -Encoding UTF8
        $targetsJson = ($Targets | ConvertTo-Json -Compress)
        Set-Content -Path $targetsFile -Value $targetsJson -Encoding UTF8
        $raw = & $pwshPath -NoProfile -ExecutionPolicy Bypass -File $tempScript $targetsFile $TimeoutSec 2>&1
        $rawText = ($raw | Out-String).Trim()
        if (-not $rawText) {
            return @(
                [PSCustomObject]@{
                    Target      = "pwsh"
                    HttpVersion = "n/a"
                    HttpCode    = "n/a"
                    Ready       = $false
                    Error       = "pwsh probe returned empty output"
                    Method      = "pwsh"
                    CanVerify   = $false
                }
            )
        }

        $parsed = ConvertFrom-Json -InputObject $rawText
        if ($parsed -is [System.Array]) {
            return $parsed
        }
        return @($parsed)
    }
    catch {
        return @(
            [PSCustomObject]@{
                Target      = "pwsh"
                HttpVersion = "n/a"
                HttpCode    = "n/a"
                Ready       = $false
                Error       = "pwsh probe failed: $($_.Exception.Message)"
                Method      = "pwsh"
                CanVerify   = $false
            }
        )
    }
    finally {
        if (Test-Path $tempScript) {
            Remove-Item -Path $tempScript -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $targetsFile) {
            Remove-Item -Path $targetsFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-Http2Targets {
    param(
        [string[]]$Targets,
        [int]$TimeoutSec = 20
    )

    $curlCmd = Get-Command -Name "curl.exe" -ErrorAction SilentlyContinue
    if (-not $curlCmd) {
        $curlCmd = Get-Command -Name "curl" -ErrorAction SilentlyContinue
    }

    if (-not $curlCmd) {
        $pwshRowsMissingCurl = Test-Http2TargetsWithPwsh -Targets $Targets -TimeoutSec $TimeoutSec
        if ($pwshRowsMissingCurl) {
            return $pwshRowsMissingCurl
        }
        return @(
            [PSCustomObject]@{
                Target      = "curl"
                HttpVersion = "n/a"
                HttpCode    = "n/a"
                Ready       = $false
                Error       = "curl was not found on PATH; cannot verify HTTP/2 readiness"
                Method      = "curl"
                CanVerify   = $false
            }
        )
    }

    $curlVersionText = (& $curlCmd.Source -V 2>&1 | Out-String)
    $curlHasHttp2 = $curlVersionText -match "HTTP2"
    if (-not $curlHasHttp2) {
        $pwshRowsNoH2 = Test-Http2TargetsWithPwsh -Targets $Targets -TimeoutSec $TimeoutSec
        if ($pwshRowsNoH2) {
            return $pwshRowsNoH2
        }
        return @(
            [PSCustomObject]@{
                Target      = "curl"
                HttpVersion = "n/a"
                HttpCode    = "n/a"
                Ready       = $false
                Error       = "Current curl does not support HTTP/2; cannot verify readiness. Install curl with nghttp2 support or PowerShell 7+ with compatible probe tooling."
                Method      = "curl"
                CanVerify   = $false
            }
        )
    }

    $results = @()
    foreach ($target in $Targets) {
        $url = "$target".Trim()
        if (-not $url) {
            continue
        }

        if ($url -notmatch "^https?://") {
            $url = "https://$url/"
        }

        $output = ""
        $errorText = ""
        $httpVersion = "n/a"
        $httpCode = "n/a"
        $ready = $false

        $discardTarget = if ($script:IsWindowsOS) { "NUL" } else { "/dev/null" }
        try {
            $curlOutput = & $curlCmd.Source `
                --http2 `
                --location `
                --silent `
                --show-error `
                --max-time $TimeoutSec `
                --output $discardTarget `
                --write-out "HTTP_VERSION:%{http_version}`nHTTP_CODE:%{http_code}`n" `
                $url 2>&1

            $output = ($curlOutput | Out-String)
            if ($output -match "HTTP_VERSION:([^\r\n]+)") {
                $httpVersion = $Matches[1].Trim()
            }
            if ($output -match "HTTP_CODE:([^\r\n]+)") {
                $httpCode = $Matches[1].Trim()
            }
            if ($httpVersion -eq "2" -or $httpVersion -eq "2.0") {
                $ready = $true
            }
        }
        catch {
            $errorText = $_.Exception.Message
        }

        if (-not $errorText -and -not $ready -and $output -and $output -notmatch "HTTP_VERSION:") {
            $errorText = ($output.Trim())
        }

        $results += [PSCustomObject]@{
            Target      = $url
            HttpVersion = $httpVersion
            HttpCode    = $httpCode
            Ready       = $ready
            Error       = $errorText
            Method      = "curl"
            CanVerify   = $true
        }
    }

    return $results
}

function Write-Http2Table {
    param(
        [object[]]$Rows,
        [string]$Title = "HTTP/2 probe"
    )

    Write-Section $Title
    foreach ($row in $Rows) {
        $status = if ($row.Ready) { "[OK]  " } else { "[WARN]" }
        $color = if ($row.Ready) { "Green" } elseif ($row.CanVerify -eq $false) { "Red" } else { "Yellow" }
        Write-Host ("  {0} {1,-30}  h2={2,-5}  code={3}" -f $status, $row.Target, $row.HttpVersion, $row.HttpCode) -ForegroundColor $color
        if ($row.Error) {
            Write-Host ("         detail: {0}" -f $row.Error) -ForegroundColor DarkGray
        }
    }
}

function Write-CursorWrapperCard {
    param([object]$WrapperStatus)

    Write-Section "Cursor wrapper"
    Write-InfoLine -Label "Package wrapper" -Value $(if ($WrapperStatus.PackageWrapperExists) { "found" } else { "missing" })
    Write-InfoLine -Label "Installed wrapper" -Value $(if ($WrapperStatus.InstalledWrapperExists) { "found" } else { "not installed" })
    Write-InfoLine -Label "On PATH" -Value $(if ($WrapperStatus.OnPath) { "yes" } else { "no" })
    Write-InfoLine -Label "Cursor installed" -Value $(if ($WrapperStatus.CursorInstalled) { "yes" } else { "no" })
    if ($WrapperStatus.OnPathSource) {
        Write-InfoLine -Label "Path source" -Value $WrapperStatus.OnPathSource
    }
}

function Write-DoctorJson {
    param(
        [string]$Path,
        [object]$Body
    )

    $json = $Body | ConvertTo-Json -Depth 8
    Set-Content -Path $Path -Value $json -Encoding UTF8 -NoNewline
}

function Write-CursorHttpsInterpretation {
    param(
        [object]$Probe,
        [object]$Api2TcpRow
    )

    Write-Host ""
    if (-not $Probe.TcpLayerReachable) {
        Write-Host "HTTPS probe: TLS/HTTP failed before a response (or connection error). Treat as connectivity/TLS/proxy issue." -ForegroundColor Yellow
        if ($Probe.Error) {
            Write-Host "  Detail: $($Probe.Error)" -ForegroundColor DarkGray
        }
        return
    }

    Write-Host "HTTPS probe: got HTTP response (TLS OK). Status: $($Probe.HttpStatus)" -ForegroundColor $(if ($Probe.LooksLikeRegionBlock) { "Yellow" } else { "Green" })

    if ($Api2TcpRow -and $Api2TcpRow.Passed -and $Probe.LooksLikeRegionBlock) {
        Write-Host ""
        Write-Host "TCP to api2.cursor.sh is OK but HTTP/body suggests policy/region (e.g. model provider not supported in your region). Local DNS/proxy tweaks cannot bypass Cursor account/region policy." -ForegroundColor Yellow
        Write-Host "See: https://cursor.com/docs/account/regions" -ForegroundColor White
        Write-Host "Check Cursor account, billing region, and provider availability for your region." -ForegroundColor DarkGray
    }
    elseif ($Api2TcpRow -and $Api2TcpRow.Passed -and -not $Probe.LooksLikeRegionBlock) {
        Write-Host "No obvious region signal in this probe. If Cursor still shows region errors, read the regions doc above anyway." -ForegroundColor DarkGray
    }
}

function Set-PublicDnsForActiveAdapters {
    $sd = Split-Path -Parent $PSCommandPath
    $toolSettings = Get-ToolSettings -ScriptDir $sd
    $primary = "1.1.1.1"
    $secondary = "8.8.8.8"
    if ($toolSettings -and $toolSettings.dns) {
        $primary = Get-StringSetting -Value $toolSettings.dns.primary -Fallback $primary
        $secondary = Get-StringSetting -Value $toolSettings.dns.secondary -Fallback $secondary
    }
    Write-Host "Setting DNS on active adapters to $primary / $secondary ..." -ForegroundColor Yellow
    $targets = Get-NetIPConfiguration |
        Where-Object { $null -ne $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq "Up" }
    foreach ($t in $targets) {
        try {
            Set-DnsClientServerAddress -InterfaceIndex $t.InterfaceIndex -ServerAddresses @($primary, $secondary)
            Write-Host "  [OK] $($t.InterfaceAlias)" -ForegroundColor Green
        }
        catch {
            Write-Host "  [FAILED] $($t.InterfaceAlias): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function Repair-MicrosoftStoreLink {
    if (-not $script:IsWindowsOS) {
        Write-Host "  [SKIP] Microsoft Store link fix is only available on Windows." -ForegroundColor DarkGray
        return
    }

    $storeUri = "ms-windows-store://home"
    $storeProcessNames = @("WinStore.App", "ApplicationFrameHost")
    $winInetProxyRegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"

    Write-Host "  Pre-step: Check WinINET proxy (Store often fails with local loopback proxy) ..." -ForegroundColor Yellow
    try {
        $proxyCfg = Get-ItemProperty -Path $winInetProxyRegPath -ErrorAction Stop
        $proxyEnabled = [int]$proxyCfg.ProxyEnable
        $proxyServer = [string]$proxyCfg.ProxyServer
        if ($proxyEnabled -eq 1 -and $proxyServer -match '(^|\s|;)(127\.0\.0\.1|localhost):\d+') {
            Write-Host "    [WARN] Detected local proxy: $proxyServer. Temporarily disabling for Store repair." -ForegroundColor Yellow
            Set-ItemProperty -Path $winInetProxyRegPath -Name ProxyEnable -Value 0 -ErrorAction Stop
            Set-ItemProperty -Path $winInetProxyRegPath -Name ProxyServer -Value "" -ErrorAction Stop
            netsh winhttp reset proxy | Out-Null
            Write-Host "    [OK] WinINET proxy disabled for current user." -ForegroundColor Green
        }
        else {
            Write-Host "    [OK] No blocking local proxy detected." -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Host "    [WARN] Failed to inspect/adjust WinINET proxy: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host "  Pre-step: Stop Microsoft Store related processes ..." -ForegroundColor Yellow
    try {
        $runningStoreProcesses = Get-Process -Name $storeProcessNames -ErrorAction SilentlyContinue
        if ($runningStoreProcesses) {
            foreach ($proc in $runningStoreProcesses) {
                try {
                    Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                    Write-Host "    [OK] Stopped $($proc.ProcessName) (PID: $($proc.Id))" -ForegroundColor Green
                }
                catch {
                    Write-Host "    [WARN] Failed to stop $($proc.ProcessName): $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
            Start-Sleep -Seconds 2
        }
        else {
            Write-Host "    [INFO] No running Store-related processes found." -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Host "    [WARN] Failed to enumerate Store processes: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host "  Step A: Reset Microsoft Store cache (wsreset.exe) ..." -ForegroundColor Yellow
    try {
        $wsreset = Join-Path $env:WINDIR "System32\wsreset.exe"
        if (Test-Path $wsreset) {
            $p = Start-Process -FilePath $wsreset -PassThru -WindowStyle Hidden
            if ($p.WaitForExit(90000)) {
                Write-Host "    [OK] wsreset.exe finished (exit code: $($p.ExitCode))" -ForegroundColor Green
            }
            else {
                try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
                Write-Host "    [WARN] wsreset.exe timed out (>90s), continued with next step." -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "    [WARN] wsreset.exe not found, skipped cache reset." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "    [WARN] wsreset failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host "  Step B: Re-register Microsoft Store app package ..." -ForegroundColor Yellow
    $reRegisterOk = $false
    for ($attempt = 1; $attempt -le 3 -and -not $reRegisterOk; $attempt++) {
        if ($attempt -gt 1) {
            Write-Host "    [INFO] Retry re-register attempt $attempt/3 ..." -ForegroundColor Yellow
        }
        try {
            $runningStoreProcesses = Get-Process -Name $storeProcessNames -ErrorAction SilentlyContinue
            foreach ($proc in $runningStoreProcesses) {
                try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
            }

            $storePackage = Get-AppxPackage -Name "Microsoft.WindowsStore" -ErrorAction Stop | Select-Object -First 1
            if ($storePackage -and $storePackage.InstallLocation) {
                $manifestPath = Join-Path $storePackage.InstallLocation "AppxManifest.xml"
                if (Test-Path $manifestPath) {
                    Add-AppxPackage -DisableDevelopmentMode -Register $manifestPath -ErrorAction Stop | Out-Null
                    $reRegisterOk = $true
                    Write-Host "    [OK] Microsoft Store package re-registered." -ForegroundColor Green
                }
                else {
                    Write-Host "    [WARN] AppxManifest.xml not found, skipped re-register." -ForegroundColor Yellow
                    break
                }
            }
            else {
                Write-Host "    [WARN] Microsoft Store package not found." -ForegroundColor Yellow
                break
            }
        }
        catch {
            $errText = $_.Exception.Message
            if ($errText -match "0x80073D02") {
                Write-Host "    [WARN] Store is still in use (0x80073D02). Retrying after closing process..." -ForegroundColor Yellow
                Start-Sleep -Seconds 2
                continue
            }
            Write-Host "    [WARN] Re-register Microsoft Store failed: $errText" -ForegroundColor Yellow
            break
        }
    }
    if (-not $reRegisterOk) {
        Write-Host "    [WARN] Microsoft Store re-register did not complete successfully." -ForegroundColor Yellow
    }

    Write-Host "  Step C: Ensure Store dependency services are running ..." -ForegroundColor Yellow
    foreach ($svcName in @("InstallService", "ClipSVC", "AppXSvc", "BITS", "wuauserv")) {
        try {
            $svc = Get-Service -Name $svcName -ErrorAction Stop
            if ($svc.Status -ne "Running") {
                Start-Service -Name $svcName -ErrorAction Stop
                Write-Host "    [OK] Started service: $svcName" -ForegroundColor Green
            }
            else {
                Write-Host "    [OK] Service already running: $svcName" -ForegroundColor DarkGray
            }
        }
        catch {
            Write-Host "    [WARN] Service check/start failed for ${svcName}: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    Write-Host "  Step D: Test Microsoft Store URI protocol ..." -ForegroundColor Yellow
    try {
        Start-Process -FilePath $storeUri -ErrorAction Stop | Out-Null
        Write-Host "    [OK] Opened $storeUri" -ForegroundColor Green
    }
    catch {
        Write-Host "    [WARN] Failed to open $storeUri : $($_.Exception.Message)" -ForegroundColor Yellow
    }

    if (-not $reRegisterOk) {
        Write-Host "  Step E (fallback): Deep Store reset (cache cleanup + AllUsers register) ..." -ForegroundColor Yellow

        try {
            $runningStoreProcesses = Get-Process -Name $storeProcessNames -ErrorAction SilentlyContinue
            foreach ($proc in $runningStoreProcesses) {
                try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
        catch {
        }

        $storePackageFamily = "Microsoft.WindowsStore_8wekyb3d8bbwe"
        $storeDataRoot = Join-Path $env:LOCALAPPDATA ("Packages\" + $storePackageFamily)
        $cleanupTargets = @(
            (Join-Path $storeDataRoot "LocalCache"),
            (Join-Path $storeDataRoot "TempState"),
            (Join-Path $storeDataRoot "AC\INetCache")
        )

        foreach ($cleanupPath in $cleanupTargets) {
            try {
                if (Test-Path $cleanupPath) {
                    Get-ChildItem -Path $cleanupPath -Force -ErrorAction SilentlyContinue |
                        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Host "    [OK] Cleared cache path: $cleanupPath" -ForegroundColor Green
                }
            }
            catch {
                Write-Host "    [WARN] Failed to clear cache path ${cleanupPath}: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        $allUsersRegistered = $false
        try {
            $storePkgsAllUsers = @(Get-AppxPackage -AllUsers -Name "Microsoft.WindowsStore" -ErrorAction Stop)
            foreach ($pkg in $storePkgsAllUsers) {
                if ($pkg.InstallLocation) {
                    $manifestPath = Join-Path $pkg.InstallLocation "AppxManifest.xml"
                    if (Test-Path $manifestPath) {
                        Add-AppxPackage -DisableDevelopmentMode -Register $manifestPath -ErrorAction Stop | Out-Null
                        $allUsersRegistered = $true
                    }
                }
            }
            if ($allUsersRegistered) {
                Write-Host "    [OK] AllUsers Microsoft Store register completed." -ForegroundColor Green
            }
            else {
                Write-Host "    [WARN] AllUsers register skipped (no usable manifest found)." -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "    [WARN] AllUsers register failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        Write-Host "    [INFO] Fallback complete. Reboot is strongly recommended." -ForegroundColor Yellow
    }
}

function Run-Repair {
    param(
        [bool]$ChangeDns,
        [bool]$FixMicrosoftStoreLink
    )

    if (-not $script:IsWindowsOS) {
        Write-Section "Repair (not available on this OS)"
        Write-Host "  Automatic stack repair (ipconfig, netsh, Winsock) runs only on Windows." -ForegroundColor Yellow
        Write-Host "  macOS: try Network settings, VPN/proxy, or: sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder" -ForegroundColor DarkGray
        Write-Host "  Linux: check systemd-resolved / NetworkManager; flush DNS per your distro docs." -ForegroundColor DarkGray
        return
    }

    Write-Section "Running repair steps"
    $totalSteps = if ($FixMicrosoftStoreLink) { 7 } else { 6 }

    Write-Step -Number 1 -Total $totalSteps -Title "Flush DNS cache"
    ipconfig /flushdns | Out-Host

    Write-Step -Number 2 -Total $totalSteps -Title "Reset WinHTTP proxy"
    netsh winhttp reset proxy | Out-Host

    Write-Step -Number 3 -Total $totalSteps -Title "Reset Winsock (reboot usually required)"
    netsh winsock reset | Out-Host

    Write-Step -Number 4 -Total $totalSteps -Title "Reset TCP/IP stack (reboot usually required)"
    netsh int ip reset | Out-Host

    if ($ChangeDns) {
        Write-Step -Number 5 -Total $totalSteps -Title "Switch DNS to public resolvers"
        Set-PublicDnsForActiveAdapters
    }
    else {
        Write-Step -Number 5 -Total $totalSteps -Title "Skip DNS change"
        Write-Host "  DNS change skipped because -NoDnsChange was used" -ForegroundColor DarkGray
    }

    Write-Step -Number 6 -Total $totalSteps -Title "Fix Cursor proxy settings (http.proxySupport -> override)"
    $cursorSettingsPath = Join-Path $env:APPDATA "Cursor\User\settings.json"
    if (Test-Path $cursorSettingsPath) {
        try {
            $settingsContent = Get-Content -Path $cursorSettingsPath -Raw -Encoding UTF8
            $modified = $false

            if ($settingsContent -match '"http\.proxySupport"\s*:\s*"([^"]*)"') {
                $currentValue = $Matches[1]
                if ($currentValue -ne "override") {
                    $settingsContent = $settingsContent -replace '"http\.proxySupport"\s*:\s*"[^"]*"', '"http.proxySupport": "override"'
                    $modified = $true
                    Write-Host "  [OK] Changed http.proxySupport: `"$currentValue`" -> `"override`"" -ForegroundColor Green
                }
                else {
                    Write-Host "  [OK] http.proxySupport is already `"override`"" -ForegroundColor Green
                }
            }
            else {
                $settingsContent = $settingsContent -replace '^\{', "{`n    `"http.proxySupport`": `"override`","
                $modified = $true
                Write-Host "  [OK] Added http.proxySupport: `"override`" to Cursor settings" -ForegroundColor Green
            }

            if ($settingsContent -match '"http\.proxyStrictSSL"\s*:\s*(true)') {
                $settingsContent = $settingsContent -replace '"http\.proxyStrictSSL"\s*:\s*true', '"http.proxyStrictSSL": false'
                $modified = $true
                Write-Host "  [OK] Changed http.proxyStrictSSL: true -> false" -ForegroundColor Green
            }

            if ($modified) {
                Set-Content -Path $cursorSettingsPath -Value $settingsContent -Encoding UTF8 -NoNewline
            }

            Write-Host "  [NOTE] Restart Cursor for proxy changes to take effect" -ForegroundColor Yellow
        }
        catch {
            Write-Host "  [WARN] Failed to update Cursor settings: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "  Cursor settings.json not found at $cursorSettingsPath, skipping" -ForegroundColor DarkGray
    }

    if ($FixMicrosoftStoreLink) {
        Write-Step -Number 7 -Total $totalSteps -Title "Fix Microsoft Store link / connectivity"
        Repair-MicrosoftStoreLink
    }
}

$startedAt = Get-Date
$scriptDir = Split-Path -Parent $PSCommandPath
$logDir = Join-Path $scriptDir "logs"
if (-not (Test-Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory | Out-Null
}

$settings = Get-ToolSettings -ScriptDir $scriptDir
$targets = Get-StringArraySetting -Value $settings.targets -Fallback $script:DefaultTargets
$probeUri = Get-StringSetting -Value $settings.probe_url -Fallback $script:DefaultProbeUrl
$http2Targets = Get-StringArraySetting -Value $settings.diagnostics.cursorHttp2Targets -Fallback $script:DefaultCursorHttp2Targets
$fixMicrosoftStoreLinkAfterRepair = [bool]$OneClickFix
if (
    -not $OneClickFix -and
    $null -ne $settings -and
    $null -ne $settings.repairs -and
    $null -ne $settings.repairs.fixMicrosoftStoreLinkAfterRepair
) {
    $fixMicrosoftStoreLinkAfterRepair = [bool]$settings.repairs.fixMicrosoftStoreLinkAfterRepair
}
$installWrapperOnOneClick = $true
if ($null -ne $settings -and $null -ne $settings.integrations -and $null -ne $settings.integrations.cursorWrapper) {
    $cw = $settings.integrations.cursorWrapper
    if ($null -ne $cw.installOnOneClick -and $cw.installOnOneClick -eq $false) {
        $installWrapperOnOneClick = $false
    }
}

$script:SilentMode = [bool]($Silent -or ($env:CURSOR_NETWORK_REPAIR_SILENT -eq "1"))
$script:OneClickExeNotify = $null

if ($OneClickFix) {
    $ForceRepair = $true
}

if (-not $Doctor -and -not $ProbeHttp2 -and -not $InstallCursorWrapper) {
    Ensure-Admin
}

$timeTag = Get-Date -Format "yyyyMMdd-HHmmss"
$logBaseName = if ($Doctor) { "network-doctor" } elseif ($ProbeHttp2) { "network-http2" } elseif ($InstallCursorWrapper) { "network-wrapper" } elseif ($FixStoreOnlyNoReboot) { "store-fix" } else { "network-repair" }
$logPath = Join-Path $logDir "$logBaseName-$timeTag.log"

Start-Transcript -Path $logPath | Out-Null

try {
    try {
        $Host.UI.RawUI.WindowTitle = "Cursor Network Repair Assistant"
    }
    catch {
    }

    Initialize-ConsoleEncoding
    Set-ConsoleTheme
    Write-Banner
    Write-Section "Session"
    Write-InfoLine -Label "Started" -Value ((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
    $osDesc = try {
        [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    }
    catch {
        ("{0} ({1})" -f $env:OS, [System.Environment]::OSVersion.VersionString)
    }
    Write-InfoLine -Label "OS" -Value $osDesc
    Write-InfoLine -Label "PowerShell" -Value ("{0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
    Write-InfoLine -Label "Log file" -Value $logPath
    Write-InfoLine -Label "Mode" -Value $(if ($Doctor) { "doctor" } elseif ($ProbeHttp2) { "probe-http2" } elseif ($InstallCursorWrapper) { "install-cursor-wrapper" } elseif ($FixStoreOnlyNoReboot) { "fix-store-only-no-reboot" } elseif ($OneClickFix) { "one-click-fix" } else { "repair" })
    Write-InfoLine -Label "DNS change" -Value $(if ($NoDnsChange) { "Disabled" } else { "Enabled" })
    Write-InfoLine -Label "Force repair" -Value $(if ($ForceRepair) { "Enabled" } else { "Disabled" })
    Write-InfoLine -Label "Fix Store link" -Value $(if ($fixMicrosoftStoreLinkAfterRepair) { "Enabled" } else { "Disabled" })

    if ($InstallCursorWrapper) {
        Install-CursorWrapper -ScriptDir $scriptDir
        return
    }

    if ($FixStoreOnlyNoReboot) {
        Write-Section "Store-only repair (no reboot path)"
        Write-Host "  Running Microsoft Store repair only." -ForegroundColor White
        Write-Host "  Skipping Winsock/TCP reset and DNS changes." -ForegroundColor DarkGray
        Repair-MicrosoftStoreLink
        Write-Host ""
        Write-Host "Store-only repair finished. Try opening Microsoft Store now." -ForegroundColor Green
        return
    }

    if ($ProbeHttp2) {
        $http2Only = Test-Http2Targets -Targets $http2Targets
        Write-Http2Table -Rows $http2Only -Title "HTTP/2 probe (Cursor)"
        if (@($http2Only | Where-Object { $_.CanVerify -eq $false }).Count -gt 0) {
            exit 3
        }
        $api2Rows = @($http2Only | Where-Object { $_.Target -match "api2\.cursor\.sh" })
        $api2Ready = (@($api2Rows | Where-Object { $_.Ready }).Count -gt 0)
        $anyReady = (@($http2Only | Where-Object { $_.Ready }).Count -gt 0)
        if ($api2Rows.Count -gt 0 -and -not $api2Ready) {
            exit 2
        }
        if (-not $anyReady) {
            exit 2
        }
        return
    }

    if ($OneClickFix) {
        Write-Section "One-click preparation"
        if ($installWrapperOnOneClick) {
            try {
                Install-CursorWrapper -ScriptDir $scriptDir
            }
            catch {
                Write-Host "  [WARN] Failed to install cursor-company wrapper: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "  [INFO] Skipping cursor-company install (settings.json: integrations.cursorWrapper.installOnOneClick=false)." -ForegroundColor DarkGray
        }
    }

    $before = foreach ($target in $targets) { Test-Endpoint -HostName $target }
    Write-EndpointTable -Rows $before -Title "Pre-check"

    $api2Before = $before | Where-Object { $_.Host -eq "api2.cursor.sh" } | Select-Object -First 1
    $probeBefore = Get-CursorHttpsProbe -Uri $probeUri
    Write-HttpsProbeCard -Probe $probeBefore -Title "HTTPS probe (Cursor API)"
    Write-CursorHttpsInterpretation -Probe $probeBefore -Api2TcpRow $api2Before

    $orTcpBefore = $before | Where-Object { $_.Host -eq "openrouter.ai" } | Select-Object -First 1
    $orProbeBefore = Get-OpenRouterHttpsProbe
    Write-HttpsProbeCard -Probe $orProbeBefore -Title "HTTPS probe (OpenRouter API, Claude Code)"
    Write-OpenRouterHttpsInterpretation -Probe $orProbeBefore -OpenRouterTcpRow $orTcpBefore

    $wrapperStatus = Get-CursorWrapperStatus -ScriptDir $scriptDir
    Write-CursorWrapperCard -WrapperStatus $wrapperStatus

    $http2Before = Test-Http2Targets -Targets $http2Targets
    Write-Http2Table -Rows $http2Before -Title "HTTP/2 readiness (Cursor)"
    $http2CanVerify = (@($http2Before | Where-Object { $_.CanVerify -eq $false }).Count -eq 0)
    $http2Ready = (@($http2Before | Where-Object { $_.Ready }).Count -gt 0)

    if ($Doctor) {
        $doctorPath = Join-Path $logDir "network-doctor-$timeTag.json"
        $doctorLatestPath = Join-Path $logDir "network-doctor-latest.json"
        $doctorBody = [ordered]@{
            generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            mode = "doctor"
            probeUrl = $probeUri
            endpointChecks = $before
            cursorHttpsProbe = $probeBefore
            cursorWrapper = $wrapperStatus
            cursorHttp2Readiness = [ordered]@{
                ok = $http2Ready
                canVerify = $http2CanVerify
                targets = $http2Before
            }
        }
        Write-DoctorJson -Path $doctorPath -Body $doctorBody
        Write-DoctorJson -Path $doctorLatestPath -Body $doctorBody
        Write-Section "Doctor artifacts"
        Write-InfoLine -Label "Report" -Value $doctorPath
        Write-InfoLine -Label "Latest" -Value $doctorLatestPath
        $failCountDoctor = ($before | Where-Object { -not $_.Passed }).Count
        Write-FinalSummary -FailCount $failCountDoctor -Probe $probeBefore
        return
    }

    $beforeFailCount = ($before | Where-Object { -not $_.Passed }).Count
    if ($beforeFailCount -eq 0 -and -not $ForceRepair) {
        Write-Host ""
        Write-Host "All TCP/DNS checks passed. No stack repair needed." -ForegroundColor Green
        Write-Host "Use -ForceRepair if you still want to run repair." -ForegroundColor DarkGray
        Write-Host "If Cursor still shows 'region' errors, that is account/provider policy, not local TCP." -ForegroundColor DarkGray
        Write-FinalSummary -FailCount $beforeFailCount -Probe $probeBefore
    }
    else {
        if ($beforeFailCount -eq 0) {
            Write-Host "-ForceRepair enabled. Running repair..." -ForegroundColor Yellow
        }
        else {
            Write-Host "$beforeFailCount target(s) failed. Running repair..." -ForegroundColor Yellow
        }

        Run-Repair -ChangeDns:(-not $NoDnsChange) -FixMicrosoftStoreLink:$fixMicrosoftStoreLinkAfterRepair

        $after = foreach ($target in $targets) { Test-Endpoint -HostName $target }
        Write-EndpointTable -Rows $after -Title "Post-check"

        $api2After = $after | Where-Object { $_.Host -eq "api2.cursor.sh" } | Select-Object -First 1
        $probeAfter = Get-CursorHttpsProbe -Uri $probeUri
        Write-HttpsProbeCard -Probe $probeAfter -Title "HTTPS probe (Cursor API) after repair"
        Write-CursorHttpsInterpretation -Probe $probeAfter -Api2TcpRow $api2After

        $orTcpAfter = $after | Where-Object { $_.Host -eq "openrouter.ai" } | Select-Object -First 1
        $orProbeAfter = Get-OpenRouterHttpsProbe
        Write-HttpsProbeCard -Probe $orProbeAfter -Title "HTTPS probe (OpenRouter API) after repair"
        Write-OpenRouterHttpsInterpretation -Probe $orProbeAfter -OpenRouterTcpRow $orTcpAfter

        $http2After = Test-Http2Targets -Targets $http2Targets
        Write-Http2Table -Rows $http2After -Title "HTTP/2 readiness (Cursor) after repair"

        $afterFailCount = ($after | Where-Object { -not $_.Passed }).Count
        Write-Host ""
        if ($afterFailCount -eq 0) {
            Write-Host "Repair result: all targets passed." -ForegroundColor Green
        }
        else {
            Write-Host "Repair result: $afterFailCount target(s) still failing." -ForegroundColor Red
            Write-Host "Check local proxy, firewall, corporate gateway, or ISP filtering." -ForegroundColor Yellow
        }

        Write-Host ""
        if ($script:IsWindowsOS) {
            Write-Host "Note: Winsock/TCP-IP reset usually needs a reboot to fully apply." -ForegroundColor Yellow
        }
        Write-FinalSummary -FailCount $afterFailCount -Probe $probeAfter

        if ($OneClickFix) {
            $oneClickIssues = @()
            $api2Rows = @($http2After | Where-Object { $_.Target -match "api2\.cursor\.sh" })
            $api2Ready = (@($api2Rows | Where-Object { $_.Ready }).Count -gt 0)
            $anyReady = (@($http2After | Where-Object { $_.Ready }).Count -gt 0)
            if ($afterFailCount -gt 0) {
                $oneClickIssues += "TCP/DNS checks still failing on $afterFailCount target(s)."
            }
            if ($api2Rows.Count -gt 0 -and -not $api2Ready) {
                $oneClickIssues += "api2.cursor.sh did not negotiate HTTP/2."
            }
            elseif (-not $anyReady) {
                $oneClickIssues += "No HTTP/2-ready target was detected."
            }

            if ($oneClickIssues.Count -gt 0) {
                Write-Section "One-click result"
                Write-Host "  [FAILED] One-click fix cannot guarantee full recovery yet." -ForegroundColor Red
                foreach ($issue in $oneClickIssues) {
                    Write-Host "  - $issue" -ForegroundColor Yellow
                }
                if ($script:SilentMode -and ($env:CURSOR_NETWORK_REPAIR_LAUNCHED_FROM_EXE -eq "1") -and (Test-ShowTrayBalloonOnExeFinish -ToolSettings $settings)) {
                    $script:OneClickExeNotify = @{
                        Title  = "Cursor network repair"
                        Body   = "One-click could not verify recovery. See src\logs for details."
                        IsError = $true
                    }
                }
                exit 20
            }

            Write-Section "One-click result"
            Write-Host "  [OK] One-click fix completed and key HTTP/2 gate passed." -ForegroundColor Green
            if ($env:CURSOR_NETWORK_REPAIR_LAUNCHED_FROM_EXE -eq "1") {
                if ($script:SilentMode -and (Test-ShowTrayBalloonOnExeFinish -ToolSettings $settings)) {
                    $script:OneClickExeNotify = @{
                        Title   = "Cursor network repair"
                        Body    = "One-click fix completed successfully."
                        IsError = $false
                    }
                }
                if ((-not $script:SilentMode) -and (Test-LaunchClaudeCodeOnExeSuccess -ToolSettings $settings)) {
                    Start-ClaudeCodeWithOpenRouterEnv -ScriptRoot $scriptDir
                }
            }
        }
    }

    $elapsed = (Get-Date) - $startedAt
    Write-Host ""
    Write-Host ("Completed in {0:mm\:ss}" -f $elapsed) -ForegroundColor White
}
finally {
    Stop-Transcript | Out-Null
    try {
        if ($script:SilentMode -and $OneClickFix -and ($env:CURSOR_NETWORK_REPAIR_LAUNCHED_FROM_EXE -eq "1") -and (Test-ShowTrayBalloonOnExeFinish -ToolSettings $settings)) {
            if ($null -ne $script:OneClickExeNotify) {
                Show-NetworkRepairTrayBalloon -Title $script:OneClickExeNotify.Title -Body $script:OneClickExeNotify.Body -IsError $script:OneClickExeNotify.IsError
            }
        }
    }
    catch {
    }
    if ($OneClickFix -and -not $env:CURSOR_NETWORK_REPAIR_LAUNCHED_FROM_EXE -and -not $script:SilentMode) {
        Write-Host ""
        Write-Host "Press Enter to exit..." -ForegroundColor Cyan
        $null = Read-Host
    }
}
