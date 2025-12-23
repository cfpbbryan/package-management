<#
.SYNOPSIS
    Validates that R is configured for offline lockdown.

.DESCRIPTION
    Confirms that the R client lockdown settings written by
    `r-client-lockdown.ps1` are present. The script checks the contents of
    Rprofile.site and Renviron.site in the R etc directory and ensures the
    R bin directory is present in the system PATH. The script writes a Windows
    event log entry for both success and failure so administrators can audit
    compliance.

.EXAMPLE
    # Validate R lockdown
    .\r-client-lockdown-check.ps1
#>

[CmdletBinding()]
param(
    [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

            $basePath = if ([string]::IsNullOrWhiteSpace($wordToComplete)) {
                '.'
            }
            elseif (Test-Path -LiteralPath $wordToComplete -PathType Container) {
                $wordToComplete
            }
            else {
                $parent = Split-Path -Path $wordToComplete -Parent
                if ([string]::IsNullOrWhiteSpace($parent)) { '.' } else { $parent }
            }

            $leaf = if ([string]::IsNullOrWhiteSpace($wordToComplete)) { '' } else { Split-Path -Path $wordToComplete -Leaf }

            Get-ChildItem -Directory -Path $basePath -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "$leaf*" } |
                ForEach-Object {
                    [System.Management.Automation.CompletionResult]::new(
                        $_.FullName,
                        $_.Name,
                        'ParameterValue',
                        $_.FullName)
                }
        })]
    [string]$RInstallPath = "",
    [switch]$Log
)

$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/logging-utils.psm1" -Force

$eventLogConfig = @{
    LogName     = 'Application'
    EventSource = 'RClientLockdownCheck'
    EventIds    = @{
        Information = 1000
        Error       = 1001
    }
    SkipSourceCreationErrors = $true
}
$eventLogEnabled = $Log.IsPresent

function Write-EventLogIfEnabled {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('Information', 'Warning', 'Error')][string]$EntryType = 'Information'
    )

    if (-not $eventLogEnabled) { return }

    Write-EventLogRecord @eventLogConfig -Message $Message -EntryType $EntryType
}

function Register-RClientLockdownCheckCompleters {
    param([string]$ScriptPath = $PSCommandPath)

    $commandInfo = Get-Command -Name $ScriptPath -CommandType ExternalScript -ErrorAction SilentlyContinue
    if (-not $commandInfo) { return }

    $parameters = $commandInfo.Parameters
    if (-not $parameters -or -not $parameters.ContainsKey('RInstallPath')) { return }

    $completer = $parameters['RInstallPath'].Attributes |
        Where-Object { $_ -is [System.Management.Automation.ArgumentCompleterAttribute] } |
        Select-Object -First 1

    if (-not $completer) { return }

    $scriptName = Split-Path -Path $ScriptPath -Leaf
    $commandNames = @(
        $scriptName
        ".\\$scriptName"
        "./$scriptName"
        $ScriptPath
        $commandInfo.Source
        $commandInfo.Definition
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    if (-not $commandNames) { return }

    Register-ArgumentCompleter -CommandName $commandNames -ParameterName 'RInstallPath' -ScriptBlock $completer.ScriptBlock
}

function Write-ConsoleLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $color = switch ($Level) {
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'Gray' }
    }

    Write-Host "[$Level] $Message" -ForegroundColor $color
}

function Write-OutcomeEvent {
    param(
        [string]$Message,
        [bool]$Success
    )

    if ($Success) {
        Write-EventLogIfEnabled -Message $Message -EntryType 'Information'
    }
    else {
        Write-EventLogIfEnabled -Message $Message -EntryType 'Error'
    }
}

function Convert-ToForwardSlashPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }

    return ($Path -replace '\\', '/')
}

function Resolve-RInstallPath {
    param([string]$ProvidedPath)

    if (-not [string]::IsNullOrWhiteSpace($ProvidedPath)) {
        $resolvedPath = (Resolve-Path -Path $ProvidedPath -ErrorAction Stop).ProviderPath
        $candidatePath = Get-RVersionChildPath -RootPath $resolvedPath
        if ($candidatePath) { return $candidatePath }
        return $resolvedPath
    }

    if (-not [string]::IsNullOrWhiteSpace($env:R_HOME) -and (Test-Path -Path $env:R_HOME -PathType Container)) {
        return (Resolve-Path -Path $env:R_HOME -ErrorAction Stop).ProviderPath
    }

    $registryPaths = @(
        'HKLM:/SOFTWARE/R-core/R',
        'HKLM:/SOFTWARE/WOW6432Node/R-core/R'
    )

    foreach ($registryPath in $registryPaths) {
        try {
            $installPath = (Get-ItemProperty -Path $registryPath -Name InstallPath -ErrorAction Stop).InstallPath
        }
        catch {
            $installPath = $null
        }

        if (-not [string]::IsNullOrWhiteSpace($installPath) -and (Test-Path -Path $installPath -PathType Container)) {
            return (Resolve-Path -Path $installPath -ErrorAction Stop).ProviderPath
        }
    }

    $defaultRoots = @(
        'C:/Program Files/R',
        'C:/Program Files (x86)/R'
    )

    foreach ($root in $defaultRoots) {
        if (-not (Test-Path -Path $root -PathType Container)) { continue }

        $candidate = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
            Sort-Object -Property Name -Descending |
            Select-Object -First 1

        if ($candidate) { return $candidate.FullName }
    }

    return $null
}

function Get-RVersionChildPath {
    param([string]$RootPath)

    if ([string]::IsNullOrWhiteSpace($RootPath)) { return $null }

    $etcPath = Join-Path -Path $RootPath -ChildPath 'etc'
    if (Test-Path -Path $etcPath -PathType Container) { return $null }

    $candidate = Get-ChildItem -Path $RootPath -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^R-\d' } |
        Sort-Object -Property Name -Descending |
        Select-Object -First 1

    if ($candidate) { return $candidate.FullName }

    return $null
}

function Test-PathContainsEntry {
    param(
        [string]$PathEntry,
        [string]$SystemPath
    )

    if ([string]::IsNullOrWhiteSpace($PathEntry)) { return $false }
    if ([string]::IsNullOrWhiteSpace($SystemPath)) { return $false }

    $normalize = {
        param([string]$Item)
        if ([string]::IsNullOrWhiteSpace($Item)) { return $null }
        $trimmed = $Item.Trim().TrimEnd('\', '/')
        if ([string]::IsNullOrWhiteSpace($trimmed)) { return $null }
        return ($trimmed -replace '/', '\')
    }

    $normalizedEntry = & $normalize $PathEntry
    if (-not $normalizedEntry) { return $false }

    $systemEntries = $SystemPath -split ';' | ForEach-Object { & $normalize $_ } | Where-Object { $_ }
    return ($systemEntries | Where-Object { $_ -ieq $normalizedEntry }).Count -gt 0
}

Register-RClientLockdownCheckCompleters

try {
    $resolvedInstallPath = Resolve-RInstallPath -ProvidedPath $RInstallPath

    if ([string]::IsNullOrWhiteSpace($resolvedInstallPath)) {
        $errorMessage = 'Unable to locate the R installation directory. Provide a valid path with -RInstallPath.'
        Write-ConsoleLog $errorMessage 'ERROR'
        throw $errorMessage
    }

    $resolvedInstallPath = Convert-ToForwardSlashPath $resolvedInstallPath
    $etcDirectory = Convert-ToForwardSlashPath ([System.IO.Path]::Combine($resolvedInstallPath, 'etc'))
    $rProfilePath = Convert-ToForwardSlashPath ([System.IO.Path]::Combine($etcDirectory, 'Rprofile.site'))
    $rEnvironPath = Convert-ToForwardSlashPath ([System.IO.Path]::Combine($etcDirectory, 'Renviron.site'))

    $issues = @()

    Write-ConsoleLog "Validating R lockdown configuration in $etcDirectory" 'INFO'

    if (-not (Test-Path -Path $rProfilePath -PathType Leaf)) {
        $issues += [PSCustomObject]@{ Issue = 'MissingFile'; Detail = $rProfilePath }
        Write-ConsoleLog "Missing: $rProfilePath" 'ERROR'
    }
    else {
        $profileLines = Get-Content -Path $rProfilePath -ErrorAction Stop
        $profilePattern = '^\s*options\(\s*repos\s*=\s*c\(\s*CRAN\s*=\s*"file:///c:/admin/r_mirror"\s*\)\s*,\s*pkgType\s*=\s*"binary"\s*\)\s*$'
        $hasProfileLine = $profileLines | Where-Object { $_ -match $profilePattern }

        if (-not $hasProfileLine) {
            $issues += [PSCustomObject]@{ Issue = 'MissingLine'; Detail = 'options(repos = c(CRAN = "file:///c:/admin/r_mirror"), pkgType = "binary")' }
            Write-ConsoleLog 'Missing lockdown line in Rprofile.site.' 'ERROR'
        }
    }

    if (-not (Test-Path -Path $rEnvironPath -PathType Leaf)) {
        $issues += [PSCustomObject]@{ Issue = 'MissingFile'; Detail = $rEnvironPath }
        Write-ConsoleLog "Missing: $rEnvironPath" 'ERROR'
    }
    else {
        $environLines = Get-Content -Path $rEnvironPath -ErrorAction Stop
        $environPattern = '^\s*R_REPOS_OVERRIDE\s*=\s*1\s*$'
        $hasEnvironLine = $environLines | Where-Object { $_ -match $environPattern }

        if (-not $hasEnvironLine) {
            $issues += [PSCustomObject]@{ Issue = 'MissingLine'; Detail = 'R_REPOS_OVERRIDE=1' }
            Write-ConsoleLog 'Missing R_REPOS_OVERRIDE=1 in Renviron.site.' 'ERROR'
        }
    }

    $systemPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $rBinPath = [System.IO.Path]::Combine($resolvedInstallPath, 'bin')
    if (-not (Test-PathContainsEntry -PathEntry $rBinPath -SystemPath $systemPath)) {
        $issues += [PSCustomObject]@{ Issue = 'MissingPathEntry'; Detail = $rBinPath }
        Write-ConsoleLog "System PATH missing R bin entry: $rBinPath" 'ERROR'
    }
    else {
        Write-ConsoleLog "System PATH contains R bin entry: $rBinPath" 'INFO'
    }

    $summary = "R lockdown validation complete for $etcDirectory. Missing items: $($issues.Count)."
    Write-ConsoleLog $summary 'INFO'

    if ($issues.Count -eq 0) {
        Write-OutcomeEvent -Message 'R lockdown validation PASSED with no discrepancies.' -Success $true
        $global:LASTEXITCODE = 0
    }
    else {
        $failureMessage = "R lockdown validation FAILED with $($issues.Count) issue(s)."
        Write-OutcomeEvent -Message $failureMessage -Success $false
        $global:LASTEXITCODE = 1
        exit $global:LASTEXITCODE
    }
}
catch {
    $errorMessage = "Lockdown check encountered an error: $($_.Exception.Message)"
    Write-OutcomeEvent -Message $errorMessage -Success $false
    Write-ConsoleLog $errorMessage 'ERROR'
    $global:LASTEXITCODE = 1
    exit $global:LASTEXITCODE
}
