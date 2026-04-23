param(
    [Parameter(Position=0)]
    [ValidatePattern('^(stable|latest|\d+\.\d+\.\d+(-[^\s]+)?)$')]
    [string]$Target = "latest",
    [switch]$Bootstrapped
)

if (-not $Bootstrapped) {
    $tempScript = Join-Path $env:TEMP "cc-bootstrap.ps1"
    try {
        Invoke-WebRequest -Uri "https://daheiai.com/cc.ps1" -OutFile $tempScript -UseBasicParsing
    }
    catch {
        Write-Error "Failed to stage installer script: $_"
        exit 1
    }

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $tempScript -Target $Target -Bootstrapped
    exit $LASTEXITCODE
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = 'SilentlyContinue'

# Check for 32-bit Windows
if (-not [Environment]::Is64BitProcess) {
    Write-Error "Claude Code does not support 32-bit Windows. Please use a 64-bit version of Windows."
    exit 1
}

$GCS_BUCKET = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
$DOWNLOAD_DIR = "$env:USERPROFILE\.claude\downloads"
$INSTALL_BASE = "$env:USERPROFILE\.local\share\claude"
$VERSIONS_DIR = "$INSTALL_BASE\versions"
$BIN_DIR = "$env:USERPROFILE\.local\bin"
$LINK_PATH = "$BIN_DIR\claude.exe"
$CONFIG_PATH = "$env:USERPROFILE\.claude.json"
$LOCKS_DIR = "$env:USERPROFILE\.local\state\claude\locks"
$CACHE_DIR = "$env:USERPROFILE\.cache\claude\staging"
$DOWNLOADS_DIR = "$env:USERPROFILE\.claude\downloads"

function Write-Config {
    param(
        [string]$ConfigPath,
        [string]$FirstStartTime
    )

    $data = @{}
    if (Test-Path $ConfigPath) {
        try {
            $existing = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json -AsHashtable
            if ($existing) {
                $data = $existing
            }
        }
        catch {
            $data = @{}
        }
    }

    $data["installMethod"] = "native"
    $data["autoUpdates"] = $false
    $data["autoUpdatesProtectedForNative"] = $true
    if (-not $data.ContainsKey("firstStartTime")) {
        $data["firstStartTime"] = $FirstStartTime
    }

    $json = $data | ConvertTo-Json -Depth 10
    Set-Content -Path $ConfigPath -Value $json -Encoding UTF8
}

function Get-RemoteText {
    param(
        [string]$Url
    )

    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        try {
            $result = & curl.exe -fsSL --ssl-no-revoke --http1.1 --retry 5 --retry-delay 2 $Url
            if ($LASTEXITCODE -eq 0) {
                if ($result -is [array]) {
                    return ($result -join "`n")
                }
                return $result
            }
            Write-Warning "curl.exe failed with exit code $LASTEXITCODE, falling back to Invoke-RestMethod"
        }
        catch {
            Write-Warning "curl.exe failed: $_. Falling back to Invoke-RestMethod"
        }
    }

    return Invoke-RestMethod -Uri $Url -ErrorAction Stop
}

# Use native ARM64 binary on ARM64 Windows, x64 otherwise
if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
    $platform = "win32-arm64"
} else {
    $platform = "win32-x64"
}
New-Item -ItemType Directory -Force -Path $DOWNLOAD_DIR | Out-Null

# Always download latest version (which has the most up-to-date installer)
try {
    $version = (Get-RemoteText -Url "$GCS_BUCKET/latest").ToString().Trim()
}
catch {
    Write-Error "Failed to get latest version: $_"
    exit 1
}

try {
    $manifestText = Get-RemoteText -Url "$GCS_BUCKET/$version/manifest.json"
    if ($manifestText -is [string]) {
        $manifest = $manifestText | ConvertFrom-Json
    }
    else {
        $manifest = $manifestText
    }
    $checksum = $manifest.platforms.$platform.checksum
    $expectedSize = $manifest.platforms.$platform.size

    if (-not $checksum) {
        Write-Error "Platform $platform not found in manifest"
        exit 1
    }
}
catch {
    Write-Error "Failed to get manifest: $_"
    exit 1
}

# Download and verify
$binaryPath = "$DOWNLOAD_DIR\claude-$version-$platform.exe"
$downloadUrl = "$GCS_BUCKET/$version/$platform/claude.exe"

Write-Output "Claude Code version: $version"
Write-Output "Platform: $platform"
Write-Output "Download source: $downloadUrl"
Write-Output "Downloading Claude Code binary..."

try {
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -fL --ssl-no-revoke --http1.1 --retry 5 --retry-delay 2 -o $binaryPath $downloadUrl
        if ($LASTEXITCODE -ne 0) {
            throw "curl.exe failed with exit code $LASTEXITCODE"
        }
    }
    else {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $binaryPath -ErrorAction Stop
    }

    if ($expectedSize) {
        $actualSize = (Get-Item -Path $binaryPath).Length
        if ($actualSize -ne [int64]$expectedSize) {
            throw "Downloaded file size mismatch. Expected $expectedSize bytes, got $actualSize bytes"
        }
    }
}
catch {
    Write-Error "Failed to download binary: $_"
    if (Test-Path $binaryPath) {
        Remove-Item -Force $binaryPath
    }
    exit 1
}

# Calculate checksum
$actualChecksum = (Get-FileHash -Path $binaryPath -Algorithm SHA256).Hash.ToLower()

if ($actualChecksum -ne $checksum) {
    Write-Error "Checksum verification failed"
    Remove-Item -Force $binaryPath
    exit 1
}

# Install directly without invoking the bundled installer
Write-Output "Setting up Claude Code..."
try {
    New-Item -ItemType Directory -Force -Path $VERSIONS_DIR | Out-Null
    New-Item -ItemType Directory -Force -Path $BIN_DIR | Out-Null
    New-Item -ItemType Directory -Force -Path $LOCKS_DIR | Out-Null
    New-Item -ItemType Directory -Force -Path $CACHE_DIR | Out-Null
    New-Item -ItemType Directory -Force -Path $DOWNLOADS_DIR | Out-Null
    New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.claude\backups" | Out-Null

    $finalPath = "$VERSIONS_DIR\$version.exe"
    if (Test-Path $finalPath) {
        Remove-Item -Force $finalPath
    }
    Move-Item -Force $binaryPath $finalPath
    Copy-Item -Force $finalPath $LINK_PATH

    if (Test-Path $CONFIG_PATH) {
        Copy-Item -Force $CONFIG_PATH "$env:USERPROFILE\.claude\backups\.claude.json.backup.$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())" -ErrorAction SilentlyContinue
    }

    $firstStartTime = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Config -ConfigPath $CONFIG_PATH -FirstStartTime $firstStartTime

    Write-Output ""
    Write-Output "Claude Code successfully installed!"
    Write-Output ""
    Write-Output "Version: $version"
    Write-Output "Location: $LINK_PATH"
    Write-Output ""
    Write-Output "PATH target: $BIN_DIR"
    Write-Output "If claude is not found, add that directory to your user PATH and reopen PowerShell."
}
finally {
    try {
        if (Test-Path $binaryPath) {
            Remove-Item -Force $binaryPath
        }
    }
    catch {
        Write-Warning "Could not remove temporary file: $binaryPath"
    }
}

Write-Output ""
Write-Output "$([char]0x2705) Installation complete!"
Write-Output ""
