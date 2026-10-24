param(
    [ValidateSet('all', 'read', 'write')]
    [string]$Profile = 'all',
    [ValidateSet('30', '80', '150')]
    [string]$Users = '30',
    [ValidateRange(1, 10)]
    [int]$Run = 1,
    [string]$Host = 'http://localhost:8080',
    [int]$DurationSeconds = 360,
    [int]$SpawnRate = 2,
    [switch]$ShortValidation
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$locustDir = Join-Path $root 'locust'
$resultsRoot = Join-Path $root 'results\raw'

if (-not (Test-Path (Join-Path $locustDir 'locustfile.py'))) {
    throw 'locustfile.py not found. Run this script from the repository root.'
}

if ($ShortValidation) {
    $Users = '5'
    $DurationSeconds = 30
    $Run = 1
    $SpawnRate = 2
}

$profilesToRun = if ($Profile -eq 'all') { @('read', 'write') } else { @($Profile) }

foreach ($profile in $profilesToRun) {
    $thisClass = switch ($profile) {
        'read' { 'ReadProfile' }
        'write' { 'WriteProfile' }
    }
    $folderName = if ($ShortValidation) { 'validacao' } elseif ($profile -eq 'read') { 'leitura' } else { 'escrita' }
    $thisFolder = Join-Path $resultsRoot $folderName
    $thisFolder = Join-Path $thisFolder "$Users-users"
    New-Item -ItemType Directory -Force -Path $thisFolder | Out-Null
    $thisCsv = Join-Path $thisFolder "${profile}_${Users}_run$(('{0:02d}' -f $Run))"

    Write-Host "Running $profile profile with $Users users (run $Run)"
    Push-Location $locustDir
    python -m locust --headless --host $Host -u $Users -r $SpawnRate -t "${DurationSeconds}s" --csv $thisCsv "$thisClass"
    Pop-Location
    if ($LASTEXITCODE -ne 0) { throw "Locust failed while running $profile profile" }
}

Write-Host "Experiment output saved in $resultsRoot"
