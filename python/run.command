#!/usr/bin/env bash
# Launches the Python (Streamlit) version in your browser (macOS / Linux).
# macOS: double-click this file in Finder (first time: right-click > Open), or run:  bash python/run.command
# Press Ctrl+C in this window to stop the app.
set -euo pipefail
cd "$(dirname "$0")/.."

# Each OS gets its own virtual environment, so a project folder shared between a Mac and a
# Windows PC (e.g. via OneDrive or Dropbox) never has one OS overwrite the other's packages.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) VENV=.venv ;;                     # Git Bash on Windows: same as run.bat
  *) VENV=".venv-$(uname -s | tr '[:upper:]' '[:lower:]')" ;;  # .venv-darwin, .venv-linux
esac

venv_bin() {
  if [ -d "$VENV/Scripts" ]; then echo "$VENV/Scripts"; else echo "$VENV/bin"; fi
}

find_python() {
  local c
  for c in python3.13 python3.12 python3.11 python3.10 python3 python; do
    if command -v "$c" >/dev/null 2>&1 &&
       "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1; then
      echo "$c"; return
    fi
  done
}

if [ ! -x "$(venv_bin)/streamlit" ] && [ ! -x "$(venv_bin)/streamlit.exe" ]; then
  PY="$(find_python)"
  if [ -z "$PY" ]; then
    echo "Python 3.10 or newer was not found. Install it from https://www.python.org/downloads/ (or: brew install python) and try again."
    exit 1
  fi
  echo "Creating virtual environment ($VENV) with $PY and installing packages..."
  rm -rf "$VENV"
  "$PY" -m venv "$VENV"
  "$(venv_bin)/python" -m pip install --upgrade pip >/dev/null
  "$(venv_bin)/python" -m pip install -r python/requirements.txt
fi

# Bind to localhost only so the app is not reachable from other machines.
exec "$(venv_bin)/streamlit" run python/app.py --server.address localhost --browser.gatherUsageStats false "$@"
