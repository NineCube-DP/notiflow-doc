#Requires -Version 5.1
<#
.SYNOPSIS
    NotiFlow installer and manager for Windows.
.DESCRIPTION
    Downloads and runs NotiFlow using Docker or Podman.
    Run again after installation to update, reconfigure, or uninstall.
.EXAMPLE
    irm https://raw.githubusercontent.com/NineCube-DP/notiflow-doc/main/start.ps1 | iex
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

# ─── Config ───────────────────────────────────────────────────────────────────
$VERSION     = "1.1.0"
$REPO_RAW    = "https://raw.githubusercontent.com/NineCube-DP/notiflow-doc/main"
$INSTALL_DIR = if ($env:NOTIFLOW_DIR) { $env:NOTIFLOW_DIR } else { "$HOME\.notiflow" }

# ─── TUI ──────────────────────────────────────────────────────────────────────
$SPIN_FRAMES = [char[]]'⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
try   { $TW = [Math]::Min([Console]::WindowWidth, 64) }
catch { $TW = 64 }

function Write-Ok   { param([string]$msg) Write-Host "  `u{2713}  $msg" -ForegroundColor Green }
function Write-Warn { param([string]$msg) Write-Host "  !  $msg" -ForegroundColor Yellow }
function Write-Info { param([string]$msg) Write-Host "  `u{00B7}  $msg" -ForegroundColor DarkGray }

function Invoke-Die {
    param([string]$msg)
    Write-Host "  `u{2717}  $msg" -ForegroundColor Red
    exit 1
}

function Write-Hr {
    Write-Host ("  " + ([string][char]0x2500 * ($script:TW - 2))) -ForegroundColor DarkGray
}

function Write-Section {
    param([string]$label)
    $dashes = [Math]::Max(1, $script:TW - $label.Length - 7)
    Write-Host ""
    Write-Host ("  " + [char]0x2500 + [char]0x2500 + [char]0x2500 + " " + $label + " " + ([string][char]0x2500 * $dashes)) -ForegroundColor DarkGray
    Write-Host ""
}

function Draw-Menu {
    param([string]$title, [string[]]$items)
    $inner = $script:TW - 6
    Write-Host ""
    Write-Host ("  " + [char]0x250C + ([string][char]0x2500 * $inner) + [char]0x2510) -ForegroundColor DarkGray
    if ($title) {
        $w = $inner - 4
        Write-Host ("  " + [char]0x2502 + "  ") -NoNewline -ForegroundColor DarkGray
        Write-Host $title.PadRight($w) -NoNewline
        Write-Host ("  " + [char]0x2502) -ForegroundColor DarkGray
        Write-Host ("  " + [char]0x251C + ([string][char]0x2500 * $inner) + [char]0x2524) -ForegroundColor DarkGray
    }
    $n = 1
    foreach ($item in $items) {
        $w = $inner - 7
        Write-Host ("  " + [char]0x2502 + "  ") -NoNewline -ForegroundColor DarkGray
        Write-Host "[$n]  " -NoNewline -ForegroundColor Blue
        Write-Host $item.PadRight($w) -NoNewline
        Write-Host ([char]0x2502) -ForegroundColor DarkGray
        $n++
    }
    Write-Host ("  " + [char]0x2514 + ([string][char]0x2500 * $inner) + [char]0x2518) -ForegroundColor DarkGray
    Write-Host ""
}

function Invoke-WithSpinner {
    param([string]$Label, [scriptblock]$ScriptBlock, [object[]]$ArgumentList = @())

    $job = Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    $i   = 0
    while ($job.State -eq 'Running') {
        $frame = $script:SPIN_FRAMES[$i % $script:SPIN_FRAMES.Length]
        [Console]::Write("`r  $frame  $Label ")
        Start-Sleep -Milliseconds 80
        $i++
    }

    $null   = Receive-Job $job -Wait -ErrorAction SilentlyContinue
    $failed = $job.State -eq 'Failed'
    $errMsg = if ($failed -and $job.ChildJobs[0].JobStateInfo.Reason) {
        $job.ChildJobs[0].JobStateInfo.Reason.Message
    } else { $null }
    Remove-Job $job -Force

    if ($failed) {
        Write-Host ("`r  `u{2717}  " + $Label.PadRight(50)) -ForegroundColor Red
        if ($errMsg) { Write-Host "     $errMsg" -ForegroundColor Red }
        exit 1
    }
    Write-Host ("`r  `u{2713}  " + $Label.PadRight(50)) -ForegroundColor Green
}

function Invoke-Compose {
    param([string[]]$ExtraArgs)
    $parts = $script:COMPOSE -split '\s+'
    if ($parts.Length -gt 1) {
        & $parts[0] ($parts[1..($parts.Length - 1)] + $ExtraArgs)
    } else {
        & $parts[0] $ExtraArgs
    }
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

# ─── Helpers ──────────────────────────────────────────────────────────────────
function Get-EnvValue {
    param([string]$Key, [string]$Default = "")
    $envFile = Join-Path $script:INSTALL_DIR ".env"
    if (-not (Test-Path $envFile)) { return $Default }
    $escaped = [regex]::Escape($Key)
    $line    = Get-Content $envFile | Where-Object { $_ -match "^${escaped}=" } | Select-Object -First 1
    if ($line) { return $line.Substring($Key.Length + 1) }
    return $Default
}

function Get-RandPass {
    $buf = [byte[]]::new(20)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buf)
    return -join ($buf | ForEach-Object { $_.ToString('x2') })
}

function Get-RandSecret {
    $buf = [byte[]]::new(48)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buf)
    return [Convert]::ToBase64String($buf)
}

function Set-EnvValue {
    param([string]$Key, [string]$Value, [string]$File)
    $escaped  = [regex]::Escape($Key)
    $content  = Get-Content $File
    $replaced = $content | ForEach-Object {
        if ($_ -match "^${escaped}=") { "$Key=$Value" } else { $_ }
    }
    Set-Content -Path $File -Value $replaced -Encoding UTF8
}

function Merge-EnvFiles {
    param([string]$OldFile, [string]$TemplateFile, [string]$OutFile)
    $old = @{}
    Get-Content $OldFile | ForEach-Object {
        if ($_ -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { $old[$Matches[1]] = $Matches[2] }
    }
    $result = Get-Content $TemplateFile | ForEach-Object {
        if ($_ -match '^([A-Za-z_][A-Za-z0-9_]*)=') {
            $key = $Matches[1]
            if ($old.ContainsKey($key)) { return "$key=$($old[$key])" }
        }
        return $_
    }
    Set-Content -Path $OutFile -Value $result -Encoding UTF8
}

# ─── Banner ───────────────────────────────────────────────────────────────────
function Print-Banner {
    Write-Host ""
    Write-Host ' _   _       _   _ ' -NoNewline -ForegroundColor White
    Write-Host ' ______ _               ' -ForegroundColor Blue
    Write-Host '| \ | |     | | (_)' -NoNewline -ForegroundColor White
    Write-Host '|  ____| |              ' -ForegroundColor Blue
    Write-Host '|  \| | ___ | |_ _ ' -NoNewline -ForegroundColor White
    Write-Host '| |__  | | _____      __' -ForegroundColor Blue
    Write-Host '| . ` |/ _ \| __| |' -NoNewline -ForegroundColor White
    Write-Host '|  __| | |/ _ \ \ /\ / /' -ForegroundColor Blue
    Write-Host '| |\  | (_) | |_| |' -NoNewline -ForegroundColor White
    Write-Host '| |    | | (_) \ V  V / ' -ForegroundColor Blue
    Write-Host '|_| \_|\___/ \__|_|' -NoNewline -ForegroundColor White
    Write-Host '|_|    |_|\___/ \_/\_/  ' -ForegroundColor Blue
    Write-Host ("                              v" + $script:VERSION) -ForegroundColor DarkGray
    Write-Hr
    Write-Host ""
}

Print-Banner

# ─── Architecture ─────────────────────────────────────────────────────────────
$ARCH = $env:PROCESSOR_ARCHITECTURE
switch ($ARCH) {
    'AMD64' { $PLATFORM = "linux/amd64" }
    'ARM64' { $PLATFORM = "linux/arm64" }
    default { $PLATFORM = "" }
}

if ($PLATFORM) {
    $env:DOCKER_DEFAULT_PLATFORM = $PLATFORM
    Write-Info "Architecture: $ARCH ($PLATFORM)"
} else {
    Write-Warn "Unknown architecture '$ARCH' — using runtime default platform."
}

# ─── Runtime detection ────────────────────────────────────────────────────────
$COMPOSE            = ""
$DOCKER_DAEMON_WARN = ""

if (Get-Command docker -ErrorAction SilentlyContinue) {
    $null = & docker info 2>&1
    if ($LASTEXITCODE -eq 0) {
        $null = & docker compose version 2>&1
        if ($LASTEXITCODE -eq 0) {
            $COMPOSE = "docker compose"
        } elseif (Get-Command docker-compose -ErrorAction SilentlyContinue) {
            $COMPOSE = "docker-compose"
        } else {
            Invoke-Die "Docker found but Compose is not installed (tried 'docker compose' and 'docker-compose')."
        }
    } else {
        $DOCKER_DAEMON_WARN = "Docker binary found but daemon is not running — falling back to Podman."
    }
}

if (-not $COMPOSE) {
    if ($DOCKER_DAEMON_WARN) { Write-Warn $DOCKER_DAEMON_WARN }
    if (Get-Command podman -ErrorAction SilentlyContinue) {
        $null = & podman compose version 2>&1
        if ($LASTEXITCODE -eq 0) {
            $COMPOSE = "podman compose"
        } elseif (Get-Command podman-compose -ErrorAction SilentlyContinue) {
            $COMPOSE = "podman-compose"
        } else {
            Invoke-Die "Podman found but podman-compose is not installed. Install it with: pip3 install podman-compose"
        }
    } else {
        Invoke-Die "No container runtime found. Install Docker (https://docs.docker.com/get-docker/) or Podman (https://podman.io/getting-started/installation)."
    }
}

Write-Info "Runtime: $COMPOSE"

# ─── Setup directory ──────────────────────────────────────────────────────────
if (-not (Test-Path $INSTALL_DIR)) {
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
}
Set-Location $INSTALL_DIR

Write-Info "Working directory: $INSTALL_DIR"
Write-Host ""

# ─── Menu (existing installation) ─────────────────────────────────────────────
if (Test-Path (Join-Path $INSTALL_DIR ".env")) {
    Clear-Host
    Print-Banner

    Write-Info "Installed at $INSTALL_DIR"

    Draw-Menu "Manage NotiFlow" @(
        "Update       pull latest & restart"
        "Reconfigure  edit configuration"
        "Uninstall    remove all data"
        "Exit"
    )

    $MENU_CHOICE = $null
    while (-not $MENU_CHOICE) {
        Write-Host ("  " + [char]0x25B6 + "  Choose [1-4]: ") -NoNewline -ForegroundColor Blue
        $MENU_CHOICE = Read-Host
    }

    Write-Host ""

    switch ($MENU_CHOICE) {
        "1" {
            Write-Section "Updating"
            $destCompose = Join-Path $INSTALL_DIR "docker-compose.yaml"
            Invoke-WithSpinner "Downloading latest compose file" {
                param($url, $out)
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
            } @("$REPO_RAW/docker-compose.yaml", $destCompose)

            Write-Section "Pulling images"
            Invoke-Compose @('pull')

            Write-Section "Starting NotiFlow"
            Invoke-Compose @('up', '-d')

            $APP_PORT  = Get-EnvValue "APP_PORT" "8080"
            $DASH_PORT = Get-EnvValue "DASHBOARD_PORT" "3080"
            Write-Host ""
            Write-Hr
            Write-Ok "NotiFlow is up!"
            Write-Info "App         http://localhost:${APP_PORT}"
            Write-Info "Dashboard   http://localhost:${DASH_PORT}"
            Write-Hr
        }
        "2" {
            Write-Section "Reconfiguring"
            $destExample = Join-Path $INSTALL_DIR ".env.example"
            Invoke-WithSpinner "Downloading latest .env.example" {
                param($url, $out)
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
            } @("$REPO_RAW/.env.example", $destExample)

            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $BACKUP    = Join-Path $INSTALL_DIR ".env.backup.$timestamp"
            Copy-Item (Join-Path $INSTALL_DIR ".env") $BACKUP
            Write-Ok "Backed up config to $BACKUP"

            Merge-EnvFiles `
                -OldFile      $BACKUP `
                -TemplateFile (Join-Path $INSTALL_DIR ".env.example") `
                -OutFile      (Join-Path $INSTALL_DIR ".env")
            Write-Ok "Config rebased on latest template."

            $EDITOR_CMD = $null
            foreach ($e in @($env:EDITOR, 'notepad', 'vim', 'vi', 'nano')) {
                if ($e -and (Get-Command $e -ErrorAction SilentlyContinue)) {
                    $EDITOR_CMD = $e
                    break
                }
            }

            if ($EDITOR_CMD) {
                Write-Info "Opening .env in ${EDITOR_CMD} — save and quit to continue ..."
                Start-Process -Wait -FilePath $EDITOR_CMD -ArgumentList "`"$(Join-Path $INSTALL_DIR '.env')`""
            } else {
                Write-Warn "No text editor found. Edit $INSTALL_DIR\.env manually, then run:"
                Write-Info "  $COMPOSE up -d"
                exit 0
            }

            Write-Section "Restarting services"
            Invoke-Compose @('up', '-d')
            Write-Ok "NotiFlow restarted with new configuration."
        }
        "3" {
            Write-Host ""
            Write-Warn "This will stop all NotiFlow services and delete $INSTALL_DIR."
            Write-Host ("  " + [char]0x25B6 + "  Type 'yes' to confirm: ") -NoNewline -ForegroundColor Blue
            $CONFIRM = Read-Host
            Write-Host ""
            if ($CONFIRM -eq "yes") {
                Write-Section "Uninstalling"
                Invoke-Compose @('down', '-v')
                Write-Ok "Services stopped."
                Set-Location $HOME
                Remove-Item -Recurse -Force $INSTALL_DIR
                Write-Ok "NotiFlow uninstalled."
            } else {
                Write-Info "Uninstall aborted."
            }
        }
        "4" {
            Write-Info "Exiting."
        }
        default {
            Invoke-Die "Invalid option."
        }
    }
    exit 0
}

# ─── Fresh install ────────────────────────────────────────────────────────────
Write-Section "Installing NotiFlow"

$destCompose = Join-Path $INSTALL_DIR "docker-compose.yaml"
Invoke-WithSpinner "Downloading docker-compose.yaml" {
    param($url, $out)
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
} @("$REPO_RAW/docker-compose.yaml", $destCompose)

$destExample = Join-Path $INSTALL_DIR ".env.example"
Invoke-WithSpinner "Downloading .env.example" {
    param($url, $out)
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
} @("$REPO_RAW/.env.example", $destExample)

Copy-Item $destExample (Join-Path $INSTALL_DIR ".env")

$JWT    = Get-RandSecret
$DBPASS = Get-RandPass
$envFile = Join-Path $INSTALL_DIR ".env"

Set-EnvValue "POSTGRES_PASSWORD" $DBPASS $envFile
Set-EnvValue "JWT_SECRET"        $JWT    $envFile

$DASHPORT = Get-EnvValue "DASHBOARD_PORT" "3080"
Set-EnvValue "CORS_ORIGINS" "http://localhost:${DASHPORT}" $envFile

Write-Ok "Configuration generated."
Write-Warn "Review $INSTALL_DIR\.env before exposing this service publicly."

Write-Section "Pulling images"
Invoke-Compose @('pull')

Write-Section "Starting NotiFlow"
Invoke-Compose @('up', '-d')

# ─── Done ─────────────────────────────────────────────────────────────────────
$APP_PORT  = Get-EnvValue "APP_PORT" "8080"
$DASH_PORT = Get-EnvValue "DASHBOARD_PORT" "3080"

Write-Host ""
Write-Hr
Write-Ok "NotiFlow is up!"
Write-Info "App         http://localhost:${APP_PORT}"
Write-Info "Dashboard   http://localhost:${DASH_PORT}"
Write-Host ""
Write-Info "Useful commands (run from $INSTALL_DIR):"
Write-Info "  View logs : $COMPOSE logs -f"
Write-Info "  Stop      : $COMPOSE down"
Write-Info "  Update    : run this script again"
Write-Hr
