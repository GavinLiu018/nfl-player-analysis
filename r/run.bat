@echo off
rem Launches the R (Shiny) version in your browser (Windows). Close this window to stop it.
cd /d "%~dp0.."
set "RSCRIPT="
for /f "delims=" %%d in ('dir /b /ad /o-n "%ProgramFiles%\R\R-*" 2^>nul') do if not defined RSCRIPT set "RSCRIPT=%ProgramFiles%\R\%%d\bin\Rscript.exe"
if not defined RSCRIPT (
  where Rscript >nul 2>nul && set "RSCRIPT=Rscript"
)
if not defined RSCRIPT (
  echo R was not found. Install it from https://cran.r-project.org/ and try again.
  pause
  exit /b 1
)
echo Using %RSCRIPT%
"%RSCRIPT%" r\install.R
"%RSCRIPT%" -e "shiny::runApp('r', launch.browser = TRUE)"
pause
