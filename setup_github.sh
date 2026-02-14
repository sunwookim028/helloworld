#!/bin/bash
# Script to create GitHub repository and push code
# Run this script to complete the GitHub setup

echo "=========================================="
echo "GitHub Repository Setup"
echo "=========================================="
echo ""

# Check if gh is installed
if ! command -v gh &> /dev/null; then
    echo "GitHub CLI (gh) is not installed."
    echo "Installing gh..."
    sudo apt update && sudo apt install -y gh
    
    if [ $? -ne 0 ]; then
        echo "Failed to install gh. Please install manually:"
        echo "  sudo apt install gh"
        exit 1
    fi
fi

echo "✓ GitHub CLI is installed"
echo ""

# Check if authenticated
if ! gh auth status &> /dev/null; then
    echo "Not authenticated with GitHub."
    echo "Please authenticate:"
    gh auth login
    
    if [ $? -ne 0 ]; then
        echo "Authentication failed. Please try again."
        exit 1
    fi
fi

echo "✓ Authenticated with GitHub"
echo ""

# Create repository
echo "Creating repository sunwookim028/helloworld..."
gh repo create sunwookim028/helloworld --public --description "V80 FPGA PCIe-HBM Loopback Design" --source=. --remote=origin

if [ $? -ne 0 ]; then
    echo "Failed to create repository. It may already exist."
    echo "Trying to push anyway..."
fi

echo ""
echo "Pushing code to GitHub..."
git push -u origin main

if [ $? -eq 0 ]; then
    echo ""
    echo "=========================================="
    echo "✓ Success! Code pushed to GitHub"
    echo "=========================================="
    echo ""
    echo "Repository: https://github.com/sunwookim028/helloworld"
    echo ""
else
    echo ""
    echo "Push failed. Please check:"
    echo "  1. Repository exists: https://github.com/sunwookim028/helloworld"
    echo "  2. You have push access"
    echo "  3. Try manual push: git push -u origin main"
fi
