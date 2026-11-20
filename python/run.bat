@echo off
rem Launches the Python (Streamlit) version in your browser (Windows). Close this window to stop it.
cd /d "%~dp0.."
if not exist ".venv\Scripts\streamlit.exe" (
  set "PY="
  where py >nul 2>nul && set "PY=py -3"
  if not defined PY where python >nul 2>nul && set "PY=python"
  if not defined PY (
    echo Python 3.10 or newer was not found. Install it from https://www.python.org/downloads/ and try again.
    pause
    exit /b 1
  )
  echo Creating virtual environment and installing packages...
  if exist ".venv" rmdir /s /q ".venv"
  call %%PY%% -m venv .venv || (pause & exit /b 1)
  ".venv\Scripts\python" -m pip install -r python\requirements.txt || (pause & exit /b 1)
)
rem Bind to localhost only so the app is not reachable from other machines.
".venv\Scripts\streamlit" run python\app.py --server.address localhost --browser.gatherUsageStats false
pause
