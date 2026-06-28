@echo off
title PHPDevManager v1.1.0
cd /d "%~dp0"

echo.
echo  ==========================================
echo    PHPDevManager v1.1.0 - Portable PHP Env
echo  ==========================================
echo.

:: Check PowerShell availability
where powershell >nul 2>&1
if errorlevel 1 (
    echo [ERROR] PowerShell not found on this system.
    echo         Please install PowerShell 5.1 or newer.
    echo.
    pause
    exit /b 1
)

echo [OK] PowerShell found.

:: Check if PS1 file exists next to this bat
if not exist "%~dp0PHPDevManager.ps1" (
    echo [ERROR] PHPDevManager.ps1 not found!
    echo         Make sure both files are in the same folder.
    echo         Current folder: %~dp0
    echo.
    pause
    exit /b 1
)

echo [OK] PHPDevManager.ps1 found.
echo.

:: Check for admin rights
net session >nul 2>&1
if errorlevel 1 (
    echo [WARN] Not running as Administrator.
    echo        Some features ^(hosts file, system PATH^) require elevation.
    echo        Tip: Right-click this .bat and choose "Run as administrator"
    echo.
)

echo  Starting PHPDevManager...
echo  ==========================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PHPDevManager.ps1" %*

echo.
echo  ==========================================
if errorlevel 1 (
    echo  [!] PHPDevManager exited with an error.
    echo      Check the messages above for details.
) else (
    echo  PHPDevManager session ended.
)
echo  ==========================================
echo.
pause
