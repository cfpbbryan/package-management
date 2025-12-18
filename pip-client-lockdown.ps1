$logName = "Application"
$eventSource = "PipClientLockdown"
$informationEventId = 1000

Import-Module "$PSScriptRoot/logging-utils.psm1" -Force

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
    [string]$MirrorPath = "C:\admin\pip_mirror"
)

$eventLogConfig = @{
    LogName                  = $logName
    EventSource              = $eventSource
    EventIds                 = @{ Information = $informationEventId }
    SkipSourceCreationErrors = $true
}

function Register-PipClientLockdownCompleters {
    param([string]$ScriptPath = $PSCommandPath)

    $commandInfo = Get-Command -Name $ScriptPath -CommandType ExternalScript -ErrorAction SilentlyContinue
    if (-not $commandInfo) { return }

    $parameters = $commandInfo.Parameters
    if (-not $parameters.ContainsKey('MirrorPath')) { return }

    $completer = $parameters['MirrorPath'].Attributes |
        Where-Object { $_ -is [System.Management.Automation.ArgumentCompleterAttribute] } |
        Select-Object -First 1

    if (-not $completer) { return }

    $scriptName = Split-Path -Path $ScriptPath -Leaf
    Register-ArgumentCompleter -CommandName $scriptName -ParameterName 'MirrorPath' -ScriptBlock $completer.ScriptBlock
    Register-ArgumentCompleter -CommandName $ScriptPath -ParameterName 'MirrorPath' -ScriptBlock $completer.ScriptBlock
}

Register-PipClientLockdownCompleters

function Write-SummaryEvent {
    param(
        [bool]$CreatedPipDirectory,
        [bool]$RestoredPipIni,
        [string]$ConfigPath,
        [string]$MirrorPath
    )

    if (-not (Test-EventLogSource -LogName $eventLogConfig.LogName -EventSource $eventLogConfig.EventSource -SkipOnError:$eventLogConfig.SkipSourceCreationErrors)) { return }

    $directoryStatus = if ($CreatedPipDirectory) { "created pip config directory" } else { "pip config directory already existed" }
    $pipIniStatus = if ($RestoredPipIni) { "restored existing pip.ini before writing new configuration" } else { "no pip.ini.disabled file to restore" }
    $summary = "pip-client-lockdown.ps1 locked pip to $MirrorPath; $directoryStatus; $pipIniStatus; wrote $ConfigPath with find-links and no-index."

    Write-EventLogRecord @eventLogConfig -Message $summary -EntryType Information
}

$mirrorPath = [System.IO.Path]::GetFullPath($MirrorPath)
$configDirectory = "C:\ProgramData\pip"
$configPath = "$configDirectory\pip.ini"

$mirrorPathExists = Test-Path $mirrorPath
if (-not $mirrorPathExists) {
    $errorMessage = "Mirror path '$mirrorPath' does not exist. Provide an existing path with -MirrorPath."
    Write-Error $errorMessage
    throw $errorMessage
}

try {
    $createdPipDirectory = $false
    # Ensure pip folder exists in ProgramData
    if (-not (Test-Path $configDirectory)) {
        New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
        $createdPipDirectory = $true
    }

    $restoredPipIni = $false
    if (Test-Path "$configPath.disabled") {
        Rename-Item "$configPath.disabled" $configPath -ErrorAction SilentlyContinue
        $restoredPipIni = $true
    }

    $mirrorUri = [System.Uri]::new($mirrorPath)
    $pipConfig = @"
[global]
find-links = $($mirrorUri.AbsoluteUri)
no-index = true
"@
    [System.IO.File]::WriteAllText($configPath, $pipConfig)

    [System.Environment]::SetEnvironmentVariable(
        "PIP_NO_INDEX",
        "1",
        "Machine"
    )

    Write-SummaryEvent -CreatedPipDirectory $createdPipDirectory -RestoredPipIni $restoredPipIni -ConfigPath $configPath -MirrorPath $mirrorPath
}
