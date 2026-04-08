param(
    [switch]$NoDnsChange,
    [switch]$ForceRepair
)

$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSEdition -eq "Desktop") {
    $script:IsWindowsOS = $true
}
else {
    $script:IsWindowsOS = [bool]$IsWindows
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
    Write-Host "  Checks DNS, TCP 443, HTTPS policy hints, and network stack health." -ForegroundColor Gray
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
    if ($haystack -match 'region|does not serve|not available|unsupported country|unavailable in your|doesn''t serve') {
        $result.LooksLikeRegionBlock = $true
    }

    [PSCustomObject]$result
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
        Write-Host "TCP to api2.cursor.sh is OK but HTTP suggests policy/region. Local DNS/stack repair may NOT fix Cursor 'Model not available / region'." -ForegroundColor Yellow
        Write-Host "See: https://cursor.com/docs/account/regions" -ForegroundColor White
        Write-Host "Check Cursor account, billing region, and provider availability for your region." -ForegroundColor DarkGray
    }
    elseif ($Api2TcpRow -and $Api2TcpRow.Passed -and -not $Probe.LooksLikeRegionBlock) {
        Write-Host "No obvious region signal in this probe. If Cursor still shows region errors, read the regions doc above anyway." -ForegroundColor DarkGray
    }
}

function Set-PublicDnsForActiveAdapters {
    Write-Host "Setting DNS on active adapters to 1.1.1.1 / 8.8.8.8 ..." -ForegroundColor Yellow
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.HardwareInterface -eq $true }
    foreach ($adapter in $adapters) {
        try {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses @("1.1.1.1", "8.8.8.8")
            Write-Host "  [OK] $($adapter.Name)" -ForegroundColor Green
        }
        catch {
            Write-Host "  [FAILED] $($adapter.Name): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function Run-Repair {
    param([bool]$ChangeDns)

    if (-not $script:IsWindowsOS) {
        Write-Section "Repair (not available on this OS)"
        Write-Host "  Automatic stack repair (ipconfig, netsh, Winsock) runs only on Windows." -ForegroundColor Yellow
        Write-Host "  macOS: try Network settings, VPN/proxy, or: sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder" -ForegroundColor DarkGray
        Write-Host "  Linux: check systemd-resolved / NetworkManager; flush DNS per your distro docs." -ForegroundColor DarkGray
        return
    }

    Write-Section "Running repair steps"
    $totalSteps = 6

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
}

Ensure-Admin

$startedAt = Get-Date
$scriptDir = Split-Path -Parent $PSCommandPath
$logDir = Join-Path $scriptDir "logs"
if (-not (Test-Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory | Out-Null
}

$timeTag = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $logDir "network-repair-$timeTag.log"

Start-Transcript -Path $logPath | Out-Null

try {
    try {
        $Host.UI.RawUI.WindowTitle = "Cursor Network Repair Assistant"
    }
    catch {
    }

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
    Write-InfoLine -Label "DNS change" -Value $(if ($NoDnsChange) { "Disabled" } else { "Enabled" })
    Write-InfoLine -Label "Force repair" -Value $(if ($ForceRepair) { "Enabled" } else { "Disabled" })

    $targets = @(
        "api.openai.com",
        "chat.openai.com",
        "api.anthropic.com",
        "claude.ai",
        "api2.cursor.sh",
        "api.cursor.sh"
    )

    $before = foreach ($target in $targets) { Test-Endpoint -HostName $target }
    Write-EndpointTable -Rows $before -Title "Pre-check"

    $api2Before = $before | Where-Object { $_.Host -eq "api2.cursor.sh" } | Select-Object -First 1
    $probeBefore = Get-CursorHttpsProbe
    Write-HttpsProbeCard -Probe $probeBefore -Title "HTTPS probe (Cursor API)"
    Write-CursorHttpsInterpretation -Probe $probeBefore -Api2TcpRow $api2Before

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

        Run-Repair -ChangeDns:(-not $NoDnsChange)

        $after = foreach ($target in $targets) { Test-Endpoint -HostName $target }
        Write-EndpointTable -Rows $after -Title "Post-check"

        $api2After = $after | Where-Object { $_.Host -eq "api2.cursor.sh" } | Select-Object -First 1
        $probeAfter = Get-CursorHttpsProbe
        Write-HttpsProbeCard -Probe $probeAfter -Title "HTTPS probe (Cursor API) after repair"
        Write-CursorHttpsInterpretation -Probe $probeAfter -Api2TcpRow $api2After

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
    }

    $elapsed = (Get-Date) - $startedAt
    Write-Host ""
    Write-Host ("Completed in {0:mm\:ss}" -f $elapsed) -ForegroundColor White
}
finally {
    Stop-Transcript | Out-Null
}
