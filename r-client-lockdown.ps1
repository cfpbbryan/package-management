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
    [string]$RInstallPath = ""
)

$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/logging-utils.psm1" -Force

$eventLogConfig = @{
    LogName     = 'Application'
    EventSource = 'RClientLockdown'
    EventIds    = @{
        Information = 1000
        Error       = 1001
    }
    SkipSourceCreationErrors = $true
}

function Register-RClientLockdownCompleters {
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

function Add-RScriptToSystemPath {
    param([string]$InstallPath)

    if ([string]::IsNullOrWhiteSpace($InstallPath)) { return $false }

    $rscriptDir = [System.IO.Path]::Combine($InstallPath, 'bin')
    if (-not (Test-Path -Path $rscriptDir -PathType Container)) { return $false }

    $currentPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ([string]::IsNullOrWhiteSpace($currentPath)) { $currentPath = '' }

    $normalize = {
        param([string]$PathEntry)
        if ([string]::IsNullOrWhiteSpace($PathEntry)) { return $null }
        return $PathEntry.Trim().TrimEnd('\', '/')
    }

    $rscriptDirNormalized = & $normalize $rscriptDir
    $pathEntries = $currentPath -split ';' | ForEach-Object { & $normalize $_ } | Where-Object { $_ }

    $alreadyPresent = $pathEntries | Where-Object { $_ -ieq $rscriptDirNormalized }
    if ($alreadyPresent) { return $false }

    $updatedEntries = @($pathEntries + $rscriptDirNormalized) | Where-Object { $_ }
    $updatedPath = ($updatedEntries -join ';')
    [Environment]::SetEnvironmentVariable('Path', $updatedPath, 'Machine')
    return $true
}

Register-RClientLockdownCompleters

try {
    $resolvedInstallPath = Resolve-RInstallPath -ProvidedPath $RInstallPath

    if ([string]::IsNullOrWhiteSpace($resolvedInstallPath)) {
        $errorMessage = 'Unable to locate the R installation directory. Provide a valid path with -RInstallPath.'
        Write-Error $errorMessage
        throw $errorMessage
    }

    $resolvedInstallPath = Convert-ToForwardSlashPath $resolvedInstallPath
    $etcDirectory = Convert-ToForwardSlashPath ([System.IO.Path]::Combine($resolvedInstallPath, 'etc'))

    if (-not (Test-Path -Path $etcDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $etcDirectory -Force | Out-Null
    }

    $rProfilePath = Convert-ToForwardSlashPath ([System.IO.Path]::Combine($etcDirectory, 'Rprofile.site'))
    $rEnvironPath = Convert-ToForwardSlashPath ([System.IO.Path]::Combine($etcDirectory, 'Renviron.site'))

    $rProfileContent = 'options(repos = c(CRAN = "file:///c:/admin/r_mirror"), pkgType = "binary")'
    $rEnvironContent = 'R_REPOS_OVERRIDE=1'

    [System.IO.File]::WriteAllText($rProfilePath, $rProfileContent)
    [System.IO.File]::WriteAllText($rEnvironPath, $rEnvironContent)

    $rPathUpdated = Add-RScriptToSystemPath -InstallPath $resolvedInstallPath
    $pathSummary = if ($rPathUpdated) { 'System PATH updated with R bin.' } else { 'System PATH already contained R bin.' }

    $summary = "R client lockdown wrote $rProfilePath and $rEnvironPath. $pathSummary"
    Write-Log $summary 'INFO' -ToEventLog -LogName $eventLogConfig.LogName -EventSource $eventLogConfig.EventSource -EventIds $eventLogConfig.EventIds -SkipSourceCreationErrors:$eventLogConfig.SkipSourceCreationErrors
}
catch {
    $errorMessage = "R client lockdown failed: $($_.Exception.Message)"
    Write-Log $errorMessage 'ERROR' -ToEventLog -LogName $eventLogConfig.LogName -EventSource $eventLogConfig.EventSource -EventIds $eventLogConfig.EventIds -SkipSourceCreationErrors:$eventLogConfig.SkipSourceCreationErrors
    throw
}
