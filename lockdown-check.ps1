<#
.SYNOPSIS
    Validates that pip is configured for offline lockdown.

.DESCRIPTION
    Confirms that pip is locked down by verifying the presence of pip.ini at
    C:\ProgramData\pip and the lockdown lines written by
    `pip-client-lockdown.ps1`. The contents of the mirror itself are not
    inspected—only the presence of the lockdown configuration in pip.ini. The
    script writes a Windows event log entry for both success and failure so
    administrators can audit compliance.

.EXAMPLE
    # Validate pip lockdown
    .\lockdown-check.ps1
#>

[CmdletBinding()]
param(
    [switch]$Log
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

    if (-not $Log) { return }

    $level = if ($Success) { 'INFO' } else { 'ERROR' }

    Write-Log $Message $level -ToEventLog -LogName $eventLogConfig.LogName -EventSource $eventLogConfig.EventSource -EventIds $eventLogConfig.EventIds -SkipSourceCreationErrors:$eventLogConfig.SkipSourceCreationErrors
}

try {
    $configPath = 'C:\\ProgramData\\pip\\pip.ini'
    $environmentVariableName = 'PIP_NO_INDEX'
    $expectedEnvironmentValue = '1'

    $issues = @()

    Write-ConsoleLog "Validating pip.ini lockdown configuration at $configPath" 'INFO'

    if (-not (Test-Path -Path $configPath -PathType Leaf)) {
        $issues += [PSCustomObject]@{ Issue = 'MissingFile'; Detail = $configPath }
        Write-ConsoleLog "Missing: $configPath" 'ERROR'
    }
    else {
        $actualLines = Get-Content -Path $configPath -ErrorAction Stop

        $hasGlobalSection = $actualLines -contains '[global]'
        $hasFindLinks = $actualLines | Where-Object { $_ -match '^\s*find-links\s*=' }
        $hasNoIndexTrue = $actualLines | Where-Object { $_ -match '^\s*no-index\s*=\s*true\s*$' }

        if (-not $hasGlobalSection) {
            $issues += [PSCustomObject]@{ Issue = 'MissingLine'; Detail = '[global]' }
            Write-ConsoleLog "Missing line: [global]" 'ERROR'
        }

        if (-not $hasFindLinks) {
            $issues += [PSCustomObject]@{ Issue = 'MissingLine'; Detail = 'find-links = <value>' }
            Write-ConsoleLog 'Missing line: find-links entry' 'ERROR'
        }

        if (-not $hasNoIndexTrue) {
            $issues += [PSCustomObject]@{ Issue = 'MissingLine'; Detail = 'no-index = true' }
            Write-ConsoleLog "Missing line: no-index = true" 'ERROR'
        }
    }

    $actualEnvValue = [System.Environment]::GetEnvironmentVariable($environmentVariableName, 'Machine')
    if ([string]::IsNullOrWhiteSpace($actualEnvValue)) {
        $issues += [PSCustomObject]@{ Issue = 'MissingEnvironmentVariable'; Detail = $environmentVariableName }
        Write-ConsoleLog "Missing environment variable: $environmentVariableName (Machine scope)" 'ERROR'
    }
    elseif ($actualEnvValue.Trim() -ne $expectedEnvironmentValue) {
        $issues += [PSCustomObject]@{ Issue = 'UnexpectedEnvironmentValue'; Detail = "$environmentVariableName=$actualEnvValue" }
        Write-ConsoleLog "Unexpected $environmentVariableName value: '$actualEnvValue' (expected '$expectedEnvironmentValue')" 'ERROR'
    }
    else {
        Write-ConsoleLog "$environmentVariableName is set correctly at Machine scope." 'INFO'
    }

    $summary = "pip.ini lockdown validation complete for $configPath. Missing items: $($issues.Count)."
    Write-ConsoleLog $summary 'INFO'

    if ($issues.Count -eq 0) {
        Write-OutcomeEvent -Message 'pip.ini lockdown validation PASSED with no discrepancies.' -Success $true
        $global:LASTEXITCODE = 0
    }
    else {
        $failureMessage = "pip.ini lockdown validation FAILED with $($issues.Count) issue(s)."
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
