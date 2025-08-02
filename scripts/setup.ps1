# Requires to run as Administrator for PATH modification
# Usage: Run in an elevated PowerShell prompt

param(
    # Path to your RunLang.psm1 module file; update if different location
    [string]$ModuleSourcePath = "$HOME\langDocker\.runlang\RunLang.psm1",
    
    # Directory where the cmd wrapper script will be created and added to PATH
    [string]$WrapperInstallDir = "$HOME\langDocker\runlang-cmd-wrapper"
)

function Install-ModuleFile {
    param([string]$SourceFile)

    $userModulesPath = "C:\Program Files\WindowsPowerShell\Modules\RunLang"
    Write-Host "Installing RunLang module to: $userModulesPath"

    if (-not (Test-Path $userModulesPath)) {
        New-Item -ItemType Directory -Path $userModulesPath -Force | Out-Null
    }

    Copy-Item -Path $SourceFile -Destination $userModulesPath -Force
    Write-Host "Module installed successfully."
}

function Setup-PowerShellProfileImport {
    $profilePath = $PROFILE
    if (-not (Test-Path $profilePath)) {
        Write-Host "PowerShell profile not found. Creating at $profilePath"
        New-Item -ItemType File -Path $profilePath -Force | Out-Null
    }

    $importLine = "Import-Module RunLang -Force"
    $profileContent = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue

    if ($profileContent -like "*$importLine*") {
        Write-Host "RunLang module already imported in PowerShell profile."
    } else {
        Add-Content -Path $profilePath -Value "`n# Automatically import RunLang module`n$importLine`n"
        Write-Host "Added import line to PowerShell profile."
    }
}

function Create-CmdWrapper {
    param([string]$TargetDir)

    if (-not (Test-Path $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
        Write-Host "Created wrapper script directory at $TargetDir"
    }

    $wrapperPath = Join-Path $TargetDir "runlang.cmd"

    $cmdContent = @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module RunLang -Force; runlang %*"
"@

    Set-Content -Path $wrapperPath -Value $cmdContent -Encoding ASCII -Force
    Write-Host "Created wrapper cmd script at $wrapperPath"
}

function Add-ToSystemPath {
    param([string]$FolderPath)

    $existingMachinePath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
    $existingUserPath = [Environment]::GetEnvironmentVariable("PATH", "User")

    # Get the current user's Windows identity
    $windowsIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    # Create a WindowsPrincipal object
    $windowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($windowsIdentity)
    # Check if the current user is an administrator
    $isAdmin = $windowsPrincipal.IsInRole([System.Security.Principal.WindowsBuiltinRole]::Administrator)

    if ($isAdmin) {
        $currentPath = $existingMachinePath
        $scope = "Machine"
    } else {
        $currentPath = $existingUserPath
        $scope = "User"
    }

    if (-not ($currentPath.Split(';') -contains $FolderPath)) {
        $newPath = "$currentPath;$FolderPath"
        Write-Host "Adding '$FolderPath' to $scope PATH."

        try {
            [Environment]::SetEnvironmentVariable("PATH", $newPath, $scope)
            Write-Host "Successfully updated $scope PATH. Restart terminals to apply changes."
        } catch {
            Write-Warning "Failed to update $scope PATH: $_"
        }
    } else {
        Write-Host "'$FolderPath' is already in the $scope PATH."
    }
}

# Validate Module file
if (-not (Test-Path $ModuleSourcePath)) {
    Write-Error "RunLang module file not found at: $ModuleSourcePath"
    exit 1
}

# 1. Install the module
Install-ModuleFile -SourceFile $ModuleSourcePath

# 2. Update PowerShell profile to auto-import
Setup-PowerShellProfileImport

# 3. Create runlang.cmd wrapper for cmd.exe and other terminals
Create-CmdWrapper -TargetDir $WrapperInstallDir

# 4. Add the wrapper directory to PATH (User or Machine depending on privilege)
Add-ToSystemPath -FolderPath $WrapperInstallDir

Write-Host "`nSetup Complete!"
Write-Host " - RunLang module installed and auto-imported in PowerShell."
Write-Host " - 'runlang' command available in PowerShell and Command Prompt."
Write-Host " - Please restart your terminal windows to apply PATH changes."
