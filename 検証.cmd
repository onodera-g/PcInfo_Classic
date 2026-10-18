@echo off
setlocal
if not exist "%~dp0.venv\Scripts\python.exe" exit /b 1
"%~dp0.venv\Scripts\python.exe" -B "%~dp0tools\verify_windows.py" %*
exit /b %errorlevel%
