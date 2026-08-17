@echo off
rem WimForge -- https://github.com/centauri/wimforge
rem Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
rem
rem Double-click this to open the window.
rem
rem See WimForge-Menu.cmd for why powershell.exe is called by full path rather
rem than letting Explorer decide. Two things are specific to this one:
rem
rem   -STA          WinForms needs a single-threaded apartment. powershell.exe
rem                 has defaulted to STA since v3, so this is belt and braces --
rem                 but pwsh does not, and being explicit costs nothing.
rem
rem   the console   A console window stays open behind the GUI. That is
rem                 deliberate and it is not hidden: when the GUI fails to start
rem                 -- a syntax error, a missing assembly, a module that will not
rem                 import -- the reason is printed there and nowhere else. A
rem                 hidden window turns that into "it just does not open", which
rem                 is a bad afternoon. Minimise it if it is in the way; closing
rem                 it closes WimForge.

setlocal
set "WF_HERE=%~dp0"
set "WF_SCRIPT=%WF_HERE%Start-WimForgeGui.ps1"

if not exist "%WF_SCRIPT%" (
    echo.
    echo   Start-WimForgeGui.ps1 is not next to this launcher.
    echo   Looked for: %WF_SCRIPT%
    echo.
    echo   Keep the launcher in the WimForge folder -- it finds everything else
    echo   relative to itself.
    echo.
    pause
    exit /b 1
)

set "WF_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%WF_PS%" set "WF_PS=powershell.exe"

echo.
echo   Starting WimForge. This window is the log -- leave it open.
echo.

"%WF_PS%" -NoProfile -ExecutionPolicy Bypass -STA -File "%WF_SCRIPT%" %* -Elevate
set "WF_RC=%ERRORLEVEL%"

if not "%WF_RC%"=="0" (
    echo.
    echo   WimForge exited with code %WF_RC%.
    echo.
    pause
)

endlocal
exit /b %WF_RC%
