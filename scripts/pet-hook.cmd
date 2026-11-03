@echo off
setlocal
rem A bare .sh hook command is resolved through the Windows file association,
rem which pops a "choose an app" dialog instead of running it. Start the
rem console-subsystem bash.exe explicitly so stdin and stdout stay connected.
set "BASH="
if defined CLAUDE_CODE_GIT_BASH_PATH if exist "%CLAUDE_CODE_GIT_BASH_PATH%" set "BASH=%CLAUDE_CODE_GIT_BASH_PATH%"
if not defined BASH if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH for %%I in (bash.exe) do set "BASH=%%~$PATH:I"
if not defined BASH exit /b 0

"%BASH%" "%~dp0pet-hook.sh"
exit /b %ERRORLEVEL%