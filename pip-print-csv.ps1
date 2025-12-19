# Load the System.IO.Compression assembly for ZipArchive
Add-Type -AssemblyName System.IO.Compression.FileSystem

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

function ConvertFrom-JsonCompat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string]$Json
    )

    begin {
        $jsonFragments = New-Object System.Collections.Generic.List[string]
    }

    process {
        $jsonFragments.Add($Json)
    }

    end {
        $combinedJson = if ($jsonFragments.Count -eq 1) { $jsonFragments[0] } else { [string]::Join([Environment]::NewLine, $jsonFragments) }

        $supportsDepth = $PSVersionTable.PSVersion.Major -ge 6 -or (Get-Command ConvertFrom-Json).Parameters.ContainsKey('Depth')

        if ($supportsDepth) {
            try {
                return $combinedJson | ConvertFrom-Json -Depth 6 -ErrorAction Stop
            }
            catch {
            }
        }

        try {
            return $combinedJson | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            Add-Type -AssemblyName System.Web.Extensions
            $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $serializer.MaxJsonLength = [int]::MaxValue
            return $serializer.DeserializeObject($combinedJson)
        }
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

$pipMirrorPath = "C:\admin\pip_mirror"
$integrityBaselinePath = Join-Path -Path $pipMirrorPath -ChildPath "integrity-baseline.json"

if (-not (Test-Path $pipMirrorPath)) {
    Write-Error "Pip mirror directory not found: $pipMirrorPath"
    exit 1
}

# Optional SHA-256 hash lookup sourced from integrity-check.ps1 output
$hashByFilename = @{}
if (Test-Path $integrityBaselinePath) {
    try {
        $baseline = Get-Content -Path $integrityBaselinePath -Raw | ConvertFrom-JsonCompat
        $mirror = Get-PropertyValue -Object $baseline -Name 'Mirror'
        $files = Get-PropertyValue -Object $mirror -Name 'Files'

        if ($files) {
            foreach ($file in $files) {
                $relativePath = Get-PropertyValue -Object $file -Name 'RelativePath'
                $hashValue = Get-PropertyValue -Object $file -Name 'Hash'
                $name = if ($relativePath) { [System.IO.Path]::GetFileName($relativePath) } else { $null }

                if ($name -and -not $hashByFilename.ContainsKey($name)) {
                    $hashByFilename[$name] = $hashValue
                }
            }
        }
    }
    catch {
        Write-Warning "Failed to parse integrity baseline at $integrityBaselinePath : $_"
    }
}

$packageInfo = Get-ChildItem -Path $pipMirrorPath -Filter "*.whl" | ForEach-Object {
    $whlFile = $_.FullName
    $filename = $_.BaseName
    $hash = $hashByFilename[$_.Name]

    try {
        # Open the wheel file directly as a ZIP archive
        $zip = [System.IO.Compression.ZipFile]::OpenRead($whlFile)

        # Find the METADATA file inside the *.dist-info directory
        $metadataEntry = $zip.Entries | Where-Object {
            $_.FullName -match '\.dist-info/METADATA$'
        } | Select-Object -First 1

        if ($metadataEntry) {
            # Read the METADATA file content directly from the archive
            $stream = $metadataEntry.Open()
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            $content = $reader.ReadToEnd()
            $reader.Close()
            $stream.Close()

            # Initialize metadata fields
            $name = ""
            $version = ""
            $requiresPython = ""
            $summary = ""
            $homepage = ""

            # Parse the METADATA content
            $content -split "`n" | ForEach-Object {
                $line = $_
                if ($line -match "^Name:\s*(.+)$") {
                    $name = $Matches[1].Trim()
                }
                elseif ($line -match "^Version:\s*(.+)$") {
                    $version = $Matches[1].Trim()
                }
                elseif ($line -match "^Requires-Python:\s*(.+)$") {
                    $requiresPython = $Matches[1].Trim()
                }
                elseif ($line -match "^Summary:\s*(.+)$") {
                    $summary = $Matches[1].Trim()
                }
                elseif ($line -match "^Home-page:\s*(.+)$") {
                    $homepage = $Matches[1].Trim()
                }
            }

            if ($name -and $version) {
                $location = $pipMirrorPath
                # Output format: Name, Version, Requires-Python, Source, Reviewer, Installer, Summary, Home-page, Location, Hash
                "$name`t$version`t$requiresPython`tPyPi`tReviewer`tInstaller`t$summary`t$homepage`t$location`t$hash"
            }
        }

        $zip.Dispose()
    }
    catch {
        Write-Error "Failed to process $whlFile : $_"
    }
}

if ($packageInfo) {
    ($packageInfo -join "`r`n") | clip.exe

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Copied pip mirror package list to clipboard" -ForegroundColor Yellow
    }
}
