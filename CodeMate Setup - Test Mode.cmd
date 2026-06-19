@echo off
setlocal
set "ROOT=%~dp0"
set "CODEMATE_TEST_MODE=1"
pushd "%ROOT%" >nul
start "" /D "%ROOT%" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%ROOT%src\CodeMate.Setup.ps1"
popd >nul
