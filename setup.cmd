@echo off
rem Double-click entry point for the medialab installer.
rem Installs uv through winget when it is missing, then opens the browser-based
rem wizard from the medialab-setup submodule. Design: docs/specs/install-wizard.md.
setlocal
cd /d "%~dp0"

where uv >nul 2>nul
if errorlevel 1 (
    echo uv is not installed; installing it with winget...
    winget install --exact --silent --accept-package-agreements --accept-source-agreements --id astral-sh.uv
    if errorlevel 1 (
        echo Could not install uv. Install it from https://docs.astral.sh/uv/getting-started/installation/ and run setup.cmd again.
        pause
        exit /b 1
    )
    set "PATH=%LOCALAPPDATA%\Programs\uv;%USERPROFILE%\.local\bin;%PATH%"
)

if not exist "medialab-setup\pyproject.toml" (
    echo The medialab-setup submodule is missing; run: git submodule update --init
    pause
    exit /b 1
)

uv run --project medialab-setup medialab-setup wizard --workspace "%~dp0." %*
if errorlevel 1 pause
endlocal
