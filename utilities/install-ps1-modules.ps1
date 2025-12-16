Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

Install-Module PSReadLine -Scope CurrentUser -Force -AllowClobber
Install-Module posh-git -Scope CurrentUser -Force -AllowClobber

New-Item -ItemType File -Path $PROFILE

Add-Content -Path $PROFILE -Value 'Import-Module PSReadLine'
Add-Content -Path $PROFILE -Value 'Import-Module posh-git'
