#!/usr/bin/env bash
# Launches the R (Shiny) version in your browser (macOS / Linux).
# macOS: double-click this file in Finder (first time: right-click > Open), or run:  bash r/run.command
# Press Ctrl+C in this window to stop the app.
set -euo pipefail
cd "$(dirname "$0")/.."

find_rscript() {
  if command -v Rscript >/dev/null 2>&1; then command -v Rscript; return; fi
  local c
  for c in /Library/Frameworks/R.framework/Resources/bin/Rscript \
           /opt/homebrew/bin/Rscript /usr/local/bin/Rscript /usr/bin/Rscript; do
    if [ -x "$c" ]; then echo "$c"; return; fi
  done
  # Git Bash on Windows (lets this script be tested there too).
  for c in "/c/Program Files/R"/R-*/bin/Rscript.exe; do
    if [ -x "$c" ]; then echo "$c"; fi
  done | sort -V | tail -n 1
}

RSCRIPT="$(find_rscript)"
if [ -z "$RSCRIPT" ]; then
  echo "R was not found. Install it from https://cran.r-project.org/ (or: brew install --cask r) and try again."
  exit 1
fi
echo "Using $RSCRIPT"
"$RSCRIPT" r/install.R
exec "$RSCRIPT" -e "shiny::runApp('r', launch.browser = TRUE)"
