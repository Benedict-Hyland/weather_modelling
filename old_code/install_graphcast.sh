#!/bin/bash

set -e

echo "🚀 Installing GraphCast and dependencies..."

if [ ! -d ".venv" ]; then
    echo "📦 Creating Python virtual environment..."
    python -m venv .venv
fi

echo "🔧 Activating virtual environment..."
source .venv/bin/activate

echo "⬆️ Upgrading pip..."
pip install --upgrade pip

echo "📋 Installing base dependencies..."
pip install -e .

echo "🌍 Installing GraphCast from GitHub..."
pip install --upgrade https://github.com/deepmind/graphcast/archive/master.zip

echo "🔧 Installing additional dependencies..."
pip install cartopy matplotlib ipywidgets

echo "🛠️ Applying cartopy workaround..."
pip uninstall -y shapely || true
pip install shapely --no-binary shapely

echo "✅ GraphCast installation completed!"
echo ""
echo "To use GraphCast forecasting:"
echo "1. Activate the virtual environment: source .venv/bin/activate"
echo "2. Run the forecasting script: python run_graphcast_forecast.py"
echo ""
echo "Make sure you have zarr forecast files in the ./outputs directory first."
