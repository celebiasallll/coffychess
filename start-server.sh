#!/bin/bash

echo "========================================"
echo "    COFFEE CHESS BACKEND SERVER"
echo "========================================"
echo ""

# Check if Node.js is installed
if ! command -v node &> /dev/null; then
    echo "ERROR: Node.js is not installed or not in PATH"
    echo "Please install Node.js from https://nodejs.org/"
    echo ""
    read -p "Press Enter to continue..."
    exit 1
fi

# Display Node.js version
echo "Node.js version:"
node --version
echo ""

# Check if package.json exists
if [ ! -f "package.json" ]; then
    echo "ERROR: package.json not found"
    echo "Please make sure you're in the correct directory"
    echo ""
    read -p "Press Enter to continue..."
    exit 1
fi

# Install dependencies if node_modules doesn't exist
if [ ! -d "node_modules" ]; then
    echo "Installing dependencies..."
    npm install
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to install dependencies"
        echo ""
        read -p "Press Enter to continue..."
        exit 1
    fi
    echo "Dependencies installed successfully!"
    echo ""
fi

# Start the server
echo "Starting Coffee Chess backend server..."
echo "Server will be available at: http://localhost:3005"
echo ""
echo "Press Ctrl+C to stop the server"
echo "========================================"
echo ""

npm start

# If server stops, wait for user input
echo ""
echo "Server has stopped."
# Only pause if running interactively
if [ -t 0 ]; then
    read -p "Press Enter to continue..."
fi 
