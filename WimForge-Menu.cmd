@echo off
rem WimForge -- https://github.com/centauri/wimforge
rem Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
rem
rem Double-click this to open the console menu.
rem
rem There is more here than "run the script", and each line is load-bearing:
rem
rem   powershell.exe by full path   Double-clicking a .ps1 runs it through
rem                                 whatever is registered for .ps1, and on a
rem                                 machine with PowerShell 7 installed that is
rem                                 pwsh. WimForge needs Windows PowerShell 5.1
rem                                 Desktop, where the DISM module runs natively
rem                                 instead of through a compatibility shim. The
rem                                 full path is used because PATH is not
rem                                 guaranteed on a freshly built machine.
rem
rem   -ExecutionPolicy Bypass       For this process only; nothing is changed on
rem                                 the machine. It also gets past the block on
rem                                 files that came out of a downloaded zip,
rem                                 which is otherwise a confusing first run.
rem
rem   -Elevate                      The script asks for elevation itself, so
rem                                 there is one UAC prompt and one elevation
rem                                 path rather than two that can disagree.
rem
rem   the pause at the end          A double-clicked window that closes on
rem                                 failure shows a flash of black and nothing
rem                                 else. If it exits badly, the window stays up
rem                                 with the reason still on it.
rem
rem Nothing here needs the current directory to be anything in particular, so it
rem also works from a UNC path or a memory stick.

setlocal
set "WF_HERE=%~dp0"
set "WF_SCRIPT=%WF_HERE%Start-WimForgeMenu.ps1"

if not exist "%WF_SCRIPT%" (
    echo.
    echo   Start-WimForgeMenu.ps1 is not next to this launcher.
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
