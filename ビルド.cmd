@echo off
setlocal
if not exist "%~dp0.venv\Scripts\python.exe" (
  echo Run setup first.
  exit /b 1
)
"%~dp0.venv\Scripts\python.exe" -B "%~dp0tools\build_windows.py" %*
exit /b %errorlevel%
