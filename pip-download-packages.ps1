Import-Module "$PSScriptRoot/logging-utils.psm1" -Force

$eventSource = "pip-download-packages"
$eventLogName = "Application"

$originalLocation = Get-Location

function Exit-WithCleanup {
    param([string]$message)

    if ($message) { Write-Error $message }
    if ($message) {
        Write-FailureEvent -Message $message
    } else {
        Write-FailureEvent -Message "pip-download-packages.ps1 failed without a specific error message."
    }
    Set-Location $originalLocation
    exit 1
}

function Ensure-PyLauncher {
    if (Get-Command py.exe -ErrorAction SilentlyContinue) { return }

    Exit-WithCleanup "py.exe not found. Please ensure Python Launcher for Windows is installed."
}

function Get-PySelector {
    param([string]$version)
    "-$version"
}

function Get-PipPythonVersion {
    param([string]$version)
    $version.Replace('.', '')
}

function Normalize-PackageName {
    param([string]$name)
    $name.ToLower() -replace '[-_.]+', '-'
}

function Get-PackageArtifacts {
    param(
        [string]$Name,
        [string]$Version,
        [string]$Directory
    )

    $normalizedName = Normalize-PackageName $Name
    $files = Get-ChildItem -Path $Directory -File -ErrorAction SilentlyContinue
    $matching = foreach ($file in $files) {
        if ($file.Name -notmatch '^(.+?)-([0-9][0-9A-Za-z\.]*)(?:-[^-]+)*\.(tar\.gz|zip|whl)$') { continue }

        $fileName = $matches[1]
        $fileVersion = $matches[2]
        $normalizedFileName = Normalize-PackageName $fileName

        if ($normalizedFileName -eq $normalizedName -and $fileVersion -eq $Version) {
            $file
        }
    }

    $matching | Sort-Object -Property Name
}

function Format-PackageEntry {
    param($PackageEntry)

    "$($PackageEntry.PythonVersion): $($PackageEntry.Requirement)"
}

function Parse-RequirementEntry {
    param(
        [string]$Line,
        [string[]]$SupportedVersions
    )

    $trimmed = $Line.Trim()
    if (-not $trimmed) { return $null }
    if ($trimmed.StartsWith('#')) { return $null }

    if ($trimmed -notmatch '^(?<version>3\.\d+)\s*:\s*(?<requirement>.+)$') {
        Exit-WithCleanup "Invalid requirement format (expected '3.x: package==version'): $Line"
    }

    $version = $matches['version']
    $requirement = $matches['requirement'].Trim()

    if (-not $SupportedVersions -contains $version) {
        Exit-WithCleanup "Unsupported Python version '$version' in requirements file. Supported versions: $($SupportedVersions -join ', ')"
    }

    if (-not $requirement) {
        Exit-WithCleanup "Requirement is missing for Python ${version}: $Line"
    }

    [PSCustomObject]@{
        PythonVersion = $version
        Requirement    = $requirement
    }
}

function Write-DownloadSummaryEvent {
    param(
        [string]$PythonVersionSummary,
        [int]$RequestedCount,
        [int]$InitialFailureCount,
        [int]$PostRetryFailureCount,
        [int]$MissingArtifactCount
    )

    $summary = "pip-download-packages.ps1 completed ($PythonVersionSummary). " +
        "Requested: $RequestedCount. " +
        "Initial failures: $InitialFailureCount. " +
        "Failures after retry: $PostRetryFailureCount. " +
        "Missing artifacts: $MissingArtifactCount. " +
        "Please re-run integrity-check.ps1 baseline."

    Write-Log -Message $summary -Level INFO -ToEventLog -LogName $eventLogName -EventSource $eventSource -EventId 1000 -SkipSourceCreationErrors
}

function Write-FailureEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Message
    )

    Write-Log -Message $Message -Level ERROR -ToEventLog -LogName $eventLogName -EventSource $eventSource -EventId 1001 -SkipSourceCreationErrors
}

function Invoke-DownloadPhase {
    param(
        [object[]]$Packages,
        [ScriptBlock]$DownloadScript,
        [int]$MaxJobs,
        [string]$PhaseLabel
    )

    Write-Host "`n$PhaseLabel`n"

    $jobs = @()
    $total = $Packages.Count
    $index = 0

    foreach ($pkg in $Packages) {
        $index++

        while ((Get-Job -State Running).Count -ge $MaxJobs) {
            Start-Sleep -Milliseconds 200
        }

        $job = Start-Job -ScriptBlock $DownloadScript -ArgumentList $pkg
        $job | Add-Member -NotePropertyName Package -NotePropertyValue $pkg
        $jobs += $job

        Write-Host "[$index/$total] Queued: $(Format-PackageEntry $pkg) (Active: $((Get-Job -State Running).Count))"
    }

    Write-Host "`nWaiting for downloads to complete..."
    Get-Job | Wait-Job | Out-Null

    $failures = @()
    foreach ($job in $jobs) {
        $result = Receive-Job $job
        $hasDownloadError = $result.ExitCode -ne 0 -or $result.Output -match "ERROR|Could not find|No matching distribution"

        if ($hasDownloadError) {
            $artifactExists = $false

            if ($job.Package.Requirement -match '^(?<name>[^=<>!~\s]+?)(?:\[.*\])?==(?<version>[^\s;]+)') {
                $artifactMatches = Get-PackageArtifacts -Name $matches['name'] -Version $matches['version'] -Directory $outputDir
                if ($artifactMatches.Count -gt 0) { $artifactExists = $true }
            }

            if ($artifactExists) {
                Write-Host "Download reported errors but artifacts found: $(Format-PackageEntry $job.Package)" -ForegroundColor Yellow
                continue
            }

            $failures += $job.Package
            Write-Host "Download failed: $(Format-PackageEntry $job.Package)" -ForegroundColor Yellow
        }
    }

    Get-Job | Remove-Job
    return $failures
}

Ensure-PyLauncher

$supportedPythonVersions = @('3.7', '3.8', '3.9', '3.10', '3.11', '3.12', '3.13')

$requirementsFile = "C:\admin\package-management\pip_requirements_multi_version.txt"
# Each non-comment line must follow the format "3.11: package==version" to specify the interpreter used for downloading.
if (-not (Test-Path $requirementsFile)) {
    Exit-WithCleanup "Requirements file not found at $requirementsFile"
}

$rawRequirementLines = Get-Content $requirementsFile
$packages = @(foreach ($line in $rawRequirementLines) {
    Parse-RequirementEntry -Line $line -SupportedVersions $supportedPythonVersions
}) | Where-Object { $_ }

if ($packages.Count -eq 0) {
    Exit-WithCleanup "No requirements found in $requirementsFile after ignoring blank and comment lines."
}

$uniqueVersions = $packages | Select-Object -ExpandProperty PythonVersion -Unique | Sort-Object {[version]$_}
$pythonVersionSummary = "Per-line versions enforced: $($uniqueVersions -join ', ')"

Write-Host $pythonVersionSummary

foreach ($version in $uniqueVersions) {
    $pySelector = Get-PySelector $version
    & py $pySelector --version 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Exit-WithCleanup "Python $version is not installed. Please install it before running this script."
    }
}

# Disable pip.ini temporarily
Remove-Item "C:\ProgramData\pip\pip.ini.disabled" -Force -ErrorAction SilentlyContinue
Rename-Item "C:\ProgramData\pip\pip.ini" "C:\ProgramData\pip\pip.ini.disabled" -ErrorAction SilentlyContinue

New-Item -Path "C:\admin\pip_mirror" -ItemType Directory -Force | Out-Null
Set-Location "C:\admin\pip_mirror"
$outputDir = "C:\admin\pip_mirror"
$maxJobs = 15

$pySelectorFunc = ${function:Get-PySelector}
$pipPythonVersionFunc = ${function:Get-PipPythonVersion}
$existsAction = 's'

Write-Host "Using pip --exists-action $existsAction (skip existing files) for downloads."

$downloadJob = {
    param($package)
    ${function:Get-PySelector} = $using:pySelectorFunc
    ${function:Get-PipPythonVersion} = $using:pipPythonVersionFunc

    $pySelector = Get-PySelector $package.PythonVersion
    $pipPythonVersion = Get-PipPythonVersion $package.PythonVersion
    $result = & py $pySelector -m pip download $package.Requirement `
        -d $using:outputDir `
        --platform win_amd64 `
        --python-version $pipPythonVersion `
        --only-binary=:all: `
        --exists-action $using:existsAction 2>&1
    return @{ ExitCode = $LASTEXITCODE; Output = $result }
}

$failedPackages = Invoke-DownloadPhase -Packages $packages -DownloadScript $downloadJob -MaxJobs $maxJobs -PhaseLabel "Phase 1: Downloading binary wheels..."
$initialWheelFailureCount = $failedPackages.Count

$retryFailures = @()
if ($failedPackages.Count -gt 0) {
    $sourceJob = {
        param($package)
        ${function:Get-PySelector} = $using:pySelectorFunc
        ${function:Get-PipPythonVersion} = $using:pipPythonVersionFunc

        $pySelector = Get-PySelector $package.PythonVersion
        & py $pySelector -m pip download $package.Requirement -d $using:outputDir --exists-action $using:existsAction 2>&1 | Out-Null
        return @{ ExitCode = $LASTEXITCODE; Output = "" }
    }

    $retryFailures = Invoke-DownloadPhase -Packages $failedPackages -DownloadScript $sourceJob -MaxJobs $maxJobs -PhaseLabel "Phase 2: Retrying failed packages with source builds allowed..."
} else {
    Write-Host "`nAll packages downloaded successfully with binary wheels!" -ForegroundColor Green
}

function Get-PackageNameFromRequirement {
    param([string]$requirementLine)

    $trimmed = ($requirementLine -split ';')[0].Trim()
    if (-not $trimmed) { return $null }

    if ($trimmed.StartsWith('-')) { return $null }

    if ($trimmed -match '^([A-Za-z0-9_.-]+)') {
        return Normalize-PackageName $matches[1]
    }

    return $null
}

function PackageHasArtifactsInDirectory {
    param(
        $Package,
        [string[]]$ArtifactNames
    )

    $normalizedName = Get-PackageNameFromRequirement $Package.Requirement
    if (-not $normalizedName) { return $false }

    return $ArtifactNames -contains $normalizedName
}

$artifactNames = Get-ChildItem $outputDir -File | ForEach-Object {
    $base = ($_.Name -split '-')[0]
    Normalize-PackageName $base
} | Sort-Object -Unique

$failedPackages = $failedPackages | Where-Object { -not (PackageHasArtifactsInDirectory -Package $_ -ArtifactNames $artifactNames) }
$retryFailures = $retryFailures | Where-Object { -not (PackageHasArtifactsInDirectory -Package $_ -ArtifactNames $artifactNames) }

$requirementEntries = $packages
$missingPackages = @()
foreach ($entry in $requirementEntries) {
    $normalizedName = Get-PackageNameFromRequirement $entry.Requirement
    if (-not $normalizedName) { continue }

    if (-not ($artifactNames -contains $normalizedName)) {
        $missingPackages += $entry
    }
}


if ($retryFailures.Count -gt 0 -or $missingPackages.Count -gt 0) {

    if ($retryFailures.Count -gt 0) {
        $failedDescriptions = $retryFailures | ForEach-Object { Format-PackageEntry $_ }
        Write-Warning "Some packages failed to download after retry: $($failedDescriptions -join ', ')"
    }

    if ($missingPackages.Count -gt 0) {
        $missingDescriptions = $missingPackages | ForEach-Object { Format-PackageEntry $_ }
        Write-Warning "Missing downloaded artifacts for: $($missingDescriptions -join ', ')"
        Write-Warning "Packages without artifacts:"
        $missingPackages | ForEach-Object { Write-Warning " - $(Format-PackageEntry $_)" }
    }
} else {
    Write-Host "All packages downloaded and verified."
}

Write-Host "Download process complete."

$requestedCount = $requirementEntries.Count
$initialFailureCount = $initialWheelFailureCount
$postRetryFailureCount = $retryFailures.Count
$missingArtifactCount = $missingPackages.Count

Write-DownloadSummaryEvent `
    -PythonVersionSummary $pythonVersionSummary `
    -RequestedCount $requestedCount `
    -InitialFailureCount $initialFailureCount `
    -PostRetryFailureCount $postRetryFailureCount `
    -MissingArtifactCount $missingArtifactCount

Set-Location $originalLocation
