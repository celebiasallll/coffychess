@echo off
title Coffee Chess Backend Server
echo ========================================
echo     COFFEE CHESS BACKEND SERVER
echo ========================================
echo.

REM Check if Node.js is installed
node --version >nul 2>&1
if errorlevel 1 (
    echo ERROR: Node.js is not installed or not in PATH
    echo Please install Node.js from https://nodejs.org/
    echo.
    pause
    exit /b 1
)

REM Display Node.js version
echo Node.js version:
node --version
echo.

REM Check if package.json exists
if not exist package.json (
    echo ERROR: package.json not found
    echo Please make sure you're in the correct directory
    echo.
    pause
    exit /b 1
)

REM Install dependencies if node_modules doesn't exist
if not exist node_modules (
    echo Installing dependencies...
    npm install
    if errorlevel 1 (
        echo ERROR: Failed to install dependencies
        echo.
        pause
        exit /b 1
    )
    echo Dependencies installed successfully!
    echo.
)

REM Start the server
echo Starting Coffee Chess backend server...
echo Server will be available at: http://localhost:3005
echo.
echo Press Ctrl+C to stop the server
echo ========================================
echo.

npm start

REM If server stops, wait for user input
echo.
echo Server has stopped.
pause 
