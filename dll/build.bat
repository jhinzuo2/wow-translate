@echo off
REM WoWTranslate DLL Build Script for Windows
REM Requires: Visual Studio 2022 with C++ workload, CMake 3.20+,
REM           vcpkg with: vcpkg install curl[openssl]:x86-windows-static
REM Set VCPKG_ROOT below (or as an env var) before running.

echo ============================================
echo WoWTranslate DLL Build Script
echo ============================================
echo.

REM Check for CMake
where cmake >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo ERROR: CMake not found. Please install CMake 3.20+ and add to PATH.
    exit /b 1
)

REM Check for Visual Studio
if not exist "%ProgramFiles%\Microsoft Visual Studio\2022" (
    if not exist "%ProgramFiles(x86)%\Microsoft Visual Studio\2022" (
        echo WARNING: Visual Studio 2022 not found in default location.
        echo Make sure you have Visual Studio 2022 with C++ workload installed.
    )
)

REM Create build directory
if not exist build mkdir build
cd build

echo.
echo Configuring CMake for 32-bit build...
echo.

REM Configure for 32-bit (WoW 1.12 is 32-bit)
if "%VCPKG_ROOT%"=="" (
    echo ERROR: VCPKG_ROOT is not set. Install vcpkg, run:
    echo   vcpkg install curl[openssl]:x86-windows-static
    echo then set VCPKG_ROOT to your vcpkg checkout path and re-run this script.
    cd ..
    exit /b 1
)

cmake .. -G "Visual Studio 17 2022" -A Win32 ^
    -DCMAKE_TOOLCHAIN_FILE=%VCPKG_ROOT%\scripts\buildsystems\vcpkg.cmake ^
    -DVCPKG_TARGET_TRIPLET=x86-windows-static

if %ERRORLEVEL% neq 0 (
    echo ERROR: CMake configuration failed.
    cd ..
    exit /b 1
)

echo.
echo Building Release configuration...
echo.

cmake --build . --config Release

if %ERRORLEVEL% neq 0 (
    echo ERROR: Build failed.
    cd ..
    exit /b 1
)

echo.
echo ============================================
echo Build successful!
echo ============================================
echo.
echo Output: build\bin\Release\WoWTranslate.dll
echo.
echo Installation:
echo 1. Copy WoWTranslate.dll to your WoW folder (next to WoW.exe)
echo 2. Add "WoWTranslate.dll" to dlls.txt
echo 3. Copy WoWTranslate addon folder to Interface\AddOns\
echo.

cd ..
