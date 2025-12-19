<#
.SYNOPSIS
    Generate or verify integrity baselines for offline package mirrors.

.DESCRIPTION
    This script walks a single mirror root directory and records file integrity information
    (size, modified time, SHA-256 hash) in a JSON manifest. Baseline mode produces the
    manifest, while verify mode re-computes hashes and reports missing files, unexpected
    files, and hash mismatches. Results are written to the console and the Windows event log.

.PARAMETER MirrorRoot
    Mirror root directory to process. Defaults to C:\admin\pip_mirror.

.PARAMETER Mode
    Operation mode: 'baseline' to create a manifest; 'verify' to compare against an
    existing manifest.

.PARAMETER ManifestPath
    Location of the JSON manifest to write or read. Defaults to
    <MirrorRoot>\integrity-baseline.json. Must reside inside the mirror root.

.EXAMPLE
    # Create a baseline manifest for the default mirror
    .\integrity-check.ps1 -Mode baseline

.EXAMPLE
    # Verify the mirror against an existing baseline manifest
    .\integrity-check.ps1 -Mode verify
#>

[CmdletBinding()]
param(
[Parameter(Mandatory = $false)]
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
[string]$MirrorRoot = "C:\\admin\\pip_mirror",

    [Parameter(Mandatory = $false)]
    [ValidateSet('baseline', 'verify')]
    [string]$Mode = 'baseline',

    [Parameter(Mandatory = $false)]
    [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

            $rootPath = $fakeBoundParameters['MirrorRoot']
            if (-not $rootPath) { $rootPath = $MirrorRoot }

            $resolvedRoot = Resolve-Path -Path $rootPath -ErrorAction SilentlyContinue
            if (-not $resolvedRoot) { return }

            $root = $resolvedRoot.ProviderPath
            $defaultManifest = Join-Path -Path $root -ChildPath 'integrity-baseline.json'

            $candidates = New-Object System.Collections.Generic.HashSet[string]
            $candidates.Add($defaultManifest) | Out-Null

            Get-ChildItem -Path $root -Filter *.json -Recurse -File -ErrorAction SilentlyContinue |
                ForEach-Object { $candidates.Add($_.FullName) | Out-Null }

            $normalizedWord = if ([string]::IsNullOrWhiteSpace($wordToComplete)) { '' } else { $wordToComplete }

            $candidates | Where-Object { [string]::IsNullOrWhiteSpace($normalizedWord) -or $_ -like "$normalizedWord*" } |
                Sort-Object |
                ForEach-Object {
                    $name = Split-Path -Path $_ -Leaf
                    [System.Management.Automation.CompletionResult]::new($_, $name, 'ParameterValue', $_)
                }
        })]
    [string]$ManifestPath,
    [switch]$Log
)

$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/logging-utils.psm1" -Force

$logName = 'Application'
$eventSource = 'MirrorIntegrityCheck'
$informationEventId = 1000
$errorEventId = 1001
$eventLogConfig = @{
    LogName     = $logName
    EventSource = $eventSource
    EventIds    = @{
        Information = $informationEventId
        Error       = $errorEventId
    }
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

function Register-MirrorIntegrityCompleters {
    param([string]$ScriptPath = $PSCommandPath)

    $commandInfo = Get-Command -Name $ScriptPath -CommandType ExternalScript -ErrorAction SilentlyContinue
    if (-not $commandInfo) { return }

    $scriptName = Split-Path -Path $ScriptPath -Leaf
    $parameters = $commandInfo.Parameters

    $targets = @{
        MirrorRoot   = $null
        ManifestPath = $null
    }

    foreach ($paramName in @($targets.Keys)) {
        if ($parameters.ContainsKey($paramName)) {
            $completer = $parameters[$paramName].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ArgumentCompleterAttribute] } |
                Select-Object -First 1

            if ($completer) {
                $targets[$paramName] = $completer.ScriptBlock
            }
        }
    }

    foreach ($entry in $targets.GetEnumerator()) {
        if (-not $entry.Value) { continue }

        Register-ArgumentCompleter -CommandName $scriptName -ParameterName $entry.Key -ScriptBlock $entry.Value
        Register-ArgumentCompleter -CommandName $ScriptPath -ParameterName $entry.Key -ScriptBlock $entry.Value
    }
}

Register-MirrorIntegrityCompleters

function Resolve-AbsolutePath {
    param([string]$Path)
    [System.IO.Path]::GetFullPath($Path)
}

function Get-RelativePath {
    param(
        [string]$BasePath,
        [string]$TargetPath
    )

    $resolvedBase = (Resolve-Path -LiteralPath $BasePath).ProviderPath
    $resolvedTarget = (Resolve-Path -LiteralPath $TargetPath).ProviderPath

    $getRelativePathMethod = [System.IO.Path].GetMethod('GetRelativePath', [type[]]@([string], [string]))
    if ($getRelativePathMethod) {
        return [System.IO.Path]::GetRelativePath($resolvedBase, $resolvedTarget)
    }

    $baseUri = [Uri](($resolvedBase.TrimEnd([System.IO.Path]::DirectorySeparatorChar)) + [System.IO.Path]::DirectorySeparatorChar)
    $targetUri = [Uri]$resolvedTarget
    $relativeUri = $baseUri.MakeRelativeUri($targetUri)
    $relativePath = [System.Uri]::UnescapeDataString($relativeUri.ToString())

    return $relativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar
}

function Validate-Parameters {
    if (-not $MirrorRoot) {
        throw 'A mirror root must be specified.'
    }

    $absoluteRoot = Resolve-AbsolutePath $MirrorRoot

    $adminRoot = Resolve-AbsolutePath 'C:\\admin'
    $adminPrefix = $adminRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $absoluteRoot.StartsWith($adminPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Mirror root must be a subfolder of $adminRoot. Provided path: $absoluteRoot"
    }

    if (-not (Test-Path -Path $absoluteRoot -PathType Container)) {
        throw "Mirror root does not exist or is not a directory: $absoluteRoot"
    }

    $script:MirrorRoot = $absoluteRoot

    if (-not $ManifestPath) {
        $script:ManifestPath = Join-Path -Path $script:MirrorRoot -ChildPath 'integrity-baseline.json'
    }

    $resolvedManifest = Resolve-AbsolutePath $script:ManifestPath
    $script:ManifestPath = $resolvedManifest

    $rootPrefix = $script:MirrorRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedManifest.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "ManifestPath must be located inside the mirror root: $script:MirrorRoot"
    }

    if ($Mode -eq 'verify' -and -not (Test-Path -Path $script:ManifestPath -PathType Leaf)) {
        throw "Manifest not found for verification: $script:ManifestPath"
    }
}

function Get-ExcludedPaths {
    $excluded = New-Object System.Collections.Generic.HashSet[string]

    if ($script:ManifestPath) {
        $excluded.Add((Resolve-AbsolutePath $script:ManifestPath)) | Out-Null
    }

    $excluded
}

function Get-FileRecords {
    param(
        [string]$RootPath,
        [System.Collections.Generic.HashSet[string]]$ExcludedPaths
    )

    $files = Get-ChildItem -Path $RootPath -Recurse -File -ErrorAction Stop
    $records = foreach ($file in $files) {
        if ($ExcludedPaths.Contains($file.FullName)) { continue }
        if ($file.Extension -match '\.(tmp|log|bak)$') { continue }

        $relativePath = Get-RelativePath -BasePath $RootPath -TargetPath $file.FullName
        $hash = Get-FileHash -Algorithm SHA256 -Path $file.FullName

        [PSCustomObject]@{
            RootPath        = $RootPath
            RelativePath    = $relativePath
            FullPath        = $file.FullName
            SizeBytes       = $file.Length
            LastWriteTimeUtc= $file.LastWriteTimeUtc.ToString('o')
            Hash            = $hash.Hash
        }
    }

    $records
}

function ConvertFrom-JsonCompat {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Json
    )

    $convertCmd = Get-Command ConvertFrom-Json -ErrorAction SilentlyContinue
    $supportsDepth = ($PSVersionTable.PSVersion.Major -ge 6) -or ($convertCmd -and $convertCmd.Parameters.ContainsKey('Depth'))

    if ($supportsDepth) {
        return $Json | ConvertFrom-Json -Depth 6 -ErrorAction Stop
    }

    try {
        return $Json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Add-Type -AssemblyName System.Web.Extensions
        $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $serializer.MaxJsonLength = [int]::MaxValue
        return $serializer.DeserializeObject($Json)
    }
}

function Build-Baseline {
    $excluded = Get-ExcludedPaths

    Write-Log "Building baseline for $script:MirrorRoot" 'INFO'
    $files = Get-FileRecords -RootPath $script:MirrorRoot -ExcludedPaths $excluded

    $manifest = [PSCustomObject]@{
        GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        Mode           = 'baseline'
        Mirror         = [PSCustomObject]@{
            RootPath  = $script:MirrorRoot
            FileCount = $files.Count
            Files     = $files | Sort-Object RelativePath
        }
    }

    $manifest | ConvertTo-Json -Depth 6 | Out-File -FilePath $script:ManifestPath -Encoding UTF8
    Write-Log "Baseline written to $script:ManifestPath" 'INFO'
}

function Verify-Baseline {
    $excluded = Get-ExcludedPaths
    $manifestJson = Get-Content -Path $script:ManifestPath -Raw
    $manifest = ConvertFrom-JsonCompat -Json $manifestJson

    $discrepancies = @()

    $expected = $manifest.Mirror
    if (-not $expected -or $expected.RootPath -ne $script:MirrorRoot) {
        $message = "Manifest mirror root does not match the requested mirror root: $script:MirrorRoot"
        Write-Log $message 'WARN'
        $discrepancies += [PSCustomObject]@{ RootPath = $script:MirrorRoot; Issue = 'MissingManifestEntry'; Detail = $message }
    }
    else {
        Write-Log "Verifying mirror $script:MirrorRoot" 'INFO'

        $expectedFiles = @{}
        foreach ($item in $expected.Files) { $expectedFiles[$item.RelativePath] = $item }

        $actualRecords = Get-FileRecords -RootPath $script:MirrorRoot -ExcludedPaths $excluded
        $actualFiles = @{}
        foreach ($record in $actualRecords) { $actualFiles[$record.RelativePath] = $record }

        $missing = $expectedFiles.Keys | Where-Object { -not $actualFiles.ContainsKey($_) }
        $unexpected = $actualFiles.Keys | Where-Object { -not $expectedFiles.ContainsKey($_) }

        foreach ($rel in $missing) {
            $discrepancies += [PSCustomObject]@{ RootPath = $script:MirrorRoot; Issue = 'MissingFile'; Detail = $rel }
            Write-Log "Missing: $rel" 'ERROR'
            Write-EventLogIfEnabled -Message "Missing file: $rel" -EntryType 'Error'
        }

        foreach ($rel in $unexpected) {
            $discrepancies += [PSCustomObject]@{ RootPath = $script:MirrorRoot; Issue = 'UnexpectedFile'; Detail = $rel }
            Write-Log "Unexpected: $rel" 'WARN'
            Write-EventLogIfEnabled -Message "Unexpected file: $rel" -EntryType 'Error'
        }

        $shared = $expectedFiles.Keys | Where-Object { $actualFiles.ContainsKey($_) }
        foreach ($rel in $shared) {
            $expectedItem = $expectedFiles[$rel]
            $actualItem = $actualFiles[$rel]
            if ($expectedItem.Hash -ne $actualItem.Hash) {
                $discrepancies += [PSCustomObject]@{ RootPath = $script:MirrorRoot; Issue = 'HashMismatch'; Detail = $rel }
                Write-Log "Hash mismatch: $rel" 'ERROR'
                Write-EventLogIfEnabled -Message "Hash mismatch: $rel" -EntryType 'Error'
            }
        }

        Write-Log "Verification complete for $script:MirrorRoot. Missing: $($missing.Count), Unexpected: $($unexpected.Count), Hash mismatches: $((($shared | Where-Object { $expectedFiles[$_].Hash -ne $actualFiles[$_].Hash }).Count))" 'INFO'
    }

    if ($discrepancies.Count -gt 0) {
        $summary = "Mirror integrity verification FAILED for $script:MirrorRoot with $($discrepancies.Count) issue(s)."
        Write-Log $summary 'ERROR'
        Write-EventLogIfEnabled -Message $summary -EntryType 'Error'
        return @{ Success = $false; Issues = $discrepancies }
    }

    $successMessage = "Mirror integrity verification PASSED for $script:MirrorRoot with no discrepancies."
    Write-Log $successMessage 'INFO'
    Write-EventLogIfEnabled -Message $successMessage -EntryType 'Information'
    return @{ Success = $true; Issues = @() }
}

function Run-MirrorIntegrityCheck {
    Validate-Parameters

    if ($Mode -eq 'baseline') {
        Build-Baseline
        $message = "Mirror integrity baseline created at $script:ManifestPath"
        Write-EventLogIfEnabled -Message $message -EntryType 'Information'
        return 0
    }
    else {
        $result = Verify-Baseline
        if (-not $result.Success) { return 1 }
        return 0
    }
}

exit (Run-MirrorIntegrityCheck)
