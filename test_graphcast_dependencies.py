#!/usr/bin/env python3
"""
Test script to verify GraphCast dependencies and basic functionality
"""

import sys
import traceback

def test_basic_dependencies():
    """Test basic Python dependencies"""
    print("Testing basic dependencies...")
    
    try:
        import xarray as xr
        import numpy as np
        import pandas as pd
        import zarr
        print("✅ Basic dependencies (xarray, numpy, pandas, zarr) available")
        return True
    except ImportError as e:
        print(f"❌ Missing basic dependencies: {e}")
        return False

def test_graphcast_dependencies():
    """Test GraphCast-specific dependencies"""
    print("\nTesting GraphCast dependencies...")
    
    missing_deps = []
    
    try:
        import jax
        print("✅ JAX available")
    except ImportError:
        missing_deps.append("jax")
        print("❌ JAX not available")
    
    try:
        import haiku as hk
        print("✅ Haiku available")
    except ImportError:
        missing_deps.append("dm-haiku")
        print("❌ Haiku not available")
    
    try:
        from google.cloud import storage
        print("✅ Google Cloud Storage available")
    except ImportError:
        missing_deps.append("google-cloud-storage")
        print("❌ Google Cloud Storage not available")
    
    try:
        from graphcast import autoregressive
        print("✅ GraphCast library available")
    except ImportError:
        missing_deps.append("graphcast")
        print("❌ GraphCast library not available")
    
    if missing_deps:
        print(f"\n⚠️ Missing dependencies: {', '.join(missing_deps)}")
        print("Run './install_graphcast.sh' to install missing dependencies")
        return False
    else:
        print("\n✅ All GraphCast dependencies available")
        return True

def test_script_import():
    """Test if the main script can be imported"""
    print("\nTesting script import...")
    
    try:
        import run_graphcast_forecast
        print("✅ GraphCast forecast script imports successfully")
        return True
    except ImportError as e:
        print(f"❌ Failed to import script: {e}")
        traceback.print_exc()
        return False

def main():
    """Run all tests"""
    print("GraphCast Dependencies Test")
    print("=" * 40)
    
    print(f"Python version: {sys.version}")
    print(f"Python executable: {sys.executable}")
    print()
    
    basic_ok = test_basic_dependencies()
    graphcast_ok = test_graphcast_dependencies()
    script_ok = test_script_import()
    
    print("\n" + "=" * 40)
    print("Test Summary:")
    print(f"Basic dependencies: {'✅ PASS' if basic_ok else '❌ FAIL'}")
    print(f"GraphCast dependencies: {'✅ PASS' if graphcast_ok else '❌ FAIL'}")
    print(f"Script import: {'✅ PASS' if script_ok else '❌ FAIL'}")
    
    if basic_ok and graphcast_ok and script_ok:
        print("\n🎉 All tests passed! GraphCast forecasting is ready to use.")
        return 0
    else:
        print("\n⚠️ Some tests failed. Install missing dependencies before running forecasts.")
        return 1

if __name__ == "__main__":
    sys.exit(main())
