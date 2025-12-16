function Test-EventLogSource {
    param(
        [string]$LogName = 'Application',
        [Parameter(Mandatory = $true)][string]$EventSource,
        [switch]$SkipOnError
    )

    try {
        if ([System.Diagnostics.EventLog]::SourceExists($EventSource)) { return $true }
    }
    catch {
        if (-not $SkipOnError) { throw }

        Write-Warning "Unable to query event source '$EventSource'. Skipping event log entry."
        return $false
    }

    try {
        New-EventLog -LogName $LogName -Source $EventSource -ErrorAction Stop
        return $true
    }
    catch {
        if (-not $SkipOnError) { throw }

        Write-Warning "Unable to create event source '$EventSource'. Skipping event log entry."
        return $false
    }
}

function Write-EventLogRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('Information', 'Warning', 'Error')][string]$EntryType = 'Information',
        [string]$LogName = 'Application',
        [Parameter(Mandatory = $true)][string]$EventSource,
        [hashtable]$EventIds,
        [int]$EventId,
        [switch]$SkipSourceCreationErrors
    )

    if (-not (Test-EventLogSource -LogName $LogName -EventSource $EventSource -SkipOnError:$SkipSourceCreationErrors)) { return }

    $resolvedEventId = 0
    if ($PSBoundParameters.ContainsKey('EventId')) {
        $resolvedEventId = $EventId
    }
    elseif ($EventIds -and $EventIds.ContainsKey($EntryType)) {
        $resolvedEventId = $EventIds[$EntryType]
    }

    Write-EventLog -LogName $LogName -Source $EventSource -EntryType $EntryType -EventId $resolvedEventId -Message $Message
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [switch]$ToEventLog,
        [string]$LogName = 'Application',
        [string]$EventSource,
        [hashtable]$EventIds,
        [int]$EventId,
        [switch]$SkipSourceCreationErrors
    )

    $color = switch ($Level) {
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'Gray' }
    }

    Write-Host "[$Level] $Message" -ForegroundColor $color

    if ($ToEventLog) {
        $entryType = switch ($Level) {
            'WARN' { 'Warning' }
            'ERROR' { 'Error' }
            default { 'Information' }
        }

        $eventLogParams = @{
            Message                   = $Message
            EntryType                 = $entryType
            LogName                   = $LogName
            EventSource               = $EventSource
            EventIds                  = $EventIds
            SkipSourceCreationErrors  = $SkipSourceCreationErrors
        }

        if ($PSBoundParameters.ContainsKey('EventId')) {
            $eventLogParams['EventId'] = $EventId
        }

        Write-EventLogRecord @eventLogParams
    }
}

Export-ModuleMember -Function Write-Log, Write-EventLogRecord, Test-EventLogSource
