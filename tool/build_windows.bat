@echo off
rem ---------------------------------------------------------------------------
rem ScaleGuard - Windows build helper
rem
rem Flutter's own `flutter build windows` requires the "C++ CMake tools for
rem Windows" component of Visual Studio. That component can only be installed
rem with administrator rights, so this script performs the same two build steps
rem with a standalone CMake (pip) and Ninja, using the MSVC toolchain that the
rem Visual Studio Build Tools already provide through vcvars64.bat.
rem
rem Usage:  tool\build_windows.bat [debug|release]      (default: debug)
rem
rem The INSTALL target places flutter_windows.dll, icudtl.dat and the
rem flutter_assets bundle next to the executable, and this script then copies
rem the mihomo sidecar into <out>\core\, which is the layout the app resolves at
rem runtime.
rem ---------------------------------------------------------------------------
setlocal

set "MODE=%~1"
if "%MODE%"=="" set "MODE=debug"

set "PROJECT_ROOT=%~dp0.."
pushd "%PROJECT_ROOT%"

set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCVARS%" (
  echo [ScaleGuard] vcvars64.bat not found at "%VCVARS%".
  echo [ScaleGuard] Install Visual Studio Build Tools with the C++ workload.
  popd & exit /b 1
)

rem cmake: prefer PATH, then the copy installed by `python -m pip install cmake`.
set "CMAKE_EXE="
for /f "delims=" %%C in ('where cmake.exe 2^>nul') do if not defined CMAKE_EXE set "CMAKE_EXE=%%C"
if not defined CMAKE_EXE set "CMAKE_EXE=%APPDATA%\Python\Python313\Scripts\cmake.exe"
if not exist "%CMAKE_EXE%" (
  echo [ScaleGuard] cmake.exe not found. Run: python -m pip install --user cmake
  popd & exit /b 1
)

rem ninja: it is installed by winget, which does not refresh this session's
rem PATH, so the known install locations are searched explicitly.
set "NINJA_EXE="
for /f "delims=" %%N in ('where ninja.exe 2^>nul') do if not defined NINJA_EXE set "NINJA_EXE=%%N"
if not defined NINJA_EXE (
  if exist "%LOCALAPPDATA%\Microsoft\WinGet\Links\ninja.exe" set "NINJA_EXE=%LOCALAPPDATA%\Microsoft\WinGet\Links\ninja.exe"
)
if not defined NINJA_EXE (
  for /d %%D in ("%LOCALAPPDATA%\Microsoft\WinGet\Packages\Ninja-build.Ninja*") do (
    if not defined NINJA_EXE if exist "%%D\ninja.exe" set "NINJA_EXE=%%D\ninja.exe"
  )
)
if not defined NINJA_EXE (
  echo [ScaleGuard] ninja.exe not found. Run: winget install --id Ninja-build.Ninja
  popd & exit /b 1
)
rem CMake invokes the program by name, so its folder must be on PATH.
for %%N in ("%NINJA_EXE%") do set "PATH=%%~dpN;%PATH%"

echo [ScaleGuard] mode  = %MODE%
echo [ScaleGuard] cmake = %CMAKE_EXE%
echo [ScaleGuard] ninja = %NINJA_EXE%

call "%VCVARS%" >nul
if errorlevel 1 (
  echo [ScaleGuard] failed to initialise the MSVC environment.
  popd & exit /b 1
)

set "BUILD_DIR=%PROJECT_ROOT%\build\windows\x64\%MODE%"
if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"

echo [ScaleGuard] staging Flutter engine artifacts...
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%PROJECT_ROOT%\tool\stage_flutter_artifacts.ps1" -Mode %MODE%
if errorlevel 1 (
  echo [ScaleGuard] staging failed.
  popd & exit /b 1
)

echo [ScaleGuard] configuring...
"%CMAKE_EXE%" -G Ninja ^
  -DCMAKE_MAKE_PROGRAM="%NINJA_EXE%" ^
  -DCMAKE_BUILD_TYPE=%MODE% ^
  -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl ^
  -DFLUTTER_TARGET_PLATFORM=windows-x64 ^
  -S "%PROJECT_ROOT%\windows" ^
  -B "%BUILD_DIR%"
if errorlevel 1 (
  echo [ScaleGuard] cmake configure failed.
  popd & exit /b 1
)

echo [ScaleGuard] building...
rem With a single-config generator the install target is lower-case `install`;
rem it is what copies flutter_windows.dll, icudtl.dat and the flutter_assets
rem bundle next to the executable.
"%CMAKE_EXE%" --build "%BUILD_DIR%" --target install
if errorlevel 1 (
  echo [ScaleGuard] build failed.
  popd & exit /b 1
)

set "OUT_DIR=%BUILD_DIR%\runner"
if not exist "%OUT_DIR%\core" mkdir "%OUT_DIR%\core"
copy /y "%PROJECT_ROOT%\windows\runner\mihomo.exe" "%OUT_DIR%\core\mihomo.exe" >nul
if exist "%PROJECT_ROOT%\windows\runner\NOTICE.txt" copy /y "%PROJECT_ROOT%\windows\runner\NOTICE.txt" "%OUT_DIR%\core\NOTICE.txt" >nul

echo [ScaleGuard] done: %OUT_DIR%\ScaleGuard.exe
popd
endlocal
