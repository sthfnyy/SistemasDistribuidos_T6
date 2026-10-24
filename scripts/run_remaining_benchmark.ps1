param(
    [string]$BaseUrl = 'http://localhost:8080',
    [int]$DurationSeconds = 360,
    [int]$WarmupSeconds = 60,
    [int]$SpawnRate = 2,
    [int]$PauseSeconds = 15
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$rawRoot = Join-Path $root 'results\raw'
$progressLog = Join-Path $root 'results\benchmark-progress.log'
$petclinicRoot = Join-Path $root 'petclinic'
$java = 'C:\Program Files\Microsoft\jdk-17.0.20.101-hotspot\bin\java.exe'
$python = 'C:\Users\sthef\AppData\Local\Programs\Python\Python311\python.exe'
$startedProcesses = [System.Collections.Generic.List[object]]::new()

function Write-ProgressLog([string]$Message) {
    $line = '[{0}] {1}' -f (Get-Date).ToString('o'), $Message
    Add-Content -LiteralPath $progressLog -Value $line
    Write-Host $line
}

function Test-Healthy([int]$Port) {
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:$Port/actuator/health" -UseBasicParsing -TimeoutSec 5
        return $response.StatusCode -eq 200
    } catch {
        return $false
    }
}

function Wait-Healthy([int]$Port, [int]$TimeoutSeconds = 120) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-Healthy $Port) { return }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw "Health check timeout on port $Port"
}

function Start-ServiceIfNeeded([string]$Module, [int]$Port, [string]$Name) {
    if (Test-Healthy $Port) { return }
    $jar = Get-ChildItem (Join-Path $petclinicRoot "spring-petclinic-$Module\target\*.jar") |
        Where-Object { $_.Name -notmatch 'sources|javadoc|original' } |
        Select-Object -First 1
    if (-not $jar) { throw "Executable JAR not found for $Module" }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $process = Start-Process -FilePath $java `
        -ArgumentList @(
            '-jar', $jar.FullName, "--server.port=$Port",
            '--logging.level.org.springframework.web=OFF',
            '--logging.level.org.springframework.core=OFF',
            '--logging.level.org.springframework.http=OFF',
            '--logging.level.org.springframework.cloud=OFF',
            '--logging.level.reactor=OFF',
            '--logging.level.com.netflix=ERROR'
        ) `
        -RedirectStandardOutput (Join-Path $petclinicRoot "logs\$Name-benchmark-$stamp.log") `
        -RedirectStandardError (Join-Path $petclinicRoot "logs\$Name-benchmark-$stamp.err.log") `
        -PassThru -WindowStyle Hidden
    $startedProcesses.Add($process)
    Wait-Healthy $Port
}

function Ensure-Environment {
    Start-ServiceIfNeeded 'config-server' 8888 'config-server'
    Start-ServiceIfNeeded 'discovery-server' 8761 'discovery-server'
    Start-ServiceIfNeeded 'customers-service' 8081 'customers-service'
    Start-ServiceIfNeeded 'visits-service' 8082 'visits-service'
    Start-ServiceIfNeeded 'vets-service' 8083 'vets-service'
    Start-ServiceIfNeeded 'api-gateway' 8080 'api-gateway'

    foreach ($port in @(8888, 8761, 8081, 8082, 8083, 8080)) {
        Wait-Healthy $port 30
    }

    $requiredApps = @('API-GATEWAY', 'CUSTOMERS-SERVICE', 'VETS-SERVICE')
    $eurekaDeadline = (Get-Date).AddSeconds(120)
    do {
        $eureka = Invoke-RestMethod -Uri 'http://localhost:8761/eureka/apps' `
            -Headers @{ Accept = 'application/json' } -TimeoutSec 10
        $up = @(
            $eureka.applications.application |
                Where-Object { @($_.instance).status -contains 'UP' } |
                ForEach-Object { $_.name }
        )
        $missingApps = @($requiredApps | Where-Object { $_ -notin $up })
        if ($missingApps.Count -eq 0) { break }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $eurekaDeadline)
    if ($missingApps.Count -gt 0) {
        throw "Eureka registration timeout: $($missingApps -join ', ')"
    }

    foreach ($path in @('/api/customer/owners', '/api/customer/owners/1', '/api/vet/vets')) {
        $endpointDeadline = (Get-Date).AddSeconds(120)
        $endpointReady = $false
        do {
            try {
                $response = Invoke-WebRequest -Uri ($BaseUrl + $path) -UseBasicParsing -TimeoutSec 15
                $endpointReady = $response.StatusCode -eq 200
            } catch {
                $endpointReady = $false
            }
            if (-not $endpointReady) { Start-Sleep -Seconds 3 }
        } while (-not $endpointReady -and (Get-Date) -lt $endpointDeadline)
        if (-not $endpointReady) { throw "Endpoint readiness timeout: $path" }
    }
}

function Get-RunPaths([string]$Profile, [int]$Users, [int]$Run) {
    $folderName = if ($Profile -eq 'read') { 'leitura' } else { 'escrita' }
    $folder = Join-Path $rawRoot "$folderName\$Users-users"
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $stem = '{0}_{1}_run{2:00}' -f $Profile, $Users, $Run
    return [pscustomobject]@{
        Folder = $folder
        Prefix = Join-Path $folder $stem
        Cpu = Join-Path $rawRoot ("cpu_{0}_{1}_run{2:00}.csv" -f $Profile, $Users, $Run)
        Stdout = Join-Path $folder "$stem.log"
        Stderr = Join-Path $folder "$stem.err.log"
    }
}

function Test-RunValid([string]$Profile, [int]$Users, [int]$Run) {
    $paths = Get-RunPaths $Profile $Users $Run
    $statsPath = $paths.Prefix + '_stats.csv'
    $historyPath = $paths.Prefix + '_stats_history.csv'
    $failuresPath = $paths.Prefix + '_failures.csv'
    $exceptionsPath = $paths.Prefix + '_exceptions.csv'
    foreach ($path in @($statsPath, $historyPath, $failuresPath, $exceptionsPath, $paths.Cpu)) {
        if (-not (Test-Path -LiteralPath $path)) { return $false }
    }
    try {
        $aggregateStats = Import-Csv $statsPath | Where-Object { $_.Name -eq 'Aggregated' } | Select-Object -Last 1
        if (-not $aggregateStats -or [int]$aggregateStats.'Request Count' -le 0) { return $false }
        $history = @(Import-Csv $historyPath | Where-Object { $_.Name -eq 'Aggregated' })
        if ($history.Count -lt 2) { return $false }
        $hasReset = $false
        for ($index = 1; $index -lt $history.Count; $index++) {
            if ([int]$history[$index].'Total Request Count' -lt [int]$history[$index - 1].'Total Request Count') {
                $hasReset = $true
                break
            }
        }
        if (-not $hasReset) { return $false }
        $cpuRows = @(Import-Csv $paths.Cpu)
        if ($cpuRows.Count -eq 0) { return $false }
        foreach ($service in @('customers-service', 'vets-service')) {
            if (-not ($cpuRows | Where-Object { $_.service -eq $service } | Select-Object -First 1)) { return $false }
        }
        return $true
    } catch {
        return $false
    }
}

function Archive-FailedAttempt([object]$Paths, [int]$Attempt) {
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $candidates = @(
        $Paths.Prefix + '_stats.csv',
        $Paths.Prefix + '_stats_history.csv',
        $Paths.Prefix + '_failures.csv',
        $Paths.Prefix + '_exceptions.csv',
        $Paths.Cpu,
        $Paths.Stdout,
        $Paths.Stderr
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) {
            Move-Item -LiteralPath $path -Destination ($path + ".failed-attempt$Attempt-$stamp")
        }
    }
}

function Invoke-OneRun([string]$Profile, [int]$Users, [int]$Run, [int]$Attempt) {
    $paths = Get-RunPaths $Profile $Users $Run
    $userClass = if ($Profile -eq 'read') { 'ReadProfile' } else { 'WriteProfile' }
    if ($Attempt -eq 1) {
        $existingOutputs = @(
            $paths.Prefix + '_stats.csv', $paths.Prefix + '_stats_history.csv',
            $paths.Prefix + '_failures.csv', $paths.Prefix + '_exceptions.csv',
            $paths.Cpu, $paths.Stdout, $paths.Stderr
        ) | Where-Object { Test-Path -LiteralPath $_ }
        if ($existingOutputs.Count -gt 0) { Archive-FailedAttempt $paths 0 }
    }
    $cpuProcess = $null
    $locustProcess = $null
    try {
        Ensure-Environment
        Write-ProgressLog "[START] $Profile $Users run$('{0:00}' -f $Run) attempt$Attempt"
        $cpuProcess = Start-Process powershell -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'monitor_cpu.ps1'),
            '-Profile', $Profile, '-Users', "$Users", '-Run', "$Run",
            '-DurationSeconds', "$DurationSeconds", '-SampleIntervalSeconds', '5',
            '-OutputCsv', ("results/raw/cpu_{0}_{1}_run{2:00}.csv" -f $Profile, $Users, $Run)
        ) -PassThru -WindowStyle Hidden

        $env:LOCUST_WARMUP_SECONDS = "$WarmupSeconds"
        $relativePrefix = "..\results\raw\$($(if ($Profile -eq 'read') {'leitura'} else {'escrita'}))\$Users-users\$Profile`_$Users`_run$('{0:00}' -f $Run)"
        $locustProcess = Start-Process -FilePath $python -ArgumentList @(
            '-m', 'locust', '--headless', '--host', $BaseUrl,
            '-u', "$Users", '-r', "$SpawnRate", '-t', "${DurationSeconds}s",
            '--csv', $relativePrefix, $userClass
        ) -WorkingDirectory (Join-Path $root 'locust') `
          -RedirectStandardOutput $paths.Stdout -RedirectStandardError $paths.Stderr `
          -PassThru -WindowStyle Hidden

        $runDeadline = (Get-Date).AddSeconds($DurationSeconds + 70)
        while (-not $locustProcess.HasExited -and (Get-Date) -lt $runDeadline) {
            $currentDrive = [System.IO.DriveInfo]::new((Split-Path -Qualifier $root))
            if ($currentDrive.AvailableFreeSpace -lt 64MB) {
                Stop-Process -Id $locustProcess.Id -Force -ErrorAction SilentlyContinue
                Stop-Process -Id $cpuProcess.Id -Force -ErrorAction SilentlyContinue
                throw 'Disk safety threshold reached during run'
            }
            Start-Sleep -Seconds 5
            $locustProcess.Refresh()
        }
        if (-not $locustProcess.HasExited) {
            Stop-Process -Id $locustProcess.Id -Force -ErrorAction SilentlyContinue
            throw 'Locust timeout'
        }
        if (-not $cpuProcess.WaitForExit(45000)) {
            Stop-Process -Id $cpuProcess.Id -Force -ErrorAction SilentlyContinue
            throw 'CPU monitor timeout'
        }
        $locustProcess.Refresh()
        $cpuProcess.Refresh()
        if ($null -ne $locustProcess.ExitCode -and $locustProcess.ExitCode -ne 0) {
            throw "Locust exit code $($locustProcess.ExitCode)"
        }
        if ($null -ne $cpuProcess.ExitCode -and $cpuProcess.ExitCode -ne 0) {
            throw "CPU monitor exit code $($cpuProcess.ExitCode)"
        }
        if (-not (Test-RunValid $Profile $Users $Run)) { throw 'Output validation failed' }
        Write-ProgressLog "[OK] $Profile $Users run$('{0:00}' -f $Run)"
        return $true
    } catch {
        if ($locustProcess -and -not $locustProcess.HasExited) {
            Stop-Process -Id $locustProcess.Id -Force -ErrorAction SilentlyContinue
        }
        if ($cpuProcess -and -not $cpuProcess.HasExited) {
            Stop-Process -Id $cpuProcess.Id -Force -ErrorAction SilentlyContinue
        }
        Write-ProgressLog "[FAILED] $Profile $Users run$('{0:00}' -f $Run) attempt$Attempt - $($_.Exception.Message)"
        Archive-FailedAttempt $paths $Attempt
        return $false
    } finally {
        Remove-Item Env:LOCUST_WARMUP_SECONDS -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Path -LiteralPath $java)) { throw "Java not found: $java" }
if (-not (Test-Path -LiteralPath $python)) { throw "Python not found: $python" }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $progressLog) | Out-Null
$drive = [System.IO.DriveInfo]::new((Split-Path -Qualifier $root))
if ($drive.AvailableFreeSpace -lt 128MB) {
    throw "Insufficient disk space: $([math]::Round($drive.AvailableFreeSpace / 1GB, 2)) GB free"
}
Write-ProgressLog "[PRECHECK] Disk free: $([math]::Round($drive.AvailableFreeSpace / 1GB, 2)) GB"

$scenarios = @(
    [pscustomobject]@{ Profile = 'read'; Users = 30; Runs = 2..10 },
    [pscustomobject]@{ Profile = 'read'; Users = 80; Runs = 1..10 },
    [pscustomobject]@{ Profile = 'read'; Users = 150; Runs = 1..10 },
    [pscustomobject]@{ Profile = 'write'; Users = 30; Runs = 1..10 },
    [pscustomobject]@{ Profile = 'write'; Users = 80; Runs = 1..10 },
    [pscustomobject]@{ Profile = 'write'; Users = 150; Runs = 1..10 }
)

try {
    Ensure-Environment
    if (-not (Test-RunValid 'read' 30 1)) { throw 'Existing read/30/run01 is not valid' }
    Write-ProgressLog '[SKIPPED] read 30 run01 - valid existing result'

    $postPayload = @{
        firstName = 'Benchmark'
        lastName = 'Preflight'
        address = 'Validation Street'
        city = 'Fortaleza'
        telephone = [string](Get-Random -Minimum 1000000000 -Maximum 1999999999)
    } | ConvertTo-Json
    $post = Invoke-WebRequest -Uri "$BaseUrl/api/customer/owners" -Method Post `
        -Body $postPayload -ContentType 'application/json' -UseBasicParsing -TimeoutSec 15
    if ($post.StatusCode -notin @(200, 201)) { throw 'POST endpoint preflight failed' }

    foreach ($scenario in $scenarios) {
        foreach ($run in $scenario.Runs) {
            if (Test-RunValid $scenario.Profile $scenario.Users $run) {
                Write-ProgressLog "[SKIPPED] $($scenario.Profile) $($scenario.Users) run$('{0:00}' -f $run) - valid existing result"
                continue
            }
            $completed = Invoke-OneRun $scenario.Profile $scenario.Users $run 1
            if (-not $completed) {
                Write-ProgressLog "[RETRY] $($scenario.Profile) $($scenario.Users) run$('{0:00}' -f $run)"
                $completed = Invoke-OneRun $scenario.Profile $scenario.Users $run 2
            }
            if (-not $completed) {
                Write-ProgressLog "[FAILED-FINAL] $($scenario.Profile) $($scenario.Users) run$('{0:00}' -f $run)"
            }
            Start-Sleep -Seconds $PauseSeconds
        }
    }
} finally {
    foreach ($process in $startedProcesses) {
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-ProgressLog '[COMPLETE] Remaining benchmark loop finished'
& $python (Join-Path $PSScriptRoot 'process_results.py')
if ($LASTEXITCODE -ne 0) {
    Write-ProgressLog '[FAILED] Final result processing failed'
    throw 'Final result processing failed'
}
Write-ProgressLog '[OK] Final result processing completed'
