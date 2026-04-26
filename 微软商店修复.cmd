@echo off
setlocal
chcp 65001 >nul
title Microsoft Store Repair (No Reboot)
color 07

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_PATH=%SCRIPT_DIR%src\cursor-model-network-repair.ps1"

if not exist "%SCRIPT_PATH%" (
  echo.
  echo ================================================================
  echo   [ERROR] Script not found
  echo   "%SCRIPT_PATH%"
  echo ================================================================
  echo.
  pause
  exit /b 1
)

echo.
echo ================================================================
echo   Microsoft Store Repair ^(No Reboot^)
echo ================================================================
echo   Running store-only fix path...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" -FixStoreOnlyNoReboot
set "EXIT_CODE=%errorlevel%"

echo.
echo ================================================================
if "%EXIT_CODE%"=="0" (
  echo   Finished. ExitCode: %EXIT_CODE%
) else (
  echo   Finished with issues. ExitCode: %EXIT_CODE%
)
echo ================================================================
echo.
pause
exit /b %EXIT_CODE%
