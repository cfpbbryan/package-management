# Install Visual C++ Build Tools for Python package building
# Minimal installation for pip/PyPI package compilation

$ErrorActionPreference = "Stop"

$installerUrl = "https://aka.ms/vs/stable/vs_BuildTools.exe"
$installerPath = "$env:TEMP\vs_BuildTools.exe"

Write-Host "Visual C++ Build Tools Installer" -ForegroundColor Cyan
Write-Host "================================`n"

# Check if already installed
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    $installed = & $vswhere -products Microsoft.VisualStudio.Product.BuildTools -property installationPath
    if ($installed) {
        Write-Host "Build Tools appear to be already installed at: $installed" -ForegroundColor Yellow
        $response = Read-Host "Continue with installation anyway? (y/N)"
        if ($response -ne "y") {
            Write-Host "Installation cancelled."
            exit 0
        }
    }
}

# Download installer
Write-Host "Downloading installer from: $installerUrl"
Write-Host "Saving to: $installerPath`n"

try {
    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
    Write-Host "Download complete.`n" -ForegroundColor Green
} catch {
    Write-Host "Failed to download installer: $_" -ForegroundColor Red
    exit 1
}

# Verify download
if (-not (Test-Path $installerPath)) {
    Write-Host "Installer file not found after download." -ForegroundColor Red
    exit 1
}

$fileSize = (Get-Item $installerPath).Length / 1MB
Write-Host "Installer size: $([math]::Round($fileSize, 2)) MB`n"

# Run installer
Write-Host "Installing Visual C++ Build Tools (minimal for Python)..."
Write-Host "This will take several minutes and requires ~3-4 GB of disk space.`n" -ForegroundColor Yellow

try {
    $process = Start-Process -FilePath $installerPath -ArgumentList @(
        "--quiet",
        "--wait",
        "--norestart",
        "--add", "Microsoft.VisualStudio.Workload.VCTools"
    ) -Wait -PassThru

    if ($process.ExitCode -eq 0) {
        Write-Host "`nInstallation completed successfully!" -ForegroundColor Green
    } elseif ($process.ExitCode -eq 3010) {
        Write-Host "`nInstallation completed. A restart may be required." -ForegroundColor Yellow
    } else {
        Write-Host "`nInstallation failed with exit code: $($process.ExitCode)" -ForegroundColor Red
        exit $process.ExitCode
    }
} catch {
    Write-Host "Installation error: $_" -ForegroundColor Red
    exit 1
}

# Cleanup
Write-Host "`nCleaning up installer..."
Remove-Item $installerPath -Force -ErrorAction SilentlyContinue

Write-Host "`nBuild tools are now ready for pip package compilation." -ForegroundColor Green
