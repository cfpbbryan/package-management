<#
.SYNOPSIS
    Validates that pip is configured for offline lockdown.

.DESCRIPTION
    Runs `py -m pip config list` and confirms that pip is locked down by
    checking for the `global.find-links` and `global.no-index` values that
    `pip-client-lockdown.ps1` sets. The contents of the mirror itself are not
    inspected—only the presence of the lockdown configuration in pip.ini. The
    script writes a Windows event log entry for both success and failure so
    administrators can audit compliance.

.PARAMETER PythonLauncher
    Python launcher executable to invoke. Defaults to `py`.

.EXAMPLE
    # Validate pip lockdown using the default Python launcher
    .\lockdown-check.ps1

.EXAMPLE
    # Validate pip lockdown using a specific Python launcher
    .\lockdown-check.ps1 -PythonLauncher "C:\\Python311\\python.exe"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][string]$PythonLauncher = "py"
)

$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/logging-utils.psm1" -Force

$eventLogConfig = @{
    LogName     = 'Application'
    EventSource = 'PipClientLockdownCheck'
    EventIds    = @{
        Information = 1000
        Error       = 1001
    }
    SkipSourceCreationErrors = $true
}

function Convert-ToFileUri {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path.TrimEnd([System.IO.Path]::DirectorySeparatorChar, '/'))
    return ([System.Uri]::new($fullPath)).AbsoluteUri
}

function Get-PipConfigValues {
    param([string]$PythonLauncher)

    $output = & $PythonLauncher -m pip config list

    $findLinks = $null
    $noIndex = $null

    foreach ($line in $output) {
        if ($line -match '^global\.find-links=(.+)$') {
            $findLinks = $Matches[1].Trim('"', "'")
        }
        elseif ($line -match '^global\.no-index=(.+)$') {
            $noIndex = $Matches[1].Trim('"', "'")
        }
    }

    return [PSCustomObject]@{
        FindLinks = $findLinks
        NoIndex   = $noIndex
        RawOutput = $output -join "`n"
    }
}

function Write-OutcomeEvent {
    param(
        [string]$Message,
        [bool]$Success
    )

    $level = if ($Success) { 'INFO' } else { 'ERROR' }
    Write-Log -Message $Message -Level $level -ToEventLog -LogName $eventLogConfig.LogName -EventSource $eventLogConfig.EventSource -EventIds $eventLogConfig.EventIds -SkipSourceCreationErrors:$eventLogConfig.SkipSourceCreationErrors
}

try {
    $expectedFindLinks = Convert-ToFileUri -Path "C:\\admin\\pip_mirror"
    $config = Get-PipConfigValues -PythonLauncher $PythonLauncher

    $issues = @()

    if (-not $config.FindLinks) {
        $issues += 'global.find-links is missing from pip config.'
    }
    elseif ($config.FindLinks -ne $expectedFindLinks) {
        $issues += "global.find-links is '$($config.FindLinks)', expected '$expectedFindLinks'."
    }

    if (-not $config.NoIndex) {
        $issues += 'global.no-index is missing from pip config.'
    }
    elseif ($config.NoIndex -notin @('true', 'True')) {
        $issues += "global.no-index is '$($config.NoIndex)', expected 'true'."
    }

    if ($issues.Count -eq 0) {
        $successMessage = "pip.ini is locked down (find-links=$($config.FindLinks); no-index=$($config.NoIndex))."
        Write-OutcomeEvent -Message $successMessage -Success $true
    }
    else {
        $failureMessage = "pip.ini lockdown validation failed; issues: $(($issues -join ' ')) Output: $($config.RawOutput)"
        Write-OutcomeEvent -Message $failureMessage -Success $false
        throw $failureMessage
    }
}
catch {
    $errorMessage = "Lockdown check encountered an error: $($_.Exception.Message)"
    Write-OutcomeEvent -Message $errorMessage -Success $false
    throw
}
