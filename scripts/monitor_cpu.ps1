param(
    [string]$Profile = 'read',
    [int]$Users = 30,
    [int]$Run = 1,
    [int]$DurationSeconds = 300,
    [int]$SampleIntervalSeconds = 5,
    [string]$OutputCsv = 'results/raw/cpu.csv',
    [string[]]$ServiceNames = @('customers-service', 'vets-service')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$resolvedOutput = Join-Path $root $OutputCsv
$resolvedOutputDir = Split-Path -Parent $resolvedOutput
New-Item -ItemType Directory -Force -Path $resolvedOutputDir | Out-Null

if ($ServiceNames -is [string]) {
    $ServiceNames = ($ServiceNames -split ',') | ForEach-Object { $_.Trim() }
}

$start = Get-Date
$records = @()
$serviceState = @{}

function Get-DockerCpuRecord {
    param([string]$ServiceName)
    $result = docker stats --no-stream --format '{{.Name}},{{.CPUPerc}}' 2>$null
    if (-not $result) { return $null }
    foreach ($line in ($result -split "`r?`n")) {
        if ($line -match "^${ServiceName},") {
            $parts = $line.Split(',')
            if ($parts.Count -ge 2) {
                $cpu = ($parts[1] -replace '%', '').Trim()
                return [double]$cpu
            }
        }
    }
    return $null
}

function Get-LocalJvmCpuRecord {
    param(
        [string]$ServiceName,
        [hashtable]$State,
        [int]$IntervalSeconds
    )

    $servicePorts = @{
        'customers-service' = 8081
        'visits-service' = 8082
        'vets-service' = 8083
        'api-gateway' = 8080
        'discovery-server' = 8761
        'config-server' = 8888
    }
    $port = $servicePorts[$ServiceName]
    if (-not $port) { return $null }

    # Resolve the JVM by its listening port. This avoids Win32_Process/CIM,
    # which is commonly blocked for non-elevated users on Windows.
    $pids = netstat -ano -p TCP | Select-String "LISTENING\s+\d+$" | ForEach-Object {
        $parts = ($_.Line.Trim() -split '\s+')
        if ($parts.Count -ge 5 -and $parts[1] -match ":${port}$") {
            [int]$parts[4]
        }
    } | Select-Object -Unique

    foreach ($processId in $pids) {
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if (-not $process) { continue }

        $key = $ServiceName + ':' + $processId
        $now = Get-Date
        $nowCpu = $process.TotalProcessorTime
        $prev = $State[$key]

        if ($prev) {
            $deltaSeconds = ($now - $prev.Timestamp).TotalSeconds
            $deltaCpuSeconds = ($nowCpu - $prev.CpuTime).TotalSeconds
            if ($deltaSeconds -gt 0) {
                $estimated = (($deltaCpuSeconds / $deltaSeconds) * 100) / [Environment]::ProcessorCount
                $State[$key] = @{ Timestamp = $now; CpuTime = $nowCpu }
                return [double][math]::Max(0, [math]::Min(100, $estimated))
            }
        }

        $State[$key] = @{ Timestamp = $now; CpuTime = $nowCpu }
    }

    return $null
}

while ((Get-Date) -lt ($start.AddSeconds($DurationSeconds))) {
    foreach ($service in $ServiceNames) {
        $cpuValue = $null
        if (Get-Command docker -ErrorAction SilentlyContinue) {
            try {
                $cpuValue = Get-DockerCpuRecord -ServiceName $service
            } catch {
                $cpuValue = $null
            }
        }
        if ($null -eq $cpuValue) {
            $cpuValue = Get-LocalJvmCpuRecord -ServiceName $service -State $serviceState -IntervalSeconds $SampleIntervalSeconds
        }
        if ($null -eq $cpuValue) {
            $cpuValue = 0.0
        }
        $timestamp = (Get-Date).ToString('o')
        $cpuPercent = [math]::Round([double]$cpuValue, 2)
        $cpuPercentText = $cpuPercent.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
        $records += [pscustomobject]@{
            timestamp = $timestamp
            profile = $Profile
            users = $Users
            run = $Run
            service = $service
            cpu_percent = $cpuPercentText
        }
    }
    Start-Sleep -Seconds $SampleIntervalSeconds
}

if ($records.Count -gt 0) {
    $records | Export-Csv -NoTypeInformation -Path $resolvedOutput
    Write-Host "CPU metrics saved to $resolvedOutput"
} else {
    throw 'No CPU samples were collected. Ensure the application is running or Docker is available.'
}
