#Requires -Version 5.1
$ErrorActionPreference = "Continue"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
if ($PSScriptRoot) {
    $BASE = $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    $BASE = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $BASE = (Get-Location).Path
}

$PHP_DIR     = Join-Path $BASE "php"
$APACHE_DIR  = Join-Path $BASE "apache24"
$NGINX_DIR   = Join-Path $BASE "nginx"
$CONF_DIR    = Join-Path $BASE "conf"
$LOGS_DIR    = Join-Path $BASE "logs"
$VHOSTS_DIR  = Join-Path $CONF_DIR "vhosts"
$CONFIG_FILE = Join-Path $BASE "config.json"

# Port allocation constants
$FCGI_PORT_START = 9000
$HTTP_PORT_START = 80

# ---------------------------------------------------------------------------
# Console helpers
# ---------------------------------------------------------------------------
function Write-Ok   { param($msg) Write-Host "  [OK]   $msg" -ForegroundColor Green }
function Write-Info { param($msg) Write-Host "  [INFO] $msg" -ForegroundColor Cyan }
function Write-Warn { param($msg) Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Write-Err  { param($msg) Write-Host "  [ERR]  $msg" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# DOWNLOAD URLS
# ---------------------------------------------------------------------------
$NGINX_URL         = "https://nginx.org/download/nginx-1.28.0.zip"
$APACHE_BASE_URL   = "https://www.apachelounge.com/download/VS17/"
# No hardcoded Apache filename - Get-ApacheDownloadUrl discovers it live from the page

$PHP_RELEASES = @{
    "8.3.31" = "https://windows.php.net/downloads/releases/php-8.3.31-Win32-vs16-x64.zip"
    "8.2.31" = "https://windows.php.net/downloads/releases/php-8.2.31-Win32-vs16-x64.zip"
    "8.1.34" = "https://windows.php.net/downloads/releases/php-8.1.34-Win32-vs16-x64.zip"
    # Archived versions
    "8.0.30" = "https://windows.php.net/downloads/releases/archives/php-8.0.30-Win32-vs16-x64.zip"
    "7.4.33" = "https://windows.php.net/downloads/releases/archives/php-7.4.33-Win32-vc15-x64.zip"
    "7.3.33" = "https://windows.php.net/downloads/releases/archives/php-7.3.33-Win32-vc15-x64.zip"
}

# ---------------------------------------------------------------------------
# Dynamic port helpers
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Returns all TCP ports currently in use on 127.0.0.1 / 0.0.0.0
    (fast - uses netstat, not Get-NetTCPConnection which requires Admin)
#>
function Get-ActiveTcpPorts {
    $lines = netstat -ano 2>$null | Where-Object { $_ -match '^\s+TCP\s+' }
    $ports = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($line in $lines) {
        if ($line -match ':(\d+)\s') {
            $null = $ports.Add([int]$Matches[1])
        }
    }
    return $ports
}

<#
.SYNOPSIS
    Returns the ports already assigned to sites in the config (HTTP ports).
#>
function Get-ConfigHttpPorts {
    param($cfg)
    $set = [System.Collections.Generic.HashSet[int]]::new()
    if ($cfg.sites) {
        foreach ($s in $cfg.sites) {
            if ($s.port) { $null = $set.Add([int]$s.port) }
        }
    }
    return $set
}

<#
.SYNOPSIS
    Returns the fcgiPorts already assigned to sites in the config.
#>
function Get-ConfigFcgiPorts {
    param($cfg)
    $set = [System.Collections.Generic.HashSet[int]]::new()
    if ($cfg.sites) {
        foreach ($s in $cfg.sites) {
            if ($s.fcgiPort) { $null = $set.Add([int]$s.fcgiPort) }
        }
    }
    return $set
}

<#
.SYNOPSIS
    Finds the next free FCGI port starting at $FCGI_PORT_START,
    avoiding ports already claimed by other sites and live TCP connections.
#>
function Get-NextFcgiPort {
    param($cfg)
    $cfgUsed    = Get-ConfigFcgiPorts $cfg
    $activeUsed = Get-ActiveTcpPorts
    $p = $FCGI_PORT_START
    while ($cfgUsed.Contains($p) -or $activeUsed.Contains($p)) { $p++ }
    return $p
}

<#
.SYNOPSIS
    Returns the default HTTP port for new sites.
    All sites share port 80 - Nginx routes by server_name (virtual hosting).
    Only suggests 8080+ if port 80 is held by a non-Nginx process.
#>
function Get-NextHttpPort {
    param($cfg)
    # Port 80 is always the correct default for virtual hosting.
    # Multiple sites on the same port is intentional - Nginx routes by server_name.
    $activeUsed = Get-ActiveTcpPorts
    if (-not $activeUsed.Contains(80)) { return 80 }
    # Port 80 active - if nginx owns it, still return 80 (shared is fine)
    if (Get-Process -Name "nginx" -ErrorAction SilentlyContinue) { return 80 }
    # Something else owns port 80
    $p = 8080
    while ($activeUsed.Contains($p)) { $p++ }
    return $p
}

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------
function Initialize-Directories {
    foreach ($d in @($PHP_DIR, $APACHE_DIR, $NGINX_DIR, $CONF_DIR, $LOGS_DIR, $VHOSTS_DIR)) {
        if (-not (Test-Path $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }
}

function Load-Config {
    if (Test-Path $CONFIG_FILE) {
        try {
            $raw = Get-Content $CONFIG_FILE -Raw -Encoding UTF8
            return $raw | ConvertFrom-Json
        } catch {
            Write-Warn "config.json is malformed: $_"
        }
    }
    $default = '{"systemPhp":"","sites":[]}'
    $default | Set-Content $CONFIG_FILE -Encoding UTF8
    return $default | ConvertFrom-Json
}

function Save-Config {
    param($cfg)
    $cfg | ConvertTo-Json -Depth 5 | Set-Content $CONFIG_FILE -Encoding UTF8
}

<#
.SYNOPSIS
    Ensures every site has a valid, unique fcgiPort. Assigns new ones
    dynamically using Get-NextFcgiPort when missing. Also validates
    that no two sites share the same fcgiPort.
#>
function Repair-SiteConfig {
    param($cfg)

    if (-not $cfg.sites -or $cfg.sites.Count -eq 0) { return $false }

    $changed  = $false
    $usedFcgi = [System.Collections.Generic.HashSet[int]]::new()

    # First pass: collect already-assigned, unique fcgiPorts
    $duplicates = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($s in $cfg.sites) {
        if ($s.fcgiPort) {
            $port = [int]$s.fcgiPort
            if (-not $usedFcgi.Add($port)) {
                $null = $duplicates.Add($port)
            }
        }
    }

    # Rebuild used set without duplicates
    $usedFcgi.Clear()
    foreach ($s in $cfg.sites) {
        if ($s.fcgiPort -and -not $duplicates.Contains([int]$s.fcgiPort)) {
            $null = $usedFcgi.Add([int]$s.fcgiPort)
        }
    }

    # Second pass: only assign ports to sites that have NONE or a duplicate.
    # Do NOT check live TCP ports here - a port in TIME_WAIT after a kill should
    # not cause the site to be permanently reassigned a new port.
    foreach ($s in $cfg.sites) {
        $needsPort = (-not $s.fcgiPort) -or ($duplicates.Contains([int]$s.fcgiPort))
        if ($needsPort) {
            $p = $FCGI_PORT_START
            while ($usedFcgi.Contains($p)) { $p++ }
            $s | Add-Member -MemberType NoteProperty -Name fcgiPort -Value $p -Force
            $null = $usedFcgi.Add($p)
            $changed = $true
            Write-Info "Assigned fcgiPort $p to '$($s.name)'"
        }
    }

    if ($changed) { Save-Config $cfg }
    return $changed
}

# ---------------------------------------------------------------------------
# Install Nginx  (auto-discovers the latest stable Windows build from nginx.org)
# ---------------------------------------------------------------------------

function Get-NginxDownloadUrl {
    Write-Info "Checking nginx.org for the latest stable Windows build..."
    try {
        $page = Invoke-WebRequest -Uri "https://nginx.org/en/download.html" -UseBasicParsing -TimeoutSec 20
        # Match stable release links like: /download/nginx-1.28.0.zip
        $m = [regex]::Match($page.Content, '/download/(nginx-[\d.]+\.zip)')
        if (-not $m.Success) {
            Write-Warn "Could not parse Nginx version from download page. Using fallback URL."
            return $NGINX_URL
        }
        $filename = $m.Groups[1].Value
        $url = "https://nginx.org/download/$filename"
        Write-Info "Found: $filename"
        return $url
    } catch {
        Write-Warn "Page fetch failed: $_ - using fallback URL"
        return $NGINX_URL
    }
}

function Install-Nginx {
    $destZip = Join-Path $BASE "nginx.zip"
    $destDir = Join-Path $BASE "nginx"

    $nginxUrl = Get-NginxDownloadUrl
    Write-Info "Downloading from: $nginxUrl"

    try {
        Invoke-WebRequest -Uri $nginxUrl -OutFile $destZip -UseBasicParsing

        if (Test-Path $destDir) { Remove-Item $destDir -Recurse -Force }

        Expand-Archive $destZip -DestinationPath $BASE -Force

        $extracted = Get-ChildItem $BASE | Where-Object { $_.PSIsContainer -and $_.Name -like "nginx-*" } | Select-Object -First 1

        if (-not $extracted) {
            Write-Err "Could not find extracted nginx folder under $BASE"
            return
        }

        Rename-Item $extracted.FullName $destDir
        Remove-Item $destZip -Force -ErrorAction SilentlyContinue

        Write-Ok "Nginx installed at $destDir"
    } catch {
        Write-Err "Failed to install Nginx: $_"
        Remove-Item $destZip -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Install Apache  (auto-discovers the latest filename from apachelounge.com)
# ---------------------------------------------------------------------------

function Get-ApacheDownloadUrl {
    Write-Info "Checking apachelounge.com for the latest Apache Win64 VS17 build..."
    try {
        $page = Invoke-WebRequest -Uri $APACHE_BASE_URL -UseBasicParsing -TimeoutSec 20
        # Match filenames like: httpd-2.4.66-251206-win64-VS17.zip
        $matches2 = [regex]::Matches($page.Content, 'httpd-[\d.]+-\d+-[Ww]in64-VS17\.zip')
        if ($matches2.Count -eq 0) {
            Write-Warn "Could not parse a filename from the download page."
            return $null
        }
        # Take the first match (page lists newest first)
        $filename = $matches2[0].Value
        # Strip the /binaries/ sub-path that older builds used - files now live directly under VS17/
        $url = "$($APACHE_BASE_URL)binaries/$filename"
        # Quick HEAD check - if it redirects/fails try without /binaries/
        try {
            $head = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            if ($head.StatusCode -ne 200) { throw "not 200" }
        } catch {
            $url = "$($APACHE_BASE_URL)$filename"
        }
        Write-Info "Found: $filename"
        return $url
    } catch {
        Write-Warn "Page fetch failed: $_"
        return $null
    }
}

function Install-Apache {
    $destZip    = Join-Path $BASE "apache.zip"
    $extractDir = Join-Path $BASE "apache_extract"
    $finalDir   = Join-Path $BASE "apache24"

    $apacheUrl = Get-ApacheDownloadUrl
    if (-not $apacheUrl) {
        Write-Err "Could not determine Apache download URL. Check your internet connection"
        Write-Info "or visit https://www.apachelounge.com/download/VS17/ to download manually"
        Write-Info "and extract the Apache24 folder into: $finalDir"
        return
    }

    Write-Info "Downloading from: $apacheUrl"

    try {
        Invoke-WebRequest -Uri $apacheUrl -OutFile $destZip -UseBasicParsing

        if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }

        Expand-Archive $destZip -DestinationPath $extractDir -Force

        $apacheFolder = Get-ChildItem $extractDir -Recurse |
            Where-Object { $_.PSIsContainer -and $_.Name -eq "Apache24" } |
            Select-Object -First 1

        if (-not $apacheFolder) {
            Write-Err "Apache24 folder not found inside the archive."
            return
        }

        if (Test-Path $finalDir) { Remove-Item $finalDir -Recurse -Force }

        Move-Item $apacheFolder.FullName $finalDir
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $destZip    -Force          -ErrorAction SilentlyContinue

        Write-Ok "Apache installed at $finalDir"
    } catch {
        Write-Err "Failed to install Apache: $_"
        Remove-Item $destZip    -Force -ErrorAction SilentlyContinue
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# PHP Install
# ---------------------------------------------------------------------------
function Install-PHP {
    param([string]$version)

    if (-not $PHP_RELEASES.ContainsKey($version)) {
        Write-Err "Unknown PHP version: $version"
        Write-Info "Available: $($PHP_RELEASES.Keys | Sort-Object | Join-String -Separator ', ')"
        return
    }

    $dest   = Join-Path $PHP_DIR $version
    $phpExe = Join-Path $dest "php.exe"

    if (Test-Path $phpExe) {
        Write-Warn "PHP $version already installed at $dest"
        return
    }

    $url     = $PHP_RELEASES[$version]
    $zipPath = Join-Path $env:TEMP "php-$version.zip"

    Write-Info "Downloading PHP $version from $url ..."

    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($url, $zipPath)
        Write-Ok "Download complete"
    } catch {
        Write-Err "Download failed: $_"
        return
    }

    Write-Info "Extracting to $dest ..."
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    try {
        Expand-Archive -Path $zipPath -DestinationPath $dest -Force
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Err "Extraction failed: $_"
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        return
    }

    # Create php.ini with common extensions enabled and CGI settings correct
    $iniSrc = Join-Path $dest "php.ini-development"
    $iniDst = Join-Path $dest "php.ini"
    if (Test-Path $iniSrc) {
        $content = Get-Content $iniSrc -Raw

        # Extensions
        $content = $content -replace ";extension=curl",      "extension=curl"
        $content = $content -replace ";extension=mbstring",  "extension=mbstring"
        $content = $content -replace ";extension=openssl",   "extension=openssl"
        $content = $content -replace ";extension=pdo_mysql", "extension=pdo_mysql"
        $content = $content -replace ";extension=mysqli",    "extension=mysqli"
        $content = $content -replace ";extension=gd",        "extension=gd"
        $content = $content -replace ";extension=zip",       "extension=zip"

        # Absolute extension_dir so PHP finds DLLs regardless of working directory
        $extDir  = Join-Path $dest "ext"
        $extDirFwd = $extDir -replace "\\", "/"
        $content = $content -replace '(;?\s*extension_dir\s*=\s*"ext")', "extension_dir = `"$extDirFwd`""

        # CGI settings - CRITICAL for php-cgi.exe running standalone under Nginx
        # cgi.force_redirect = 0  (default 1 causes immediate crash when not behind Apache/IIS)
        $content = $content -replace "cgi\.force_redirect\s*=\s*1",  "cgi.force_redirect = 0"
        $content = $content -replace ";cgi\.force_redirect\s*=\s*1", "cgi.force_redirect = 0"
        # cgi.fix_pathinfo = 0  (security: prevent path traversal via SCRIPT_FILENAME)
        $content = $content -replace ";cgi\.fix_pathinfo\s*=\s*1",   "cgi.fix_pathinfo = 0"
        $content = $content -replace "cgi\.fix_pathinfo\s*=\s*1",    "cgi.fix_pathinfo = 0"

        # Write without BOM - some PHP internals break on BOM in php.ini
        [System.IO.File]::WriteAllText($iniDst, $content, [System.Text.UTF8Encoding]::new($false))
        Write-Ok "php.ini created with extensions + CGI settings fixed"
    }

    Write-Ok "PHP $version installed successfully at $dest"
}

function Repair-PhpIni {
    param([string]$version)

    $dest   = Join-Path $PHP_DIR $version
    $iniDst = Join-Path $dest "php.ini"

    if (-not (Test-Path $iniDst)) {
        Write-Warn "php.ini not found at $iniDst"
        return $false
    }

    $content = [System.IO.File]::ReadAllText($iniDst)

    # ---- extension_dir: set to absolute path --------------------------------
    $extDirFwd = (Join-Path $dest "ext") -replace "\\", "/"
    $content   = $content -replace '(?m)^;?\s*extension_dir\s*=.*$', "extension_dir = `"$extDirFwd`""

    # ---- cgi.force_redirect -------------------------------------------------
    # php.ini-development has "; cgi.force_redirect = 1" (note space after ;)
    # Check what's actually there first so we can report it:
    $frMatch = [regex]::Match($content, '(?m)^.*(cgi\.force_redirect.*)$')
    if ($frMatch.Success) {
        Write-Info "cgi.force_redirect current value: $($frMatch.Value.Trim())"
    }
    # Replace ALL forms: commented or not, any whitespace around ; and =
    $content = $content -replace '(?m)^;?\s*cgi\.force_redirect\s*=\s*\S+\s*$', "cgi.force_redirect = 0"

    # Verify the replacement worked
    $frAfter = [regex]::Match($content, '(?m)^.*(cgi\.force_redirect.*)$')
    if ($frAfter.Success) {
        Write-Info "cgi.force_redirect after patch:   $($frAfter.Value.Trim())"
    } else {
        # Line wasn't found at all - append it explicitly
        $content = $content.TrimEnd() + "`r`ncgi.force_redirect = 0`r`n"
        Write-Info "cgi.force_redirect not found - appended: cgi.force_redirect = 0"
    }

    # ---- cgi.fix_pathinfo ---------------------------------------------------
    $content = $content -replace '(?m)^;?\s*cgi\.fix_pathinfo\s*=\s*\S+\s*$', "cgi.fix_pathinfo = 0"
    # Append if missing
    if ($content -notmatch '(?m)^cgi\.fix_pathinfo\s*=') {
        $content = $content.TrimEnd() + "`r`ncgi.fix_pathinfo = 0`r`n"
    }

    # Write without BOM
    [System.IO.File]::WriteAllText($iniDst, $content, [System.Text.UTF8Encoding]::new($false))
    Write-Ok "php.ini repaired: $iniDst"
    return $true
}
function Set-SystemDefaultPHP {
    param([string]$version)

    $phpBinDir = Join-Path $PHP_DIR $version
    $phpExe    = Join-Path $phpBinDir "php.exe"

    if (-not (Test-Path $phpExe)) {
        Write-Err "PHP $version is not installed. Install it first."
        return
    }

    try {
        $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        $parts       = $machinePath -split ";" | Where-Object { $_ }
        # Remove any existing PHP paths managed by this tool
        $filtered    = $parts | Where-Object { $_ -notmatch [regex]::Escape($PHP_DIR) }
        $newPath     = ($filtered + $phpBinDir) -join ";"
        [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
        $env:Path    = $phpBinDir + ";" + $env:Path
        Write-Ok "System default PHP set to $version"
        Write-Info "Open a new terminal window to use 'php' globally"
    } catch {
        Write-Err "Could not update system PATH (run as Administrator): $_"
    }

    $cfg = Load-Config
    $cfg | Add-Member -MemberType NoteProperty -Name systemPhp -Value $version -Force
    Save-Config $cfg
}

function Get-InstalledPHP {
    if (-not (Test-Path $PHP_DIR)) { return @() }
    $dirs = Get-ChildItem $PHP_DIR -Directory -ErrorAction SilentlyContinue
    if (-not $dirs) { return @() }
    return @($dirs | Where-Object { Test-Path (Join-Path $_.FullName "php.exe") } | Select-Object -ExpandProperty Name | Sort-Object -Descending)
}

function Choose-InstalledPHP {
    param([string]$prompt = "Select PHP version")

    $installed = @(Get-InstalledPHP)
    if ($installed.Count -eq 0) {
        Write-Warn "No PHP versions installed. Install one first (option 7)."
        return $null
    }

    $cfg = Load-Config
    $currentDefault = $cfg.systemPhp

    Write-Host "  Installed PHP versions:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $installed.Count; $i++) {
        $ver    = $installed[$i]
        $marker = if ($ver -eq $currentDefault) { " (current default)" } else { "" }
        Write-Host ("  [{0}] PHP {1}{2}" -f ($i + 1), $ver, $marker)
    }
    Write-Host ""

    $selection = Read-Host "  $prompt (enter number)"
    $idx = 0
    if ([int]::TryParse($selection.Trim(), [ref]$idx) -and $idx -ge 1 -and $idx -le $installed.Count) {
        return $installed[$idx - 1]
    }

    Write-Warn "Invalid selection."
    return $null
}

# ---------------------------------------------------------------------------
# Vhost writers
# ---------------------------------------------------------------------------
function Write-ApacheVHost {
    param($site)

    $phpCgi    = Join-Path $PHP_DIR "$($site.phpVer)\php-cgi.exe"
    $vhostFile = Join-Path $VHOSTS_DIR "$($site.name).conf"
    $sslBlock  = ""

    if ($site.ssl) {
        $certDir  = Join-Path $CONF_DIR "ssl"
        New-Item $certDir -Force -ItemType Directory | Out-Null
        $certFile   = Join-Path $certDir "$($site.name).crt"
        $keyFile    = Join-Path $certDir "$($site.name).key"
        $opensslExe = Join-Path $APACHE_DIR "bin\openssl.exe"
        if ((-not (Test-Path $certFile)) -and (Test-Path $opensslExe)) {
            & $opensslExe req -x509 -nodes -days 365 -newkey rsa:2048 `
                -keyout $keyFile -out $certFile `
                -subj "/CN=$($site.name)" 2>$null
            Write-Ok "SSL cert created for $($site.name)"
        }
        $sslBlock = "    SSLEngine on`n    SSLCertificateFile `"$certFile`"`n    SSLCertificateKeyFile `"$keyFile`""
    }

    $conf  = "<VirtualHost *:$($site.port)>`n"
    $conf += "    ServerName   $($site.name)`n"
    $conf += "    DocumentRoot `"$($site.root)`"`n`n"
    $conf += "    FcgidInitialEnv PHPRC `"$PHP_DIR\$($site.phpVer)`"`n"
    $conf += "    AddHandler fcgid-script .php`n"
    $conf += "    FcgidWrapper `"$phpCgi`" .php`n"
    if ($sslBlock) { $conf += "`n$sslBlock`n" }
    $conf += "`n    ErrorLog  `"$LOGS_DIR\$($site.name)-error.log`"`n"
    $conf += "    CustomLog `"$LOGS_DIR\$($site.name)-access.log`" combined`n`n"
    $conf += "    <Directory `"$($site.root)`">`n"
    $conf += "        AllowOverride All`n"
    $conf += "        Require all granted`n"
    $conf += "        Options -Indexes +FollowSymLinks`n"
    $conf += "    </Directory>`n"
    $conf += "</VirtualHost>`n"

    # UTF-8 without BOM - Apache cannot parse files with a BOM
    [System.IO.File]::WriteAllText($vhostFile, $conf, [System.Text.UTF8Encoding]::new($false))
    Write-Ok "Apache vhost written: $vhostFile"
}

function Write-NginxVHost {
    param($site)

    # Use .conf extension - nginx.conf already has: include ../../conf/vhosts/*.conf
    # Our previous .nginx.conf extension was never matched by that glob.
    $vhostFile    = Join-Path $VHOSTS_DIR "$($site.name).conf"
    $vhostFileOld = Join-Path $VHOSTS_DIR "$($site.name).nginx.conf"
    $rootFwd      = $site.root -replace "\\", "/"
    $logsFwd      = $LOGS_DIR  -replace "\\", "/"

    # Remove stale .nginx.conf files from previous script versions
    if (Test-Path $vhostFileOld) {
        Remove-Item $vhostFileOld -Force -ErrorAction SilentlyContinue
        Write-Info "Removed stale: $vhostFileOld"
    }

    $conf  = "server {`n"
    $conf += "    listen       $($site.port);`n"
    $conf += "    server_name  $($site.name);`n"
    $conf += "    root         `"$rootFwd`";`n"
    $conf += "    index        index.php index.html;`n`n"
    $conf += "    location ~ \.php$ {`n"
    $conf += "        fastcgi_pass   127.0.0.1:$($site.fcgiPort);`n"
    $conf += "        fastcgi_index  index.php;`n"
    $conf += "        fastcgi_param  SCRIPT_FILENAME `$document_root`$fastcgi_script_name;`n"
    $conf += "        include        fastcgi_params;`n"
    $conf += "    }`n`n"
    $conf += "    location / {`n"
    $conf += "        try_files `$uri `$uri/ /index.php?`$query_string;`n"
    $conf += "    }`n`n"
    $conf += "    error_log  `"$logsFwd/$($site.name)-error.log`";`n"
    $conf += "    access_log `"$logsFwd/$($site.name)-access.log`";`n"
    $conf += "}`n"

    # Write without BOM - Nginx cannot parse BOM bytes
    [System.IO.File]::WriteAllText($vhostFile, $conf, [System.Text.UTF8Encoding]::new($false))
    Write-Ok "Nginx vhost written: $vhostFile  (FCGI on :$($site.fcgiPort))"
}

# ---------------------------------------------------------------------------
# Hosts file
# ---------------------------------------------------------------------------
function Add-HostsEntry {
    param([string]$hostname)
    $hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
    $entry     = "127.0.0.1   $hostname"
    try {
        $existing = Get-Content $hostsFile -ErrorAction SilentlyContinue
        if ($existing -notcontains $entry) {
            Add-Content $hostsFile $entry
            Write-Ok "Added '$hostname' to hosts file"
        } else {
            Write-Info "'$hostname' already in hosts file"
        }
    } catch {
        Write-Warn "Cannot update hosts file - need Administrator rights."
        Write-Warn "Add this line manually to: $hostsFile"
        Write-Warn "  $entry"
    }
}

# ---------------------------------------------------------------------------
# Site management
# ---------------------------------------------------------------------------
function Add-Site {
    param(
        [string]$Name,
        [string]$Root,
        [int]   $Port   = 0,    # 0 = auto-assign
        [string]$PhpVer = "",
        [string]$Server = "Apache",
        [bool]  $SSL    = $false,
        [int]   $FcgiPort = 0   # 0 = auto-assign
    )

    $Server = if ($Server) { $Server.Trim() } else { "Apache" }
    if ($Server -notin @("Apache", "Nginx")) { $Server = "Apache" }

    if (-not $Name) { Write-Err "Hostname is required.";       return }
    if (-not $Root) { Write-Err "Document root is required.";  return }

    $cfg = Load-Config
    Repair-SiteConfig $cfg | Out-Null
    $cfg = Load-Config

    # --- HTTP port: default to 80. Multiple sites on port 80 is correct -
    # Nginx routes by server_name (hostname), not port.
    if ($Port -le 0) {
        $Port = Get-NextHttpPort $cfg
    }
    Write-Info "HTTP port: $Port  (sites share port 80 via virtual hosting)"

    # --- Auto-assign FCGI port if not provided or 0 (Nginx only, but store for all)
    if ($FcgiPort -le 0) {
        $FcgiPort = Get-NextFcgiPort $cfg
        Write-Info "Auto-assigned FCGI port $FcgiPort"
    } else {
        $cfgFcgi = Get-ConfigFcgiPorts $cfg
        if ($cfgFcgi.Contains($FcgiPort)) {
            Write-Err "FCGI port $FcgiPort is already in use by another site."
            $FcgiPort = Get-NextFcgiPort $cfg
            Write-Warn "Using $FcgiPort instead."
        }
    }

    # --- Default PHP version
    if (-not $PhpVer) {
        $installed = @(Get-InstalledPHP)
        if ($installed.Count -gt 0) {
            $PhpVer = $installed[0]
        } elseif ($cfg.systemPhp) {
            $PhpVer = $cfg.systemPhp
        } else {
            $PhpVer = "8.3.31"
        }
        Write-Info "Using PHP $PhpVer"
    }

    $site = [PSCustomObject]@{
        name     = $Name
        root     = $Root
        port     = $Port
        phpVer   = $PhpVer
        server   = $Server
        ssl      = $SSL
        running  = $false
        fcgiPort = $FcgiPort
    }

    if ($Server -ieq "Apache") {
        Write-ApacheVHost $site
    } else {
        Write-NginxVHost $site
    }

    Add-HostsEntry $Name

    # Reload config and append (in case Repair-SiteConfig changed it)
    $cfg = Load-Config
    $sitesList = [System.Collections.ArrayList]@()
    if ($cfg.sites) { foreach ($s in $cfg.sites) { $sitesList.Add($s) | Out-Null } }
    $sitesList.Add($site) | Out-Null
    $cfg | Add-Member -MemberType NoteProperty -Name sites -Value $sitesList -Force
    Save-Config $cfg

    Write-Ok "Site '$Name' added - HTTP :$Port  FCGI :$FcgiPort  Server: $Server  PHP: $PhpVer"
}

function Remove-Site {
    param([string]$name)

    $cfg = Load-Config
    Repair-SiteConfig $cfg | Out-Null
    $cfg = Load-Config

    $site = $cfg.sites | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if (-not $site) { Write-Err "Site '$name' not found."; return }

    # Remove vhost config files
    $apacheConf = Join-Path $VHOSTS_DIR "$name.conf"
    $nginxConf  = Join-Path $VHOSTS_DIR "$name.nginx.conf"
    Remove-Item $apacheConf -Force -ErrorAction SilentlyContinue
    Remove-Item $nginxConf  -Force -ErrorAction SilentlyContinue

    $sitesList = [System.Collections.ArrayList]@()
    foreach ($s in $cfg.sites) {
        if ($s.name -ne $name) { $sitesList.Add($s) | Out-Null }
    }
    $cfg | Add-Member -MemberType NoteProperty -Name sites -Value $sitesList -Force
    Save-Config $cfg

    Write-Ok "Site '$name' removed. HTTP port $($site.port) and FCGI port $($site.fcgiPort) are now free."
}

function Start-Site {
    param([string]$name)

    $cfg  = Load-Config
    Repair-SiteConfig $cfg | Out-Null
    $cfg  = Load-Config
    $site = $cfg.sites | Where-Object { $_.name -eq $name } | Select-Object -First 1

    if (-not $site) {
        Write-Err "Site '$name' not found. Use option 2 to list sites."
        return
    }

    $phpBin = Join-Path $PHP_DIR "$($site.phpVer)\php.exe"
    if (-not (Test-Path $phpBin)) {
        Write-Err "PHP $($site.phpVer) not installed. Use option 7 to install it."
        return
    }

    if ($site.server -ieq "Apache") {
        Write-ApacheVHost $site
        $httpd = Join-Path $APACHE_DIR "bin\httpd.exe"
        if (Test-Path $httpd) {
            $conf = Join-Path $APACHE_DIR "conf\httpd.conf"
            Start-Process $httpd -ArgumentList "-f `"$conf`"" -WindowStyle Hidden
            Write-Ok "Apache started for '$name' on port $($site.port)"
        } else {
            Write-Warn "Apache not found at $httpd - falling back to PHP built-in server"
            Start-Process $phpBin -ArgumentList "-S 0.0.0.0:$($site.port) -t `"$($site.root)`"" -WindowStyle Hidden
            Write-Ok "PHP built-in server started for '$name' on port $($site.port)"
            Write-Info "Visit: http://localhost:$($site.port)"
        }
    } else {
        Write-NginxVHost $site
        $nginx = Join-Path $NGINX_DIR "nginx.exe"
        if (-not (Test-Path $nginx)) {
            Write-Err "Nginx not found at $nginx"
            return
        }

        # Vhost is written as .conf to match nginx's existing include ../../conf/vhosts/*.conf
        # No patching of nginx.conf needed - the include is already there.
        $vhostFile = Join-Path $VHOSTS_DIR "$($site.name).conf"
        if (Test-Path $vhostFile) {
            Write-Ok "Vhost ready: $vhostFile"
        }

        $phpCgi    = Join-Path $PHP_DIR "$($site.phpVer)\php-cgi.exe"
        $phpCgiDir = Join-Path $PHP_DIR $site.phpVer

        if (-not (Test-Path $phpCgi)) {
            Write-Warn "PHP-CGI binary not found at $phpCgi"
        } else {
            # Repair php.ini (cgi.force_redirect=0, absolute extension_dir)
            Repair-PhpIni $site.phpVer | Out-Null

            # Verify: look for the ASSIGNMENT line only (must have = sign, not just a comment)
            $iniPath    = Join-Path $phpCgiDir "php.ini"
            $iniContent = [System.IO.File]::ReadAllText($iniPath)
            $frLine     = ($iniContent -split "`n" | Where-Object { $_ -match '^cgi\.force_redirect\s*=' } | Select-Object -First 1)
            if ($frLine -match '=\s*0') {
                Write-Ok "php.ini: cgi.force_redirect = 0 (correct)"
            } elseif ($frLine) {
                Write-Warn "php.ini: cgi.force_redirect line is: $($frLine.Trim()) - expected 0"
            } else {
                Write-Warn "php.ini: cgi.force_redirect assignment not found - appending"
                [System.IO.File]::AppendAllText($iniPath, "`r`ncgi.force_redirect = 0`r`n")
            }

            # Kill any existing PHP-CGI on this FCGI port
            $portLines = netstat -ano 2>$null | Where-Object { $_ -match "127\.0\.0\.1:$($site.fcgiPort)\s|0\.0\.0\.0:$($site.fcgiPort)\s" }
            if ($portLines) {
                foreach ($line in $portLines) {
                    if ($line -match '\s+(\d+)\s*$') {
                        $oldPid = $Matches[1]
                        taskkill /PID $oldPid /F 2>$null | Out-Null
                        Write-Info "Killed old PHP-CGI PID $oldPid on port $($site.fcgiPort)"
                        break
                    }
                }
                # Wait for OS to fully release the port (TIME_WAIT can take 1-2s)
                Write-Info "Waiting for port $($site.fcgiPort) to be released..."
                $released = $false
                for ($w = 0; $w -lt 10; $w++) {
                    Start-Sleep -Milliseconds 600
                    $stillBound = netstat -ano 2>$null | Where-Object { $_ -match "127\.0\.0\.1:$($site.fcgiPort)\s|0\.0\.0\.0:$($site.fcgiPort)\s" }
                    if (-not $stillBound) { $released = $true; break }
                }
                if (-not $released) {
                    Write-Warn "Port $($site.fcgiPort) still appears bound after 6s - proceeding anyway"
                }
            }

            # Launch PHP-CGI with PHPRC pointing at the corrected php.ini
            $env:PHPRC = $phpCgiDir
            $proc = Start-Process `
                -FilePath         $phpCgi `
                -ArgumentList     "-b 127.0.0.1:$($site.fcgiPort)" `
                -WorkingDirectory $phpCgiDir `
                -WindowStyle      Hidden `
                -PassThru

            Write-Info "PHP-CGI launched (PID $($proc.Id)) - waiting for port $($site.fcgiPort)..."

            # Wait up to 6 seconds for the port to bind
            $bound = $false
            for ($i = 0; $i -lt 12; $i++) {
                Start-Sleep -Milliseconds 500
                if ($proc.HasExited) {
                    Write-Err "PHP-CGI (PID $($proc.Id)) exited with code $($proc.ExitCode)"
                    Write-Err "This almost always means cgi.force_redirect is still 1."
                    Write-Err "Check: $iniPath"
                    Write-Info "Relevant lines in php.ini:"
                    $iniContent -split "`n" | Where-Object { $_ -match 'force_redirect|fix_pathinfo|extension_dir' } | ForEach-Object { Write-Info "  $_" }
                    break
                }
                $check = netstat -ano 2>$null | Where-Object { $_ -match "127\.0\.0\.1:$($site.fcgiPort)\s|0\.0\.0\.0:$($site.fcgiPort)\s" }
                if ($check) { $bound = $true; break }
            }

            if ($bound) {
                Write-Ok "PHP-CGI (PID $($proc.Id)) listening on 127.0.0.1:$($site.fcgiPort)"
            } elseif (-not $proc.HasExited) {
                Write-Warn "PHP-CGI running (PID $($proc.Id)) but port not confirmed - Nginx may get 502 until it binds"
            }
        }

        if (-not (Get-Process nginx -ErrorAction SilentlyContinue)) {
            Start-Nginx | Out-Null
        } else {
            Write-Info "Nginx already running - reloading config"
            Reload-Nginx | Out-Null
        }

        Write-Ok "Nginx site '$name' started on port $($site.port)"
    }
}

function Stop-Site {
    param([string]$name)

    $cfg = Load-Config
    Repair-SiteConfig $cfg | Out-Null
    $cfg  = Load-Config
    $site = $cfg.sites | Where-Object { $_.name -eq $name } | Select-Object -First 1

    if (-not $site) {
        Write-Err "Site '$name' not found"
        return
    }

    if ($site.server -ieq "Apache") {
        # Stop httpd only if no other Apache sites are running
        $otherApache = $cfg.sites | Where-Object { $_.name -ne $name -and $_.server -ieq "Apache" }
        if ($otherApache.Count -eq 0) {
            Get-Process -Name "httpd" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-Ok "Apache stopped"
        } else {
            Write-Info "Apache kept running - other sites still use it"
        }
        return
    }

    # Stop this site's PHP-CGI process by its FCGI port
    if ($site.fcgiPort) {
        $lines = netstat -ano 2>$null | Where-Object { $_ -match ":$($site.fcgiPort)\s" }
        $stopped = $false
        foreach ($line in $lines) {
            if ($line -match '\s+(\d+)\s*$') {
                $pid = $Matches[1]
                taskkill /PID $pid /F 2>$null | Out-Null
                Write-Ok "Stopped PHP-CGI for '$name' (PID $pid, FCGI port $($site.fcgiPort))"
                $stopped = $true
                break
            }
        }
        if (-not $stopped) {
            Write-Warn "No PHP-CGI process found on port $($site.fcgiPort)"
        }
    }

    # Stop Nginx only if no other Nginx sites exist
    $otherNginx = $cfg.sites | Where-Object { $_.name -ne $name -and $_.server -ieq "Nginx" }
    if ($otherNginx.Count -eq 0) {
        Get-Process -Name "nginx" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Ok "Nginx stopped"
    } else {
        Write-Info "Nginx kept running - other Nginx sites still active"
        Reload-Nginx | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Nginx helpers
# ---------------------------------------------------------------------------
function Get-ApacheExe { return Join-Path $APACHE_DIR "bin\httpd.exe" }
function Get-NginxExe  { return Join-Path $NGINX_DIR  "nginx.exe"    }

function Invoke-NginxCommand {
    param([string[]]$arguments)
    $nginx = Get-NginxExe
    if (-not (Test-Path $nginx)) { Write-Err "Nginx not found at $nginx"; return $false }
    $p = Start-Process -FilePath $nginx -ArgumentList $arguments -WorkingDirectory $NGINX_DIR -WindowStyle Hidden -Wait -PassThru
    return ($p.ExitCode -eq 0)
}

function Test-NginxConfig {
    if (Invoke-NginxCommand @("-t")) { return $true }
    # Show the last error from nginx error log for immediate diagnosis
    $errLog = Join-Path $NGINX_DIR "logs\error.log"
    if (Test-Path $errLog) {
        $lastErr = Get-Content $errLog -Tail 5 | Where-Object { $_ -match '\[emerg\]|\[error\]' } | Select-Object -Last 1
        if ($lastErr) { Write-Err "Nginx says: $lastErr" }
    }
    Write-Warn "Nginx config test failed. Full log: $errLog"
    return $false
}

function Get-NginxMasterPid {
    # Read nginx.pid first (most reliable)
    $pidFile = Join-Path $NGINX_DIR "logs\nginx.pid"
    if (Test-Path $pidFile) {
        $pidVal = (Get-Content $pidFile -Raw).Trim()
        $intPid = 0
        if ([int]::TryParse($pidVal, [ref]$intPid) -and $intPid -gt 0) {
            # Verify process is still running
            if (Get-Process -Id $intPid -ErrorAction SilentlyContinue) {
                return $intPid
            }
        }
    }
    # Fallback: find nginx master process (lowest PID among all nginx processes)
    $procs = @(Get-Process -Name "nginx" -ErrorAction SilentlyContinue | Sort-Object Id)
    if ($procs.Count -gt 0) { return $procs[0].Id }
    return $null
}

function Reload-Nginx {
    if (-not (Test-NginxConfig)) { return $false }

    # Try standard -s reload first
    if (Invoke-NginxCommand @("-s", "reload")) {
        Write-Info "Nginx reloaded"
        return $true
    }

    # If that fails (common when script runs at different elevation than nginx master),
    # kill -HUP the master process directly via taskkill
    Write-Warn "nginx -s reload returned non-zero, trying direct HUP signal..."
    $masterPid = Get-NginxMasterPid
    if ($masterPid) {
        # Windows has no SIGHUP; nginx on Windows re-reads config on receipt of HUP
        # which is sent via its named pipe. As a portable fallback, stop and restart.
        Write-Info "Stopping and restarting Nginx master (PID $masterPid) to apply config..."
        Get-Process -Name "nginx" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
        return (Start-Nginx)
    }

    Write-Err "Nginx reload failed and no master PID found."
    return $false
}



function Start-Nginx {
    if (Test-NginxConfig) {
        $nginx = Get-NginxExe
        Start-Process -FilePath $nginx -WorkingDirectory $NGINX_DIR -WindowStyle Hidden
        Start-Sleep -Milliseconds 600
        Write-Info "Nginx started"
        return $true
    }
    return $false
}

function Is-ApacheInstalled { return Test-Path (Get-ApacheExe) }
function Is-NginxInstalled  { return Test-Path (Get-NginxExe)  }
function Is-ApacheRunning   { return @(Get-Process -Name "httpd" -ErrorAction SilentlyContinue).Count -gt 0 }
function Is-NginxRunning    { return @(Get-Process -Name "nginx" -ErrorAction SilentlyContinue).Count -gt 0 }

function Is-SiteRunning {
    param($site)
    if ($site.server -ieq "Apache") { return Is-ApacheRunning }
    if ($site.server -ieq "Nginx") {
        if (-not $site.fcgiPort)    { return $false }
        if (-not (Is-NginxRunning)) { return $false }
        $fcgi = netstat -ano 2>$null | Select-String ":$($site.fcgiPort)\s"
        return ($null -ne $fcgi -and "$fcgi" -ne "")
    }
    return $false
}

# ---------------------------------------------------------------------------
# Display helpers
# ---------------------------------------------------------------------------
function Choose-Site {
    param(
        [Parameter(Mandatory=$true)] [array]$sites,
        [string]$prompt      = "Select a site",
        [bool]  $onlyRunning = $false
    )

    if ($onlyRunning) { $sites = @($sites | Where-Object { Is-SiteRunning $_ }) }
    if (-not $sites -or $sites.Count -eq 0) { Write-Info "No matching sites available."; return $null }

    Write-Host ""
    for ($i = 0; $i -lt $sites.Count; $i++) {
        $s      = $sites[$i]
        $status = if (Is-SiteRunning $s) { "Running" } else { "Stopped" }
        Write-Host ("  [{0}] {1,-20} HTTP:{2,-6} FCGI:{3,-6} {4,-8} PHP:{5,-8} {6}" -f `
            ($i + 1), $s.name, $s.port, $s.fcgiPort, $s.server, $s.phpVer, $status)
    }
    Write-Host ""

    $selection = Read-Host "  $prompt (enter number)"
    $idx = 0
    if ([int]::TryParse($selection.Trim(), [ref]$idx) -and $idx -ge 1 -and $idx -le $sites.Count) {
        return $sites[$idx - 1]
    }
    Write-Warn "Invalid selection."
    return $null
}

function Show-ServiceStatus {
    $cfg = Load-Config
    Repair-SiteConfig $cfg | Out-Null

    Write-Host ""
    Write-Host "  Service status" -ForegroundColor Cyan
    Write-Host "  -----------------------------------------------------------"
    Write-Host ("  {0,-10} {1,-10} {2,-10} {3}" -f "Service","Installed","Running","Path")
    Write-Host ("  {0,-10} {1,-10} {2,-10} {3}" -f "Apache", (if (Is-ApacheInstalled) {"Yes"} else {"No"}), (if (Is-ApacheRunning) {"Yes"} else {"No"}), (Get-ApacheExe))
    Write-Host ("  {0,-10} {1,-10} {2,-10} {3}" -f "Nginx",  (if (Is-NginxInstalled)  {"Yes"} else {"No"}), (if (Is-NginxRunning)  {"Yes"} else {"No"}), (Get-NginxExe))
    Write-Host ""

    $cfg = Load-Config
    if (-not $cfg.sites -or $cfg.sites.Count -eq 0) { Write-Info "No sites configured yet."; return }

    Write-Host "  Sites" -ForegroundColor Cyan
    Write-Host "  ---------------------------------------------------------------------------"
    Write-Host ("  {0,-20} {1,-6} {2,-6} {3,-10} {4,-8} {5,-5} {6}" -f "Name","HTTP","FCGI","PHP","Server","SSL","Status")
    foreach ($s in $cfg.sites) {
        $status = if (Is-SiteRunning $s) { "Running" } else { "Stopped" }
        $ssl    = if ($s.ssl)            { "Yes"     } else { "No"     }
        Write-Host ("  {0,-20} {1,-6} {2,-6} {3,-10} {4,-8} {5,-5} {6}" -f $s.name, $s.port, $s.fcgiPort, $s.phpVer, $s.server, $ssl, $status)
    }
    Write-Host ""
}

function Stop-AllSites {
    Get-Process -Name "httpd","nginx","php","php-cgi" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Ok "All servers stopped"
}

function List-Sites {
    $cfg = Load-Config
    Repair-SiteConfig $cfg | Out-Null
    $cfg = Load-Config

    if (-not $cfg.sites -or $cfg.sites.Count -eq 0) { Write-Info "No sites configured yet."; return }

    Write-Host ""
    Write-Host ("  {0,-20} {1,-6} {2,-6} {3,-10} {4,-10} {5,-5} {6}" -f "Name","HTTP","FCGI","PHP","Server","SSL","Status") -ForegroundColor White
    Write-Host "  -----------------------------------------------------------------------"
    foreach ($s in $cfg.sites) {
        $ssl    = if ($s.ssl)            { "Yes" } else { "No" }
        $status = if (Is-SiteRunning $s) { "Running" } else { "Stopped" }
        Write-Host ("  {0,-20} {1,-6} {2,-6} {3,-10} {4,-10} {5,-5} {6}" -f $s.name, $s.port, $s.fcgiPort, $s.phpVer, $s.server, $ssl, $status)
    }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host "       PHPDevManager v1.1.0                  " -ForegroundColor Cyan
    Write-Host "       Portable PHP Dev Environment          " -ForegroundColor Cyan
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host "  Base: $BASE" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [1]  Service & site status"
    Write-Host "  [2]  List all sites"
    Write-Host "  [3]  Add new site (ports auto-assigned)"
    Write-Host "  [4]  Start site"
    Write-Host "  [5]  Stop running site"
    Write-Host "  [6]  Stop ALL servers"
    Write-Host "  [7]  Remove site"
    Write-Host "  [8]  Install PHP version"
    Write-Host "  [9]  List installed PHP versions"
    Write-Host "  [10] Set system-default PHP"
    Write-Host "  [11] Install Nginx"
    Write-Host "  [12] Install Apache"
    Write-Host "  [13] Repair php.ini (fix 502 / CGI crash)"
    Write-Host "  [14] Exit"
    Write-Host ""
    $choice = Read-Host "  Enter choice (1-14)"
    return $choice
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------
function Main {
    param([string[]]$arguments)

    Initialize-Directories
    Write-Info "PHPDevManager v1.1.0 started"
    Write-Info "Base folder: $BASE"
    Write-Host ""

    # Repair config on startup
    $cfg = Load-Config
    if (Repair-SiteConfig $cfg) {
        Write-Info "config.json repaired (fcgiPorts assigned)"
    }

    # Regenerate ALL vhost files on every startup.
    # This ensures paths (logs dir, root) are always current - critical when the
    # PhpDevManager folder is renamed or moved, as stale .conf files would cause
    # Nginx to fail its config test and refuse to start/reload.
    $cfg = Load-Config
    if ($cfg.sites -and $cfg.sites.Count -gt 0) {
        $regenCount = 0
        foreach ($site in $cfg.sites) {
            try {
                if ($site.server -ieq "Nginx") {
                    Write-NginxVHost $site
                } else {
                    Write-ApacheVHost $site
                }
                $regenCount++
            } catch {
                Write-Warn "Could not regenerate vhost for '$($site.name)': $_"
            }
        }
        Write-Info "Regenerated $regenCount vhost file(s) with current paths"
    }

    if ($arguments.Count -gt 0) {
        switch ($arguments[0]) {
            "install-php" { Install-PHP $arguments[1] }
            "set-php"     { Set-SystemDefaultPHP $arguments[1] }
            "add-site"    {
                $p = if ($arguments.Count -gt 3) { [int]$arguments[3] } else { 0 }
                $v = if ($arguments.Count -gt 4) { $arguments[4] } else { "" }
                $s = if ($arguments.Count -gt 5) { $arguments[5] } else { "Apache" }
                Add-Site -Name $arguments[1] -Root $arguments[2] -Port $p -PhpVer $v -Server $s
            }
            "remove-site" { Remove-Site $arguments[1] }
            "start"       { Start-Site $arguments[1] }
            "stop"        { Stop-Site $arguments[1] }
            "stop-all"    { Stop-AllSites }
            "list"        { List-Sites }
            "status"      { Show-ServiceStatus }
            "repair-ini"  {
                $ver = if ($arguments.Count -gt 1) { $arguments[1] } else { "" }
                if ($ver) { Repair-PhpIni $ver }
                else { foreach ($v in @(Get-InstalledPHP)) { Repair-PhpIni $v } }
            }
            "test-php-cgi" {
                # Quick sanity test: run php-cgi.exe -v and show output
                $ver = if ($arguments.Count -gt 1) { $arguments[1] } else { (Load-Config).systemPhp }
                $phpCgi = Join-Path $PHP_DIR "$ver\php-cgi.exe"
                $iniPath = Join-Path $PHP_DIR "$ver\php.ini"
                Write-Info "Testing php-cgi.exe for PHP $ver"
                Write-Info "Binary:  $phpCgi"
                Write-Info "php.ini: $iniPath"
                if (Test-Path $iniPath) {
                    $lines = [System.IO.File]::ReadAllText($iniPath) -split "`n" |
                        Where-Object { $_ -match 'force_redirect|fix_pathinfo|extension_dir' -and $_ -notmatch '^\s*;' }
                    Write-Info "Active CGI settings in php.ini:"
                    $lines | ForEach-Object { Write-Info "  $($_.Trim())" }
                }
                if (Test-Path $phpCgi) {
                    $out = & $phpCgi -v 2>&1
                    Write-Info "php-cgi -v output: $out"
                } else {
                    Write-Err "php-cgi.exe not found at $phpCgi"
                }
            }
            default       { Write-Err "Unknown command: $($arguments[0])" }
        }
        return
    }

    while ($true) {
        $c = Show-Menu
        switch ($c) {
            "1" { Show-ServiceStatus;         Read-Host "  Press Enter to continue" }
            "2" { List-Sites;                 Read-Host "  Press Enter to continue" }
            "3" {
                Write-Host ""
                $name    = Read-Host "  Hostname (e.g. myapp.local)"
                $root    = Read-Host "  Document root (e.g. C:\dev\myapp\public)"

                $cfg     = Load-Config
                $autoHttp = Get-NextHttpPort $cfg
                $autoFcgi = Get-NextFcgiPort $cfg

                Write-Host "  NOTE: All sites share port $autoHttp via virtual hosting (Nginx routes by hostname)." -ForegroundColor DarkGray
                $portIn  = Read-Host "  HTTP Port [$autoHttp - Enter to use $autoHttp]"
                $port    = if ($portIn.Trim()) { [int]$portIn } else { 0 }

                $fcgiIn  = Read-Host "  FCGI Port [$autoFcgi - Enter to auto-assign]"
                $fcgi    = if ($fcgiIn.Trim()) { [int]$fcgiIn } else { 0 }

                $ver     = Read-Host "  PHP version (blank = use latest installed)"
                $server  = Read-Host "  Server (Apache/Nginx) [Apache]"
                if (-not $server) { $server = "Apache" }
                $sslIn   = Read-Host "  Enable SSL? (y/N)"
                $ssl     = ($sslIn.Trim() -eq "y")
                Write-Host ""
                Add-Site -Name $name -Root $root -Port $port -PhpVer $ver -Server $server -SSL $ssl -FcgiPort $fcgi
                Write-Host ""
                Read-Host "  Press Enter to continue"
            }
            "4" {
                $cfg  = Load-Config
                $site = Choose-Site -sites $cfg.sites -prompt "Select a site to start"
                if ($site) { Write-Host ""; Start-Site $site.name }
                Write-Host ""; Read-Host "  Press Enter to continue"
            }
            "5" {
                $cfg  = Load-Config
                $site = Choose-Site -sites $cfg.sites -prompt "Select a running site to stop" -onlyRunning $true
                if ($site) { Write-Host ""; Stop-Site $site.name }
                Write-Host ""; Read-Host "  Press Enter to continue"
            }
            "6" { Write-Host ""; Stop-AllSites;         Write-Host ""; Read-Host "  Press Enter to continue" }
            "7" {
                $cfg  = Load-Config
                $site = Choose-Site -sites $cfg.sites -prompt "Select a site to remove"
                if ($site) {
                    $confirm = Read-Host "  Remove '$($site.name)'? (y/N)"
                    if ($confirm.Trim() -eq "y") { Write-Host ""; Remove-Site $site.name }
                }
                Write-Host ""; Read-Host "  Press Enter to continue"
            }
            "8" {
                Write-Host ""
                Write-Host "  Available PHP versions:" -ForegroundColor Cyan
                foreach ($v in ($PHP_RELEASES.Keys | Sort-Object -Descending)) { Write-Host "    $v" }
                Write-Host ""
                $ver = Read-Host "  Version to install"
                Write-Host ""
                Install-PHP $ver.Trim()
                Write-Host ""; Read-Host "  Press Enter to continue"
            }
            "9" {
                Write-Host ""
                $installed = @(Get-InstalledPHP)
                if ($installed.Count -gt 0) {
                    $cfg = Load-Config
                    foreach ($v in $installed) {
                        $marker = if ($v -eq $cfg.systemPhp) { "  (system default)" } else { "" }
                        Write-Ok "PHP $v  ->  $(Join-Path $PHP_DIR $v)$marker"
                    }
                } else {
                    Write-Info "No PHP versions installed yet. Use option 8 to download one."
                }
                Write-Host ""; Read-Host "  Press Enter to continue"
            }
            "10" {
                Write-Host ""
                $ver = Choose-InstalledPHP -prompt "Select PHP version to set as system default"
                if ($ver) { Write-Host ""; Set-SystemDefaultPHP $ver }
                Write-Host ""; Read-Host "  Press Enter to continue"
            }
            "11" { Write-Host ""; Install-Nginx;  Write-Host ""; Read-Host "  Press Enter to continue" }
            "12" { Write-Host ""; Install-Apache; Write-Host ""; Read-Host "  Press Enter to continue" }
            "13" {
                Write-Host ""
                $installed = @(Get-InstalledPHP)
                if ($installed.Count -eq 0) {
                    Write-Info "No PHP versions installed yet."
                } else {
                    Write-Host "  Installed PHP versions:" -ForegroundColor Cyan
                    for ($i = 0; $i -lt $installed.Count; $i++) {
                        Write-Host ("  [{0}] PHP {1}" -f ($i + 1), $installed[$i])
                    }
                    Write-Host "  [A] Repair ALL"
                    Write-Host ""
                    $sel = Read-Host "  Select version to repair (number or A)"
                    Write-Host ""
                    if ($sel.Trim() -ieq "A") {
                        foreach ($v in $installed) { Repair-PhpIni $v }
                    } else {
                        $idx = 0
                        if ([int]::TryParse($sel.Trim(), [ref]$idx) -and $idx -ge 1 -and $idx -le $installed.Count) {
                            Repair-PhpIni $installed[$idx - 1]
                        } else {
                            Write-Warn "Invalid selection."
                        }
                    }
                }
                Write-Host ""; Read-Host "  Press Enter to continue"
            }
            "14" { exit }
            default {
                Write-Warn "Please enter a number between 1 and 14."
                Start-Sleep -Seconds 1
            }
        }
    }
}

try {
    Main -arguments $args
} catch {
    Write-Host ""
    Write-Host "  [FATAL] $_" -ForegroundColor Red
    Write-Host "  Line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" -ForegroundColor DarkRed
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}
