#!/bin/bash
set -e
echo "Running post-install steps..."
cd /opt/app
pip install -r requirements.txt
echo "Dependencies installed."
