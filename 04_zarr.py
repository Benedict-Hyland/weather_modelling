#!/usr/bin/env puv run python
import sys
from pathlib import Path
import xarray as xr
import time

# ======================
# Directory configuration
# ======================
DATA_DIR = Path("./extraction_data")
OUTPUT_DIR = Path("./outputs")
OUTPUT_DIR.mkdir(exist_ok=True)

# ======================
# Specialized open funcs
# ======================

def open_isobaric_ds1(file: str) -> xr.Dataset:
    """Open pgrb2 isobaric pressure level dataset"""
    return xr.open_dataset(
        file,
        engine="cfgrib",
        backend_kwargs={
            "filter_by_keys": {
                "shortName": ["t", "u", "v", "gh", "w"],
                "typeOfLevel": "isobaricInhPa"
            },
            "read_keys": ["shortName", "typeOfLevel", "levels"],
            "indexpath": ""
        }
    )

def open_isobaric_ds2(file: str) -> xr.Dataset:
    """Open pgrb2b (extra levels)"""
    return xr.open_dataset(
        file,
        engine="cfgrib",
        backend_kwargs={
            "filter_by_keys": {
                "shortName": ["t", "u", "v", "gh", "w"],
                "level": [875, 825, 775, 225, 175, 125],
                "typeOfLevel": "isobaricInhPa"
            },
            "read_keys": ["shortName", "typeOfLevel", "levels"],
            "indexpath": ""
        }
    )

def open_surface_2m(file: str) -> xr.Dataset:
    """Open 2m temperature dataset"""
    ds = xr.open_dataset(
        file,
        engine="cfgrib",
        backend_kwargs={
            "filter_by_keys": {
                "shortName": ["2t"],
                "typeOfLevel": "heightAboveGround",
                "level": 2
            },
            "read_keys": ["shortName", "typeOfLevel", "levels"],
            "indexpath": ""
        }
    )
    return ds.rename({"heightAboveGround": "heightAboveGround_2m"})

def open_surface_10m(file: str) -> xr.Dataset:
    """Open 10m winds dataset"""
    ds = xr.open_dataset(
        file,
        engine="cfgrib",
        backend_kwargs={
            "filter_by_keys": {
                "shortName": ["10u", "10v"],
                "typeOfLevel": "heightAboveGround",
                "level": 10
            },
            "read_keys": ["shortName", "typeOfLevel", "levels"],
            "indexpath": ""
        }
    )
    return ds.rename({"heightAboveGround": "heightAboveGround_10m"})

def open_land_mask(file: str) -> xr.Dataset:
    """Open Land/Sea mask dataset"""
    ds = xr.open_dataset(
        file,
        engine="cfgrib",
        backend_kwargs={
            "filter_by_keys": {
                "shortName": ["land"],
                "typeOfLevel": "surface",
            },
            "read_keys": ["shortName", "typeOfLevel"]
        }
    )
    return ds


# ======================
# File discovery helpers
# ======================

def find_forecast_files(key: str):
    """
    Given a key like '20250720_06_004', find the pgrb2 (pgrba) and pgrb2b (pgrbb).
    Returns dict like:
    {
        "pgrb2": Path(...),
        "pgrb2b": Path(...)
    }
    """
    files = {}
    pgrba = DATA_DIR / f"{key}_pgrba.grib2"
    pgrbb = DATA_DIR / f"{key}_pgrbb.grib2"
    if pgrba.exists():
        files["pgrb2"] = pgrba
    if pgrbb.exists():
        files["pgrb2b"] = pgrbb
    return files

def validate_dataset(ds: xr.Dataset, name: str):
    """Sanity check"""
    if ds is None:
        raise ValueError(f"{name} is None")
    if len(ds.data_vars) == 0:
        raise ValueError(f"{name} has no data variables")

def merge_forecast_step(files_dict: dict) -> xr.Dataset:
    """
    Merge all available datasets for ONE forecast time step:
    - isobaric from pgrb2
    - surface 2m + 10m from pgrb2
    - extra isobaric from pgrb2b
    """
    ds_list = []

    if "pgrb2" in files_dict:
        print(f"  Processing pgrb2 → {files_dict['pgrb2']}")
        iso_ds1 = open_isobaric_ds1(files_dict["pgrb2"])
        validate_dataset(iso_ds1, "isobaric_ds1")
        ds_list.append(iso_ds1)

        surface_2m = open_surface_2m(files_dict["pgrb2"])
        validate_dataset(surface_2m, "surface_2m")
        ds_list.append(surface_2m)

        surface_10m = open_surface_10m(files_dict["pgrb2"])
        validate_dataset(surface_10m, "surface_10m")
        ds_list.append(surface_10m)

        land_mask = open_land_mask(files_dict["pgrb2"])
        validate_dataset(land_mask, "land/sea mask")
        ds_list.append(land_mask)

    if "pgrb2b" in files_dict:
        print(f"  Processing pgrb2b → {files_dict['pgrb2b']}")
        iso_ds2 = open_isobaric_ds2(files_dict["pgrb2b"])
        validate_dataset(iso_ds2, "isobaric_ds2")
        ds_list.append(iso_ds2)

    if not ds_list:
        raise FileNotFoundError("No valid GRIB files found for this forecast step")

    return xr.merge(ds_list)


# ======================
# Two-forecast merge
# ======================

def process_two_forecasts(key1: str, key2: str):
    """
    Process two forecast keys (e.g. 20250720_06_004 + 20250720_12_004)
    and save concatenated Zarr.
    """
    print(f"🔍 Looking for forecast files for {key1} + {key2}")

    # Get required files
    files1 = find_forecast_files(key1)
    files2 = find_forecast_files(key2)

    # Require at least pgrb2 for both
    if "pgrb2" not in files1:
        sys.exit(f"❌ Missing pgrb2 for {key1}")
    if "pgrb2" not in files2:
        sys.exit(f"❌ Missing pgrb2 for {key2}")

    # Merge each time step
    print(f"✅ Merging forecast step {key1}")
    ds1 = merge_forecast_step(files1)
    print(f"✅ Merging forecast step {key2}")
    ds2 = merge_forecast_step(files2)

    # Add synthetic time dim
    ds1 = ds1.expand_dims(time=[0])
    ds2 = ds2.expand_dims(time=[1])

    # Concatenate along time
    combined = xr.concat([ds1, ds2], dim="time")

    # Save Zarr
    out_path = OUTPUT_DIR / f"{key1}_output.zarr"
    print(f"💾 Saving to Zarr → {out_path}")
    combined.to_zarr(out_path, mode="w")
    print(f"✅ Done: {out_path}")


def main():
    if len(sys.argv) != 3:
        print("Usage: ./04_zarr.py yyyymmdd_hh_### yyyymmdd_hh_###")
        sys.exit(1)

    key1 = sys.argv[1]
    key2 = sys.argv[2]

    start = time.time()
    process_two_forecasts(key1, key2)
    print(f"⏱ Total time: {time.time()-start:.1f}s")

if __name__ == "__main__":
    main()
