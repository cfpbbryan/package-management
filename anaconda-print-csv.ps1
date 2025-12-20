[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$EnvironmentRoot = 'C:\Users',

    [Parameter(Mandatory = $false)]
    [int]$MaxDepth = 6
)

try {
    $resolvedEnvironmentRoot = Resolve-Path -LiteralPath $EnvironmentRoot -ErrorAction Stop
    $EnvironmentRoot = $resolvedEnvironmentRoot.ProviderPath
}
catch {
    Write-Error "Environment root '$EnvironmentRoot' does not exist or is not accessible."
    exit 1
}

function Read-EnvironmentFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $content = Get-Content -Path $Path -Raw

    # Try JSON first
    try {
        $parsed = $content | ConvertFrom-Json -ErrorAction Stop
        if ($parsed) { return $parsed }
    }
    catch {
        # Ignore and fall back to YAML
    }

    # ConvertFrom-Yaml ships with PowerShell 7+
    $yamlCmd = Get-Command -Name ConvertFrom-Yaml -ErrorAction SilentlyContinue
    if ($yamlCmd) {
        try {
            $parsed = $content | ConvertFrom-Yaml -ErrorAction Stop
            if ($parsed) { return $parsed }
        }
        catch {
            # Ignore and fall back to manual parsing
        }
    }

    return Parse-YamlDependencies -Content $content
}

function Parse-YamlDependencies {
    param(
        [Parameter(Mandatory = $true)][string]$Content
    )

    $lines = $Content -split "`r?`n"
    $dependencies = @()
    $currentPip = @()
    $name = ''
    $inDependencies = $false
    $pipIndent = $null

    foreach ($line in $lines) {
        if (-not $inDependencies -and $line -match '^name:\s*(.+)$') {
            $name = $Matches[1].Trim()
            continue
        }

        if ($line -match '^dependencies:\s*$') {
            $inDependencies = $true
            $currentPip = @()
            $pipIndent = $null
            continue
        }

        if (-not $inDependencies) { continue }

        if ($line.Trim().Length -eq 0) { continue }

        $indent = ($line -replace '(^\s*).*', '$1').Length
        $trimmed = $line.Trim()

        if ($trimmed -like 'pip:*') {
            $currentPip = @()
            $pipIndent = $indent
            continue
        }

        if ($pipIndent -ne $null -and $indent -gt $pipIndent) {
            if ($trimmed -like '-*') {
                $pipEntry = $trimmed.TrimStart('-').Trim()
                if ($pipEntry) { $currentPip += $pipEntry }
            }
            continue
        }

        if ($currentPip.Count -gt 0) {
            $dependencies += @{ pip = $currentPip }
            $currentPip = @()
            $pipIndent = $null
        }

        if ($trimmed -like '-*') {
            $entry = $trimmed.TrimStart('-').Trim()
            if ($entry) { $dependencies += $entry }
        }
    }

    if ($currentPip.Count -gt 0) {
        $dependencies += @{ pip = $currentPip }
    }

    return [pscustomobject]@{ Name = $name; Dependencies = $dependencies }
}

function Get-PackageFromString {
    param(
        [Parameter(Mandatory = $true)][string]$Entry
    )

    $clean = $Entry.Trim()
    if (-not $clean) { return $null }

    $separatorIndex = $clean.IndexOf('~=')
    $separatorLength = 2
    if ($separatorIndex -lt 0) {
        $separatorIndex = $clean.IndexOf('==')
        $separatorLength = 2
        if ($separatorIndex -lt 0) {
            $separatorIndex = $clean.IndexOf('=')
            $separatorLength = 1
        }
    }

    if ($separatorIndex -gt 0) {
        $name = $clean.Substring(0, $separatorIndex)
        $version = $clean.Substring($separatorIndex + $separatorLength)
    }
    else {
        $name = $clean
        $version = ''
    }

    if ($name -like '*::*') {
        $name = ($name -split '::')[-1]
    }

    return [pscustomobject]@{ Name = $name; Version = $version }
}

function Expand-Dependencies {
    param(
        [Parameter(Mandatory = $true)]$Dependencies
    )

    $packages = @()

    foreach ($dependency in $Dependencies) {
        if ($dependency -is [string]) {
            $pkg = Get-PackageFromString -Entry $dependency
            if ($pkg) { $packages += $pkg }
            continue
        }

        if ($dependency -is [System.Collections.IDictionary]) {
            foreach ($key in $dependency.Keys) {
                if ($key -eq 'pip') {
                    foreach ($pipDep in $dependency[$key]) {
                        $pkg = Get-PackageFromString -Entry $pipDep
                        if ($pkg) { $packages += $pkg }
                    }
                }
            }
        }
    }

    return $packages
}

function Get-PythonVersion {
    param(
        [Parameter(Mandatory = $true)]$Dependencies
    )

    foreach ($dependency in $Dependencies) {
        if ($dependency -is [string]) {
            $pkg = Get-PackageFromString -Entry $dependency
            if ($pkg -and $pkg.Name -ieq 'python' -and $pkg.Version) {
                return $pkg.Version
            }
        }
    }

    return ''
}

$extensions = @('*.json', '*.yml', '*.yaml')
$excludedDirectories = @('AppData', 'node_modules', '.conda', 'Anaconda3\pkgs')
$getChildItemParams = @{
    Path = $EnvironmentRoot
    Recurse = $true
    File = $true
    Filter = $null
    ErrorAction = 'SilentlyContinue'
    Attributes = '!ReparsePoint'
    Exclude = $excludedDirectories
}

if ($PSVersionTable.PSVersion.Major -ge 7 -and $PSBoundParameters.ContainsKey('MaxDepth')) {
    $getChildItemParams['Depth'] = $MaxDepth
}

$environmentFiles = foreach ($extension in $extensions) {
    $getChildItemParams['Filter'] = $extension
    Get-ChildItem @getChildItemParams
}
if (-not $environmentFiles) {
    Write-Error "No environment export files (*.json, *.yml, *.yaml) found under $EnvironmentRoot"
    exit 1
}

$rows = @()

foreach ($envFile in $environmentFiles) {
    $envData = Read-EnvironmentFile -Path $envFile.FullName
    if (-not $envData) { continue }

    $envName = if ($envData.Name) { $envData.Name } else { $envFile.BaseName }
    $resolvedEnvFilePath = (Resolve-Path -LiteralPath $envFile.FullName).ProviderPath
    $relativePath = $resolvedEnvFilePath.Substring($EnvironmentRoot.Length).TrimStart('\', '/')
    $owner = ($relativePath -split '[\\/]', 2)[0]
    $folderEnvName = $envFile.Directory.Name
    $fileEnvName = if ($envData.Name) { $envData.Name } else { $envFile.BaseName }
    $owner = $envFile.Directory.Name
    $sanitizedOwner = $owner -replace "\t", ' '
    $sanitizedFolderEnvName = $folderEnvName -replace "\t", ' '
    $sanitizedFileEnvName = $fileEnvName -replace "\t", ' '

    $dependencies = $envData.Dependencies
    if (-not $dependencies) { continue }

    $pythonVersion = Get-PythonVersion -Dependencies $dependencies
    $packages = Expand-Dependencies -Dependencies $dependencies

    foreach ($package in $packages) {
        $sanitizedName = $package.Name -replace "\t", ' '
        $sanitizedVersion = $package.Version -replace "\t", ' '
        $sanitizedPython = $pythonVersion -replace "\t", ' '
        $rows += "$sanitizedOwner`t$sanitizedFolderEnvName`t$sanitizedFileEnvName`t$sanitizedName`t$sanitizedVersion`t$sanitizedPython"
    }
}

if ($rows.Count -gt 0) {
    ($rows -join "`r`n") | clip.exe
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Copied Anaconda environment package list to clipboard" -ForegroundColor Yellow
    }
    else {
        Write-Host "Failed to copy Anaconda environment package list to clipboard (exit code $LASTEXITCODE)" -ForegroundColor Yellow
    }
}
else {
    Write-Host "No package information found to copy" -ForegroundColor Yellow
}
