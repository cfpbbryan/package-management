#!/usr/bin/env pwsh
<##
Emit a tab-separated report for every Stata package found in the shared ado tree.

The output mirrors the column order used by the Python and R inventory scripts
alongside package name, version, source, reviewer, installer, summary, URL,
install location, and file hash from the mirror's integrity-baseline.json
(blank when absent). Metadata is derived from the shared ado tree when available.
##>

param(
    [string]$SharedAdo = "C:/Program Files/Stata18/shared_ado"
)

$SummaryLineLimit = 30

$HashManifestName = 'integrity-baseline.json'

function Ensure-Windows {
    $isWindowsPlatform = $IsWindows

    if (-not $isWindowsPlatform -and $PSVersionTable.Platform) {
        $isWindowsPlatform = $PSVersionTable.Platform -eq 'Win32NT'
    }

    if (-not $isWindowsPlatform -and $env:OS) {
        $isWindowsPlatform = $env:OS -like 'Windows*'
    }

    if (-not $isWindowsPlatform) {
        Write-Error "This script is intended to run on Windows hosts only."
        exit 1
    }
}

function Get-AdoFiles {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath
    )

    Get-ChildItem -Path $BasePath -Filter *.ado -Recurse -File -ErrorAction SilentlyContinue
}

function Get-LocalMetadata {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$File
    )

    $metadata = @{ version = $null; description = $null }

    try {
        $lines = Get-Content -LiteralPath $File.FullName -Encoding Latin1 -TotalCount $SummaryLineLimit -ErrorAction Stop
    }
    catch {
        return $metadata
    }

    foreach ($line in $lines) {
        $stripped = $line.Trim()
        $lower = $stripped.ToLowerInvariant()

        if ($stripped.StartsWith('*') -and -not $metadata.description) {
            $metadata.description = $stripped.TrimStart('*').Trim()
        }

        if ($lower.Contains('version') -and -not $stripped.StartsWith('*')) {
            $parts = $lower -split '\s+'
            for ($i = 0; $i -lt $parts.Length; $i++) {
                if ($parts[$i] -eq 'version' -and $i + 1 -lt $parts.Length) {
                    $metadata.version = $parts[$i + 1]
                    break
                }
            }
        }

        if ($metadata.version -and $metadata.description) {
            break
        }
    }

    return $metadata
}

function Resolve-Location {
    param(
        [string]$SharedRoot,
        [System.IO.FileInfo]$AdoPath
    )

    if ($null -ne $AdoPath) {
        return (Split-Path -Path $AdoPath.FullName -Parent)
    }

    return $SharedRoot
}

function Format-Row {
    param(
        [string]$Package,
        [string]$Version = "",
        [string]$Description = "",
        [string]$Location = "",
        [string]$Url = "",
        [string]$Hash = ""
    )

    function Sanitize($field) {
        if ($null -eq $field) {
            return ""
        }

        return $field.ToString().Replace("`t", " ")
    }

    $packageValue = if ([string]::IsNullOrWhiteSpace($Package)) { "unknown" } else { $Package }
    $versionValue = if ($null -eq $Version) { "" } else { $Version }
    $descriptionValue = if ($null -eq $Description) { "" } else { $Description }
    $locationValue = if ([string]::IsNullOrWhiteSpace($Location)) { "unknown" } else { $Location }

    $columns = @(
        $packageValue,
        $versionValue,
        'Stata',
        'Reviewer',
        'Installer',
        $descriptionValue,
        $Url,
        $locationValue,
        $Hash
    )

    return ($columns | ForEach-Object { Sanitize $_ }) -join "`t"
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

function Get-PropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $psObject = $Object.PSObject

    if ($psObject -and $psObject.Methods['ContainsKey']) {
        if ($Object.ContainsKey($Name)) { return $Object[$Name] }
    }
    elseif ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    }
    elseif ($psObject -and $psObject.Properties[$Name]) {
        return $Object.$Name
    }

    return $null
}

# Sanity check: baseline dictionaries produced by integrity-check.ps1 on
# Windows PowerShell 5.x expose ContainsKey but not Contains, so make sure we
# access them without emitting warnings.
if ($PSVersionTable.PSEdition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -lt 6) {
    $sanityBaseline = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    $sanityMirror = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    $sanityBaseline['Mirror'] = $sanityMirror
    $sanityMirror['Files'] = @()

    Get-PropertyValue -Object $sanityBaseline -Name 'Mirror' | Out-Null
}

Ensure-Windows

if (-not (Test-Path -LiteralPath $SharedAdo)) {
    $missingAdoMessage = "Shared ado directory not found at $SharedAdo. Run stata-install-baseline.do first."
    Write-Error $missingAdoMessage
    exit 1
}

$hashLookup = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
$hashRoot = $SharedAdo
$manifestPath = Join-Path -Path $SharedAdo -ChildPath $HashManifestName

if (Test-Path -LiteralPath $manifestPath) {
    try {
        $manifestJson = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop
        $manifest = $manifestJson | ConvertFrom-JsonCompat

        $manifestMirror = Get-PropertyValue -Object $manifest -Name 'Mirror'

        if ($manifestMirror) {
            $manifestRootPath = Get-PropertyValue -Object $manifestMirror -Name 'RootPath'

            if ($manifestRootPath) {
                $hashRoot = $manifestRootPath
            }

            $manifestFiles = Get-PropertyValue -Object $manifestMirror -Name 'Files'

            if ($manifestFiles) {
                foreach ($file in $manifestFiles) {
                    $relativePath = Get-PropertyValue -Object $file -Name 'RelativePath'
                    $hashValue = Get-PropertyValue -Object $file -Name 'Hash'

                    if ($relativePath -and $hashValue) {
                        $hashLookup[$relativePath] = $hashValue
                    }
                }
            }
        }
    }
    catch {
        $manifestWarning = "Unable to load integrity baseline at $manifestPath. Hash column will be blank."
        Write-Warning $manifestWarning
    }
}
else {
    $missingManifestMessage = "Integrity baseline not found at $manifestPath. Hash column will be blank."
    Write-Warning $missingManifestMessage
}

$rows = New-Object System.Collections.Generic.List[string]
$copySucceeded = $false
$clipboardAttempted = $false

foreach ($ado in Get-AdoFiles -BasePath $SharedAdo) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($ado.Name)
    $meta = Get-LocalMetadata -File $ado

    $version = if ($meta.version) { $meta.version } else { "" }
    $description = if ($meta.description) { $meta.description } else { "" }
    $location = Resolve-Location -SharedRoot $SharedAdo -AdoPath $ado

    try {
        $relativePath = [System.IO.Path]::GetRelativePath($hashRoot, $ado.FullName)
    }
    catch {
        $relativePath = $ado.Name
    }

    $hashValue = Get-PropertyValue -Object $hashLookup -Name $relativePath
    if (-not $hashValue) { $hashValue = "" }

    $rows.Add((Format-Row -Package $name -Version $version -Description $description -Location $location -Hash $hashValue)) | Out-Null
}

if ($rows.Count -gt 0) {
    $report = $rows -join [System.Environment]::NewLine
    $clipboardAttempted = $true

    try {
        $report | clip.exe
        $copySucceeded = $? -and ($LASTEXITCODE -eq 0)
    }
    catch {
        $copySucceeded = $false
    }

    if ($copySucceeded) {
        Write-Host "Package report copied to clipboard." -ForegroundColor Yellow
    }
}

if (-not $clipboardAttempted) {
    Write-Warning "No Stata packages found to copy."
}
else {
    if (-not $copySucceeded) {
        Write-Warning "Unable to copy package report to clipboard."
    }
}
