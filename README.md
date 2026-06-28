# PHPDevManager

> Portable PHP development environment for Windows — multiple PHP versions, multiple sites, Apache & Nginx, zero global installs.

![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D6?logo=windows)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell)
![PHP](https://img.shields.io/badge/PHP-7.3--8.3-777BB4?logo=php)
![License](https://img.shields.io/badge/license-MIT-green)

---

## What it does

PHPDevManager lets you run multiple local PHP sites side by side — each with its own hostname, PHP version, and web server — from a single portable folder you can move or copy anywhere.

- **Virtual hosting** — sites route by hostname (`myapp.local`, `admin.local`) all on port 80, no port numbers to remember
- **Per-site PHP version** — run PHP 8.3 for one project and PHP 7.4 for another simultaneously
- **Auto-downloads** — PHP, Nginx and Apache are downloaded and installed with one menu choice
- **Self-healing** — vhost configs are regenerated on every launch, so renaming or moving the folder never breaks anything
- **React UI** — a visual control panel (`PHPDevManager.jsx`) runs alongside the terminal menu

---

## Quick start

### 1. Download

```
git clone https://github.com/muradsaifi/PhpDevManager
cd phpdevmanager
```

Or download the ZIP from the [Releases](../../releases) page and extract anywhere.

### 2. Launch

Right-click `PHPDevManager.bat` → **Run as administrator**

```
==========================================
   PHPDevManager v1.1.0
   Portable PHP Dev Environment
==========================================

  [1]  Service & site status
  [2]  List all sites
  [3]  Add new site
  [4]  Start site
  ...
```

### 3. Install PHP

Choose **[8]** → type `8.3.31` → downloads and extracts automatically.

### 4. Install Nginx

Choose **[11]** → downloads the latest stable Windows build from nginx.org automatically.

### 5. Add a site

Choose **[3]** and fill in:

```
Hostname:      myapp.local
Document root: C:\dev\myapp\public
HTTP Port:     80          (Enter to accept — all sites share port 80)
FCGI Port:     9000        (Enter to auto-assign)
PHP version:   8.3.31
Server:        Nginx
SSL:           N
```

The script writes the vhost config and adds `myapp.local` to your hosts file automatically.

### 6. Start the site

Choose **[4]** → select your site → open `http://myapp.local` in a browser.

---

## Folder structure

```
PhpDevManager\
├── PHPDevManager.bat          ← Double-click to launch
├── PHPDevManager.ps1          ← PowerShell backend + CLI
├── PHPDevManager.jsx          ← React visual control panel
├── config.json                ← Sites registry (auto-managed)
│
├── php\
│   ├── 8.3.31\php.exe         ← Auto-downloaded PHP versions
│   └── 7.4.33\php.exe
│
├── nginx\nginx.exe            ← Auto-downloaded (option 11)
├── apache24\bin\httpd.exe     ← Auto-downloaded (option 12)
│
├── conf\
│   ├── vhosts\                ← Auto-generated per-site configs
│   └── ssl\                   ← Auto-generated self-signed certs
│
└── logs\                      ← Per-site error + access logs
```

---

## CLI usage

All menu actions are also available as one-liners:

```powershell
# Install PHP
.\PHPDevManager.ps1 install-php 8.3.31

# Set system-wide default PHP (updates Windows PATH)
.\PHPDevManager.ps1 set-php 8.3.31

# Add a site (hostname, root, port, phpver, server)
.\PHPDevManager.ps1 add-site myapp.local C:\dev\myapp\public 80 8.3.31 Nginx

# Start / stop a site
.\PHPDevManager.ps1 start myapp.local
.\PHPDevManager.ps1 stop  myapp.local
.\PHPDevManager.ps1 stop-all

# List sites and status
.\PHPDevManager.ps1 list
.\PHPDevManager.ps1 status

# Fix php.ini CGI settings (run if you get 502 errors)
.\PHPDevManager.ps1 repair-ini 8.3.31

# Diagnose PHP-CGI binary
.\PHPDevManager.ps1 test-php-cgi 8.3.31
```

---

## PHP versions

| Version | Status   | Notes                      |
|---------|----------|----------------------------|
| 8.3.x   | Latest   | Recommended                |
| 8.2.x   | Stable   |                            |
| 8.1.x   | Security | Security fixes only        |
| 8.0.x   | EOL      | Not recommended            |
| 7.4.x   | EOL      | Legacy projects only       |
| 7.3.x   | EOL      | Legacy projects only       |

Each install gets its own `php.ini` with these extensions pre-enabled:
`curl` `mbstring` `openssl` `pdo_mysql` `mysqli` `gd` `zip`

CGI settings are auto-fixed (`cgi.force_redirect = 0`, absolute `extension_dir`) so PHP-CGI works correctly under Nginx without manual ini editing.

---

## How virtual hosting works

All sites listen on **port 80**. Nginx routes requests by hostname:

```
http://meka.local    → conf\vhosts\meka.local.conf    → PHP-CGI :9006
http://nurse.local   → conf\vhosts\nurse.local.conf   → PHP-CGI :9000
http://myapp.local   → conf\vhosts\myapp.local.conf   → PHP-CGI :9007
```

Each site has its own FastCGI port (auto-assigned from 9000 upward) so PHP versions and processes are fully isolated.

---

## Portability

The entire environment lives in one folder. To move it:

1. Stop all sites (option **[6]**)
2. Copy the folder anywhere — USB drive, another PC, network share
3. Run `PHPDevManager.bat` from the new location
4. Vhost configs are regenerated automatically with the new paths
5. Optionally run option **[10]** to update the system PATH on the new machine

---

## Visual control panel

`PHPDevManager.jsx` is a React component that provides a graphical interface for everything in the terminal menu. Open it in:

- **Claude.ai** — paste into a new React artifact
- Any local React development environment

Features: site start/stop, PHP version switcher per site, one-click install, port allocation overview, live log viewer, config sync.

---

## Requirements

| Requirement | Version |
|-------------|---------|
| Windows | 10 or 11 x64 |
| PowerShell | 5.1+ (built into Windows) |
| Internet | For first-time downloads |
| Admin rights | For hosts file and PATH edits |

---

## Troubleshooting

**502 Bad Gateway**
Run `.\PHPDevManager.ps1 repair-ini 8.3.31` then restart the site. This fixes `cgi.force_redirect` and `extension_dir` in php.ini.

**Nginx config test failed after moving the folder**
Stale `.conf` files referenced the old path. The script auto-regenerates all vhost files on startup — just restart PHPDevManager.

**Site not found in browser (404 from Nginx default server)**
Make sure you're visiting `http://hostname.local` (no port number). All sites use port 80 via virtual hosting.

**Hosts file not updated**
Run PHPDevManager.bat as Administrator. Without elevation the hosts file write is skipped (a warning is shown with the line to add manually).

**Port already in use**
Run option **[1]** to see which sites are running. Use option **[6]** to stop everything, then start the specific site you want.

---

## License

MIT — free to use, modify, and distribute.
