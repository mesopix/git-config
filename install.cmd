@echo off
chcp 65001 >nul
setlocal EnableExtensions EnableDelayedExpansion

rem git-config-sync one-click installer / uninstaller (Windows CMD).
rem Only requires git and curl.exe (both standard on Windows 10 1803+).
rem
rem Usage:
rem   install.cmd                        download config/gitconfig from GitHub and install
rem   install.cmd C:\path\to\gitconfig   install from a local file
rem   install.cmd -u                     remove the include.path entry and the managed gitconfig

set "REPO_RAW_BASE=https://raw.githubusercontent.com/mesopix/git-config/main"
set "TOOL_NAME=git-config-sync"

rem remember the console codepage so it can be restored on exit
for /f "tokens=2 delims=: " %%c in ('chcp') do set "OLDCP=%%c"

rem ANSI colors (Win10+ consoles); disabled when NO_COLOR is set
for /f %%e in ('echo prompt $E ^| cmd') do set "ESC=%%e"
set "GREEN=%ESC%[32m"
set "YELLOW=%ESC%[33m"
set "RED=%ESC%[31m"
set "RESET=%ESC%[0m"
if defined NO_COLOR (
  set "GREEN="
  set "YELLOW="
  set "RED="
  set "RESET="
)

rem the install flow buffers its lines in a temp file so a no-op run prints
rem a single summary line rather than a multi-line report that reads like
rem a failure
set "NOTICEFILE=%TEMP%\git-config-sync-notices-%RANDOM%.txt"
if exist "%NOTICEFILE%" del "%NOTICEFILE%" >nul 2>&1
set "DL_OUT=%TEMP%\git-config-sync-dl-%RANDOM%.txt"

if not defined APPDATA (
  echo %RED%Error: Environment variable APPDATA is not set; cannot determine the user config directory%RESET% 1>&2
  goto :exit_batch 1
)
set "MANAGED_DIR=%APPDATA%\%TOOL_NAME%"
set "MANAGED=%MANAGED_DIR%\gitconfig"
rem git stores include.path verbatim; forward slashes work on every platform.
set "MANAGED_INCLUDE=%MANAGED:\=/%"

rem a downloaded copy of this script is removed after success — but never
rem one inside a repo clone
set "DOWNLOADED_SELF="
if /i not "%~nx0"=="install.cmd" goto :self_done
if exist "%~dp0config\gitconfig" goto :self_done
if exist "%~dp0.git" goto :self_done
for %%D in ("%~dp0.") do set "SCRIPT_DIR=%%~fD"
for %%D in ("%CD%.") do set "CWD_FULL=%%~fD"
if /i not "!SCRIPT_DIR!"=="!CWD_FULL!" goto :self_done
set "DOWNLOADED_SELF=%~f0"
:self_done

if "%~1"=="-h" goto :usage
if "%~1"=="--help" goto :usage
if "%~1"=="-?" goto :usage
if "%~1"=="-u" goto :run_uninstall
if "%~1"=="--uninstall" goto :run_uninstall
call :do_install "%~1"
goto :exit_batch %errorlevel%

:run_uninstall
call :do_uninstall
goto :exit_batch %errorlevel%

:usage
echo Usage:
echo   install.cmd                        download config/gitconfig from GitHub and install
echo   install.cmd C:\path\to\gitconfig   install from a local file
echo   install.cmd -u                     remove the include.path entry and the managed gitconfig
goto :exit_batch 0

rem ── notice helpers ─────────────────────────────────────
:notice_ok
>>"%NOTICEFILE%" echo !GREEN!✓ %~1!RESET!
exit /b 0

:notice_warn
>>"%NOTICEFILE%" echo !YELLOW!⚠ %~1!RESET!
exit /b 0

:cleanup_self
if not defined DOWNLOADED_SELF exit /b 0
if not exist "%DOWNLOADED_SELF%" exit /b 0
del "%DOWNLOADED_SELF%" >nul 2>&1
if errorlevel 1 (
  echo   ^(you can delete the installer manually: %DOWNLOADED_SELF%^)
) else (
  echo %GREEN%✓ removed downloaded installer: %DOWNLOADED_SELF%%RESET%
)
exit /b 0

rem ── git helpers ────────────────────────────────────────
rem escape a string for use in a ^...$ git config value-regex
:escape_regex
set "s=%~1"
set "s=!s:\=/!"
set "s=!s:.=\.!"
set "s=!s:^=\^!"
set "s=!s:$=\$!"
set "s=!s:*=\*!"
set "s=!s:+= \+!"
set "s=!s:?=\?!"
set "s=!s:(=\(!"
set "s=!s:)=\)!"
set "s=!s:{=\{!"
set "s=!s:}=\}!"
set "s=!s:|= \|!"
set "s=!s:[=\[!"
set "s=!s:]=\]!"
set "PATTERN=!s!"
exit /b 0

rem ── do_install ─────────────────────────────────────────
:do_install
rem %1 = optional local source file
where git >nul 2>&1
if errorlevel 1 (
  echo %RED%Error: git not found: sync and syntax validation both require it. Install from https://git-scm.com/downloads%RESET% 1>&2
  goto :exit_batch 1
)
call :resolve_source "%~1"
if errorlevel 1 goto :exit_batch 1
call :install_managed "%SRC_FILE%"
set "FILE_CHANGED=%errorlevel%"
call :ensure_include
set "INC_CHANGED=%errorlevel%"
if defined SRC_TMP if exist "%SRC_FILE%" del "%SRC_FILE%" >nul 2>&1
set /a TOTAL=%FILE_CHANGED%+%INC_CHANGED%
if "%TOTAL%"=="0" (
  echo %GREEN%Already up to date — nothing to do.%RESET%
) else (
  if exist "%NOTICEFILE%" type "%NOTICEFILE%"
  echo %GREEN%Sync complete. Managed config overrides same-name global settings and takes effect immediately.%RESET%
)
call :cleanup_self
exit /b 0

rem ── resolve_source ─────────────────────────────────────
:resolve_source
rem %1 = optional explicit local source path
set "SRC_TMP="
if not "%~1"=="" (
  if not exist "%~1" (
    echo %RED%Error: file not found: %~1%RESET% 1>&2
    exit /b 1
  )
  call :notice_ok "using local source: %~1"
  set "SRC_FILE=%~1"
  exit /b 0
)
where curl.exe >nul 2>&1
if errorlevel 1 (
  echo %RED%Error: curl.exe not found: downloading config/gitconfig requires it ^(Windows 10 1803 or newer^)%RESET% 1>&2
  exit /b 1
)
set "SRC_FILE=%TEMP%\git-config-sync-src-%RANDOM%.gitconfig"
curl.exe -sSL -o "%SRC_FILE%" -w "%%{http_code}" "%REPO_RAW_BASE%/config/gitconfig" >"%DL_OUT%" 2>nul
if errorlevel 1 (
  if exist "%SRC_FILE%" del "%SRC_FILE%" >nul 2>&1
  echo %RED%Error: download failed: %REPO_RAW_BASE%/config/gitconfig%RESET% 1>&2
  exit /b 1
)
set "HTTP_CODE="
set /p HTTP_CODE=<"%DL_OUT%"
if not "%HTTP_CODE%"=="200" (
  if exist "%SRC_FILE%" del "%SRC_FILE%" >nul 2>&1
  echo %RED%Error: download failed: HTTP %HTTP_CODE% ^(%REPO_RAW_BASE%/config/gitconfig^)%RESET% 1>&2
  exit /b 1
)
call :notice_ok "fetched config/gitconfig from GitHub"
set "SRC_TMP=1"
exit /b 0

rem ── install_managed ────────────────────────────────────
:install_managed
rem %1 = source file
if exist "%MANAGED%" (
  fc /b "%MANAGED%" "%~1" >nul 2>&1
  if not errorlevel 1 (
    call :notice_ok "managed config is already up to date: %MANAGED%"
    exit /b 0
  )
  call :notice_warn "existing managed config differs from the source and will be overwritten — local changes will be lost"
)
if not exist "%MANAGED_DIR%" mkdir "%MANAGED_DIR%" >nul 2>&1
if errorlevel 1 (
  echo %RED%Error: unable to create directory: %MANAGED_DIR%%RESET% 1>&2
  exit /b 1
)
set "TEMP_CFG=%MANAGED_DIR%\.gitconfig-%RANDOM%.tmp"
copy /y "%~1" "%TEMP_CFG%" >nul 2>&1
if errorlevel 1 (
  echo %RED%Error: unable to write: %TEMP_CFG%%RESET% 1>&2
  exit /b 1
)
rem validate BEFORE replacing anything, so a broken file aborts with the
rem previous install untouched
git config --file "%TEMP_CFG%" --list >nul 2>&1
if errorlevel 1 (
  echo %RED%Error: invalid gitconfig source:%RESET% 1>&2
  git config --file "%TEMP_CFG%" --list 1>nul
  del "%TEMP_CFG%" >nul 2>&1
  exit /b 1
)
move /y "%TEMP_CFG%" "%MANAGED%" >nul 2>&1
if errorlevel 1 (
  del "%TEMP_CFG%" >nul 2>&1
  echo %RED%Error: unable to move %TEMP_CFG% into place%RESET% 1>&2
  exit /b 1
)
call :notice_ok "installed managed config: %MANAGED%"
exit /b 1

rem ── ensure_include ─────────────────────────────────────
:ensure_include
set "COUNT=0"
set "EXACT=0"
for /f "usebackq delims=" %%i in (`git config --global --get-all include.path 2^>nul`) do (
  set "p=%%i"
  set "p=!p:\=/!"
  if /i "!p!"=="%MANAGED_INCLUDE%" (
    set /a COUNT+=1
    if "%%i"=="%MANAGED_INCLUDE%" set "EXACT=1"
  )
)
if "%COUNT%"=="1" if "%EXACT%"=="1" (
  call :notice_ok "global include.path already set: %MANAGED_INCLUDE%"
  exit /b 0
)
if not "%COUNT%"=="0" call :notice_warn "found %COUNT% duplicate include.path entries; merging into one"
call :escape_regex "%MANAGED_INCLUDE%"
set "PATTERN=!PATTERN:/=[\/]!"
git config --global --unset-all include.path "^!PATTERN!$" >nul 2>&1
set "RC=%errorlevel%"
if not "%RC%"=="0" if not "%RC%"=="5" (
  echo %RED%Error: unable to update global include.path%RESET% 1>&2
  exit /b 1
)
git config --global --add include.path "%MANAGED_INCLUDE%" >nul 2>&1
if errorlevel 1 (
  echo %RED%Error: unable to write global include.path%RESET% 1>&2
  exit /b 1
)
call :notice_ok "added include.path to global config: %MANAGED_INCLUDE%"
exit /b 1

rem ── do_uninstall ───────────────────────────────────────
:do_uninstall
where git >nul 2>&1
if errorlevel 1 (
  echo %RED%Error: git not found: sync and syntax validation both require it. Install from https://git-scm.com/downloads%RESET% 1>&2
  goto :exit_batch 1
)
set "CHANGED=0"
set "FOUND=0"
for /f "usebackq delims=" %%i in (`git config --global --get-all include.path 2^>nul`) do (
  set "p=%%i"
  set "p=!p:\=/!"
  if /i "!p!"=="%MANAGED_INCLUDE%" set "FOUND=1"
)
if "%FOUND%"=="1" (
  call :escape_regex "%MANAGED_INCLUDE%"
  set "PATTERN=!PATTERN:/=[\/]!"
  git config --global --unset-all include.path "^!PATTERN!$" >nul 2>&1
  set "RC=%errorlevel%"
  if not "%RC%"=="0" if not "%RC%"=="5" (
    echo %RED%Error: unable to update global include.path%RESET% 1>&2
    exit /b 1
  )
  echo %GREEN%✓ removed include.path entry pointing to the managed file: %MANAGED_INCLUDE%%RESET%
  set "CHANGED=1"
)
if exist "%MANAGED%" (
  del "%MANAGED%" >nul 2>&1
  if errorlevel 1 (
    echo %RED%Error: unable to delete %MANAGED%%RESET% 1>&2
    exit /b 1
  )
  echo %GREEN%✓ deleted %MANAGED%%RESET%
  rd "%MANAGED_DIR%" >nul 2>&1
  set "CHANGED=1"
)
if "%CHANGED%"=="1" (
  echo %GREEN%Uninstall complete. Other global config and include.path entries were not touched.%RESET%
) else (
  echo %GREEN%Nothing to uninstall.%RESET%
)
call :cleanup_self
exit /b 0

rem ── exit_batch ─────────────────────────────────────────
:exit_batch
rem %1 = exit code
if "%1"=="1" if defined DOWNLOADED_SELF if exist "%DOWNLOADED_SELF%" (
  echo ^(the installer was kept at %DOWNLOADED_SELF%; fix the problem and re-run: install.cmd^) 1>&2
)
if exist "%NOTICEFILE%" del "%NOTICEFILE%" >nul 2>&1
if exist "%DL_OUT%" del "%DL_OUT%" >nul 2>&1
if defined OLDCP chcp %OLDCP% >nul
exit /b %1
