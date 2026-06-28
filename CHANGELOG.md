# Changelog

## v1.1.0 — 2026-06-28

### Added
- **Dynamic port allocation** — FCGI ports auto-assigned from 9000 upward; HTTP defaults to port 80 (virtual hosting)
- **Edit site** — pencil button in the React UI to modify an existing site without deleting it
- **Remove site** (`[7]` in menu) — deletes site from config and removes its vhost file; logs freed ports
- **Repair php.ini** (`[13]` in menu / `repair-ini` CLI) — fixes `cgi.force_redirect`, `cgi.fix_pathinfo`, and `extension_dir` in any installed PHP version
- **Auto-download discovery** — `Get-ApacheDownloadUrl` and `Get-NginxDownloadUrl` scrape the vendor download pages for the current filename, so installs never break when a new version is released
- **Vhost regeneration on startup** — all vhost `.conf` files are rewritten on every launch with current paths; renaming or moving the folder self-heals automatically
- **Port allocation overview** — Servers tab in the React UI shows all HTTP and FCGI ports in a table
- **Log export** — download button in the Logs tab saves the session log as a `.log` file
- **CLI commands** — `repair-ini`, `test-php-cgi`, `remove-site`, `status`
- **Start All / Stop All** button in the React UI

### Fixed
- **PowerShell parse errors** — em-dashes and arrows in comments were breaking PS5.1's byte-stream parser (UTF-8 multi-byte chars read as Windows-1252); all replaced with ASCII, file saved with UTF-8 BOM
- **Apache 308 redirect** — hardcoded URL with `/binaries/` subdirectory no longer exists on apachelounge.com; replaced with live page scraping
- **BOM in vhost files** — `Set-Content -Encoding UTF8` in PS5.1 writes a UTF-8 BOM; Nginx parsed `server` as `﻿server` and rejected the config; fixed by using `[System.IO.File]::WriteAllText` with explicit `UTF8NoBOM` encoding
- **Wrong vhost extension** — files were written as `.nginx.conf` but nginx.conf's include glob was `*.conf`; Nginx never loaded them; fixed to write `.conf` and clean up old files
- **Port 80 virtual hosting** — sites were getting unique HTTP ports (8080, 8081...) meaning `http://meka.local` hit Nginx's default server block; all sites now share port 80 and route by `server_name`
- **PHP-CGI `cgi.force_redirect`** — the patch regex matched a comment line containing the text instead of the actual setting; fixed with an anchored regex requiring `=`
- **Absolute `extension_dir`** — relative `extension_dir = "ext"` caused extensions to silently fail when PHP-CGI was launched from a different working directory; now writes the absolute path
- **FCGI port drift** — `Repair-SiteConfig` was checking live TCP ports; a port in `TIME_WAIT` after killing PHP-CGI would get permanently bumped to the next port; now only avoids config-assigned ports
- **PHP-CGI not restarted after ini repair** — old process held the port and continued running with the broken ini; now always killed and restarted so new settings take effect
- **Orphaned here-string** — partial deletion of a function left a `"@` closing delimiter floating in the file, breaking the PS parser at startup; fully removed
- **`Access is denied` on Nginx reload** — `nginx -s reload` fails when run at a different elevation than the Nginx master process; fallback added to stop and restart Nginx instead
- **Stale paths after folder rename** — vhost configs referenced the old folder path; fixed by regenerating all configs on startup

### Changed
- `Repair-SiteConfig` no longer assigns FCGI ports based on live TCP scan (prevents drift)
- `Get-NextHttpPort` now returns 80 by default for all sites (virtual hosting model)
- `Add-Site` no longer rejects HTTP port conflicts — sharing port 80 is correct and intentional
- PHP-CGI launch now waits up to 6 seconds confirming the port is bound before reporting success
- `Test-NginxConfig` now prints the relevant error line from the Nginx error log on failure
- Menu extended to 14 options
