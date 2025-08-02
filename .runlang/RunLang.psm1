#Requires -Version 5.1

<#
.SYNOPSIS
    LangDocker - A production-ready language-agnostic Docker execution environment
.DESCRIPTION
    Executes code files in containerized environments based on file extensions or explicit language specification
#>


# Global Configuration with Environment Variable Support

# Default paths if env variables are not set
$defaultConfigPath = "$env:USERPROFILE\langDocker\config\lang_docker_config.json"
$defaultLogPath = "$env:USERPROFILE\langDocker\logs\langdocker.log"

# Initialize global variables (will be updated after env loading)
$CONFIG_PATH = $defaultConfigPath
$LOG_PATH = $defaultLogPath
$LOG_TO_CONSOLE = $false

function Load-EnvFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$EnvFilePath
    )

    if (-not (Test-Path $EnvFilePath)) {
        Write-Warning "Env file '$EnvFilePath' not found. Skipping env loading."
        return
    }

    Get-Content $EnvFilePath | ForEach-Object {
        if ($_ -match '^\s*#' -or [string]::IsNullOrWhiteSpace($_)) { return }
        $parts = $_ -split '=', 2
        if ($parts.Count -eq 2) {
            $key = $parts[0].Trim()
            $val = $parts[1].Trim()
            # Remove enclosing quotes if present
            $val = $val.Trim('"')
            # Expand %USERPROFILE% if present
            $val = $val -replace '%USERPROFILE%', $env:USERPROFILE
            # Set as environment variable
            Set-Item -Path "Env:$key" -Value $val
        }
    }
}

# Attempt to load environment variables from .env file during initialization
$envFilePath = Join-Path (Split-Path $defaultConfigPath) 'langdocker.env'
Load-EnvFile -EnvFilePath $envFilePath

# Now override global paths if env vars are set
if ($env:LANGDOCKER_CONFIG_PATH -and -not [string]::IsNullOrWhiteSpace($env:LANGDOCKER_CONFIG_PATH)) {
    $CONFIG_PATH = $env:LANGDOCKER_CONFIG_PATH
}

if ($env:LANGDOCKER_LOG_PATH -and -not [string]::IsNullOrWhiteSpace($env:LANGDOCKER_LOG_PATH)) {
    $LOG_PATH = $env:LANGDOCKER_LOG_PATH
}

if ($env:LANGDOCKER_LOG_TO_CONSOLE) {
    $parsedBool = $false
    if ([bool]::TryParse($env:LANGDOCKER_LOG_TO_CONSOLE, [ref] $parsedBool)) {
        $LOG_TO_CONSOLE = $parsedBool
    }
}

# Global config object placeholder
$CONFIG = @{}


#region Logging Functions
function Write-ExecutionLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('ERROR', 'WARN', 'INFO', 'DEBUG')]
        [string]$Level,
        
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [hashtable]$Context = @{}
    )
    
    $logEntry = @{
        Timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ"
        Level = $Level
        Message = $Message
        Context = $Context
        ProcessId = $PID
    }
    
    try {
        $logJson = $logEntry | ConvertTo-Json -Compress
        Add-Content -Path $LOG_PATH -Value $logJson -ErrorAction SilentlyContinue
    }
    catch {
        # Fail silently on logging errors to not break main functionality
    }
    if ($LOG_TO_CONSOLE) {
        # Console output with colors
        $color = switch ($Level) {
            'ERROR' { 'Red' }
            'WARN' { 'Yellow' }
            'INFO' { 'Green' }
            'DEBUG' { 'Cyan' }
            default { 'White' }
        }
        Write-Host "[$Level] $Message" -ForegroundColor $color
    }
}
#endregion

#region Validation Functions
function Test-DockerAvailable {
    [CmdletBinding()]
    param()
    
    try {
        $null = & docker version --format "{{.Client.Version}}" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-ExecutionLog -Level 'DEBUG' -Message "Docker is available and running"
            return $true
        }
        else {
            throw "Docker command failed with exit code $LASTEXITCODE"
        }
    }
    catch {
        Write-ExecutionLog -Level 'ERROR' -Message "Docker is not available or not running: $($_.Exception.Message)"
        return $false
    }
}

function Get-SafePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )
    
    try {
        # Resolve to absolute path
        $resolvedPath = Resolve-Path $Path -ErrorAction Stop
        $currentDir = (Get-Location).Path
        
        # Security check - ensure file is within current directory tree
        if (-not $resolvedPath.Path.StartsWith($currentDir)) {
            throw "File must be within current directory tree for security reasons"
        }
        
        Write-ExecutionLog -Level 'DEBUG' -Message "Path validated successfully" -Context @{
            OriginalPath = $Path
            ResolvedPath = $resolvedPath.Path
        }
        
        return $resolvedPath.Path
    }
    catch {
        throw "Invalid or unsafe file path '$Path': $($_.Exception.Message)"
    }
}

function Test-ConfigurationSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        $ConfigObject
    )
    
    if (-not $ConfigObject) {
        throw "Configuration object is null or empty"
    }
    
    foreach ($langProperty in $ConfigObject.PSObject.Properties) {
        $langName = $langProperty.Name
        $config = $langProperty.Value
        
        # Required fields validation
        if (-not $config.command -or [string]::IsNullOrWhiteSpace($config.command)) {
            throw "Language '$langName' missing required 'command' field"
        }
        
        if (-not $config.extensions -or $config.extensions.Count -eq 0) {
            throw "Language '$langName' missing required 'extensions' field"
        }
        
        # Validate extensions format
        foreach ($ext in $config.extensions) {
            if ([string]::IsNullOrWhiteSpace($ext) -or $ext -match '[^a-zA-Z0-9]') {
                throw "Invalid extension '$ext' for language '$langName'. Extensions should be alphanumeric only"
            }
        }
        
        # Validate resource limits if specified
        if ($config.cpu) {
            $cpu = [double]$config.cpu
            if ($cpu -le 0 -or $cpu -gt 8.0) {
                Write-ExecutionLog -Level 'WARN' -Message "CPU limit $cpu for '$langName' is outside recommended range (0.1-8.0)"
            }
        }
        
        if ($config.memory -and $config.memory -notmatch '^\d+[kmgKMG]?$') {
            throw "Invalid memory format '$($config.memory)' for language '$langName'. Use format like '256m', '1g'"
        }
    }
    
    Write-ExecutionLog -Level 'INFO' -Message "Configuration schema validation passed"
}

function Get-ValidatedResourceLimits {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        $Config
    )
    
    $limits = @{}
    
    # CPU validation and defaults
    if ($Config.cpu) {
        $cpu = [double]$Config.cpu
        if ($cpu -lt 0.1 -or $cpu -gt 8.0) {
            Write-ExecutionLog -Level 'WARN' -Message "CPU limit $cpu is outside recommended range (0.1-8.0)"
        }
        $limits.cpu = $cpu
    }
    else {
        $limits.cpu = 0.5
    }
    
    # Memory validation and defaults
    if ($Config.memory) {
        if ($Config.memory -notmatch '^\d+[kmgKMG]?$') {
            throw "Invalid memory format: $($Config.memory). Use format like '256m', '1g'"
        }
        $limits.memory = $Config.memory
    }
    else {
        $limits.memory = "256m"
    }
    
    return $limits
}
#endregion

#region Configuration Management
function Load-Configuration {
    [CmdletBinding()]
    param()
    
    Write-ExecutionLog -Level 'INFO' -Message "Loading configuration from $CONFIG_PATH"
    
    if (-not (Test-Path $CONFIG_PATH)) {
        throw "Configuration file not found at $CONFIG_PATH"
    }
    
    try {
        $jsonContent = Get-Content $CONFIG_PATH -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($jsonContent)) {
            throw "Configuration file is empty"
        }
        
        $configObj = $jsonContent | ConvertFrom-Json -ErrorAction Stop
        Test-ConfigurationSchema -ConfigObject $configObj
        
        return $configObj
    }
    catch {
        throw "Failed to load or parse configuration file: $($_.Exception.Message)"
    }
}

function Initialize-Configuration {
    [CmdletBinding()]
    param()
    
    try {
        $configObj = Load-Configuration
        
        # Convert to hashtable with enhanced defaults
        $script:CONFIG = @{}
        
        foreach ($langProperty in $configObj.PSObject.Properties) {
            $lang = $langProperty.Name
            $props = $langProperty.Value
            
            # Enhanced image name handling
            $image = if ($props.image) { 
                if ($props.image -notmatch ":[\w\.\-]+$") { 
                    "$($props.image)" 
                } else { 
                    "$($props.image)-alpine" 
                }
            } else { 
                "$lang:alpine" 
            }
            
            $script:CONFIG[$lang] = @{
                image      = $image
                command    = $props.command
                extensions = $props.extensions
                mount_path = if ($props.mount_path) { $props.mount_path } else { "/app" }
                cpu        = if ($props.cpu) { [double]$props.cpu } else { 0.5 }
                memory     = if ($props.memory) { $props.memory } else { "256m" }
                timeout    = if ($props.timeout) { [int]$props.timeout } else { 300 }
            }
        }
        
        Write-ExecutionLog -Level 'INFO' -Message "Configuration loaded successfully" -Context @{
            LanguageCount = $script:CONFIG.Keys.Count
            Languages = ($script:CONFIG.Keys -join ', ')
        }
    }
    catch {
        Write-ExecutionLog -Level 'ERROR' -Message "Configuration initialization failed: $($_.Exception.Message)"
        throw
    }
}
#endregion

#region Docker Management
function Ensure-DockerImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ImageName
    )
    
    try {
        Write-ExecutionLog -Level 'DEBUG' -Message "Checking Docker image availability: $ImageName"
        
        $imageExists = & docker images --format "{{.Repository}}:{{.Tag}}" | Where-Object { $_ -eq $ImageName }
        
        if (-not $imageExists) {
            Write-ExecutionLog -Level 'INFO' -Message "Pulling Docker image: $ImageName"
            & docker pull $ImageName
            
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to pull Docker image with exit code $LASTEXITCODE"
            }
            
            Write-ExecutionLog -Level 'INFO' -Message "Successfully pulled Docker image: $ImageName"
        }
        else {
            Write-ExecutionLog -Level 'DEBUG' -Message "Docker image already available: $ImageName"
        }
    }
    catch {
        throw "Docker image validation failed for '$ImageName': $($_.Exception.Message)"
    }
}

function Invoke-DockerWithTimeout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$DockerArgs,
        
        [Parameter()]
        [int]$TimeoutSeconds = 300
    )
    
    Write-ExecutionLog -Level 'DEBUG' -Message "Starting Docker execution with timeout: ${TimeoutSeconds}s" -Context @{
        DockerArgs = ($DockerArgs -join ' ')
    }
    
    $job = Start-Job -ScriptBlock {
    param($dockerArgs)
    try {
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = "docker"
        $processInfo.Arguments = $dockerArgs -join " "
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        $process = [System.Diagnostics.Process]::Start($processInfo)
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        # Combine both outputs (plain text), so everything is "normal" output
        $allOut = $stdout + $stderr
        return $allOut
    } catch {
        return @{
            ExitCode = $LASTEXITCODE
            Output = $_.Exception.Message
        }
    }
} -ArgumentList (,$DockerArgs)

    
    try {
        $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
        if (-not $completed) {
            Stop-Job -Job $job -Force
            throw "Docker execution timed out after $TimeoutSeconds seconds"
        }
        
        $result = Receive-Job -Job $job
        $exitCode = if ($job.State -eq 'Completed') { 0 } else { 1 }
        
        Write-ExecutionLog -Level 'DEBUG' -Message "Docker execution completed" -Context @{
            ExitCode = $exitCode
            JobState = $job.State
        }
        
        return $result
    }
    catch {
        Write-ExecutionLog -Level 'ERROR' -Message "Docker execution failed: $($_.Exception.Message)"
        throw
    }
    finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}
#endregion

#region Main Execution Functions
function Invoke-LanguageCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [ValidateNotNullOrEmpty()]
        [string]$Language,
        
        [Parameter(ValueFromRemainingArguments=$true)]
        [string[]]$Args
    )
    
    begin {
        
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Write-ExecutionLog -Level 'INFO' -Message "Starting language execution" -Context @{
            Language = $Language
            File = if ($Args) { $Args[0] } else { 'None' }
            Arguments = if ($Args.Length -gt 1) { $Args[1..($Args.Length-1)] -join ' ' } else { 'None' }
        }
    }
    
    process {
        try {
            # Validate Docker availability
            if (-not (Test-DockerAvailable)) {
                throw "Docker is not available. Please ensure Docker is installed and running"
            }
            
            # Validate language configuration
            if (-not $script:CONFIG.ContainsKey($Language)) {
                $availableLanguages = $script:CONFIG.Keys -join ', '
                throw "Language '$Language' is not configured. Available languages: $availableLanguages"
            }
            
            # Validate file argument
            if (-not $Args -or -not $Args[0] -or [string]::IsNullOrWhiteSpace($Args[0])) {
                throw "File path is required as the first argument"
            }
            
            $config = $script:CONFIG[$Language]
            $filePath = Get-SafePath -Path $Args[0]
            
            if (-not (Test-Path $filePath)) {
                throw "File '$filePath' not found"
            }
            
            # Ensure Docker image is available
            Ensure-DockerImage -ImageName $config.image
            
            # Prepare paths
            $currentDir = (Get-Location).Path
            $relativePath = $filePath.Replace("$currentDir\", "").Replace("\", "/")
            $containerPath = "$($config.mount_path)/$relativePath"
            
            # Get validated resource limits
            $limits = Get-ValidatedResourceLimits -Config $config
            
            # Build Docker arguments
            $dockerArgs = @(
                "run",
                "--rm",
                "-v", "`"${currentDir}:$($config.mount_path)`"",
                "-w", $config.mount_path,
                "--cpus=$($limits.cpu)",
                "--memory=$($limits.memory)"
            )
            
            # Add security constraints
            $dockerArgs += @(
                
                # "--read-only",                   # Read-only filesystem
                # "--tmpfs", "/tmp:rwx,size=100m", # Writable temp directory
                "--network", "none"              # No network access
            )
            
            $dockerArgs += $config.image
            
            # Replace {file} placeholder in command and split into tokens
            $command = ($config.command -replace '\{file\}', $containerPath) -split ' ' | Where-Object { $_ }
            $dockerArgs += $command
            
            # Append any extra arguments
            if ($Args.Length -gt 1) {
                $dockerArgs += $Args[1..($Args.Length - 1)]
            }
            
            Write-ExecutionLog -Level 'INFO' -Message "Executing Docker container" -Context @{
                Language = $Language
                Image = $config.image
                File = $relativePath
                Command = $command -join ' '
                ResourceLimits = $limits
            }
            
            # Execute with timeout
            $result = Invoke-DockerWithTimeout -DockerArgs $dockerArgs -TimeoutSeconds $config.timeout
            
            $stopwatch.Stop()
            Write-ExecutionLog -Level 'INFO' -Message "Execution completed successfully" -Context @{
                Language = $Language
                File = $relativePath
                ExecutionTime = $stopwatch.Elapsed.TotalSeconds
                ExitCode = $LASTEXITCODE
            }
            
            return $result
        }
        catch {
            # $stopwatch.Stop()
            if ($stopwatch){ $stopwatch.Stop()}
            Write-ExecutionLog -Level 'ERROR' -Message "Execution failed: $($_.Exception.Message)" -Context @{
                Language = $Language
                File = if ($Args) { $Args[0] } else { 'Unknown' }
                ExecutionTime = $stopwatch.Elapsed.TotalSeconds
            }
            throw
        }
        
    }
}

function Invoke-FileByExtension {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath
    )
    
    try {
        $safePath = Get-SafePath -Path $FilePath
        $extension = [IO.Path]::GetExtension($safePath).TrimStart('.')
        
        Write-ExecutionLog -Level 'DEBUG' -Message "Detecting language by extension" -Context @{
            File = $FilePath
            Extension = $extension
        }
        
        foreach ($lang in $script:CONFIG.Keys) {
            if ($script:CONFIG[$lang].extensions -contains $extension) {
                Write-ExecutionLog -Level 'INFO' -Message "Language detected by extension" -Context @{
                    Language = $lang
                    Extension = $extension
                }
                return Invoke-LanguageCommand -Language $lang -Args $FilePath
            }
        }
        
        # If no language found, show available extensions
        $availableExtensions = @()
        foreach ($lang in $script:CONFIG.Keys) {
            $availableExtensions += $script:CONFIG[$lang].extensions | ForEach-Object { ".$_" }
        }
        
        throw "No language handler configured for extension '.$extension'. Available extensions: $($availableExtensions -join ', ')"
    }
    catch {
        Write-ExecutionLog -Level 'ERROR' -Message "File execution by extension failed: $($_.Exception.Message)"
        throw
    }
}
#endregion

#region Dynamic Function Generation
function Initialize-LanguageFunctions {
    [CmdletBinding()]
    param()
    
    Write-ExecutionLog -Level 'INFO' -Message "Creating dynamic language functions"
    
    foreach ($lang in $script:CONFIG.Keys) {
        try {
            $functionScript = @"
function global:$lang {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments=`$true)]
        [string[]]`$Args
    )
    
    return Invoke-LanguageCommand -Language '$lang' -Args `$Args
}
"@
            
            $scriptBlock = [scriptblock]::Create($functionScript)
            . $scriptBlock
            
            Write-ExecutionLog -Level 'DEBUG' -Message "Created function for language: $lang"
        }
        catch {
            Write-ExecutionLog -Level 'WARN' -Message "Failed to create function for language '$lang': $($_.Exception.Message)"
        }
    }
}
#endregion

#region Initialization
function Initialize-LangDocker {
    [CmdletBinding()]
    param()
    
    try {
        Write-ExecutionLog -Level 'INFO' -Message "Initializing LangDocker"
        
        # Create log directory if it doesn't exist
        $logDir = Split-Path $LOG_PATH -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        }
        
        # Initialize configuration
        Initialize-Configuration
        
        # Check Docker availability
        if (-not (Test-DockerAvailable)) {
            Write-ExecutionLog -Level 'WARN' -Message "Docker is not available. Some functionality may be limited"
        }
        
        # Create dynamic language functions
        Initialize-LanguageFunctions
        
        # Set up aliases
        Set-Alias -Name "runlang" -Value "Invoke-FileByExtension" -Scope Global -Force
        
        Write-ExecutionLog -Level 'INFO' -Message "LangDocker initialization completed successfully" -Context @{
            ConfiguredLanguages = $script:CONFIG.Keys.Count
            ConfigPath = $CONFIG_PATH
            LogPath = $LOG_PATH
        }
    }
    catch {
        Write-ExecutionLog -Level 'ERROR' -Message "LangDocker initialization failed: $($_.Exception.Message)"
        throw
    }
}
#endregion

#region Module Exports and Initialization
# Export main functions
Export-ModuleMember -Function @(
    'Invoke-LanguageCommand',
    'Invoke-FileByExtension',
    'Initialize-LangDocker'
) -Alias @('runlang')

# Initialize on script load
try {
    Initialize-LangDocker
    Write-Host "LangDocker loaded successfully! Use 'runlang <file>' to execute files by extension." -ForegroundColor Green
}
catch {
    Write-Host "LangDocker initialization failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Please check your configuration file at $CONFIG_PATH" -ForegroundColor Yellow
}
#endregion
