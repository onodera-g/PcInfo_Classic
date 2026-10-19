@echo off
setlocal
if not exist "%~dp0..\.venv\Scripts\python.exe" exit /b 1
"%~dp0..\.venv\Scripts\python.exe" -B "%~dp0verify_windows.py" %*
exit /b %errorlevel%
