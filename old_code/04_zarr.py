#!/usr/bin/env python
import sys
import argparse
from pathlib import Path
import xarray as xr
import time

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
        },
        decode_timedelta=True
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
        },
        decode_timedelta=True
    )

def open_surface_2m(file: str) -> xr.Dataset:
    """Open 2m temperature dataset"""
    ds = xr.open_dataset(
        file,
        engine="cfgrib",
        backend_kwargs={
            "filter_by_keys": {"shortName": ["2t"], "typeOfLevel": "heightAboveGround", "level": 2},
            "read_keys": ["shortName", "typeOfLevel", "levels"],
            "indexpath": ""
        },
        decode_timedelta=True
    )
    return ds.rename({"heightAboveGround": "heightAboveGround_2m"})

def open_surface_10m(file: str) -> xr.Dataset:
    """Open 10m winds dataset"""
    ds = xr.open_dataset(
        file,
        engine="cfgrib",
        backend_kwargs={
            "filter_by_keys": {"shortName": ["10u", "10v"], "typeOfLevel": "heightAboveGround", "level": 10},
            "read_keys": ["shortName", "typeOfLevel", "levels"],
            "indexpath": ""
        },
        decode_timedelta=True
    )
    return ds.rename({"heightAboveGround": "heightAboveGround_10m"})

def open_land_mask(file: str) -> xr.Dataset:
    """Open Land/Sea mask dataset"""
    ds = xr.open_dataset(
        file,
        engine="cfgrib",
        backend_kwargs={
            "filter_by_keys": {"shortName": "lsm", "typeOfLevel": "surface"},
            "read_keys": ["shortName", "typeOfLevel"],
            "indexpath": ""
        },
        decode_timedelta=True
    )
    return ds.rename({"surface": "surfaceLevel"})

def open_surface_geopotential(file: str) -> xr.Dataset:
    """Open geopotential height at the surface (model orography)"""
    ds = xr.open_dataset(
        file,
        engine="cfgrib",
        backend_kwargs={
            "filter_by_keys": {"shortName": "orog", "typeOfLevel": "surface"},
            "read_keys": ["shortName", "typeOfLevel"],
            "indexpath": ""
        },
        decode_timedelta=True
    )
    return ds.rename({"surface": "surface_level"})

def open_surface_solar_radiation(file: str) -> xr.Dataset:
    """Open downward shortwave radiation flux at the surface"""
    ds = xr.open_dataset(
        file,
        engine="cfgrib",
        backend_kwargs={
            "filter_by_keys": {"shortName": "fsr", "typeOfLevel": "surface"},
            "read_keys": ["shortName", "typeOfLevel"],
            "indexpath": ""
        },
        decode_timedelta=True
    )
    return ds.rename({"surface": "surface_level"})


# ======================
# File discovery helpers
# ======================

def _candidates_for_prefix(prefix_dir: Path, prefix_stem: str):
    """Build candidate paths for a given directory and key/prefix stem."""
    a = prefix_dir / f"{prefix_stem}_pgrba.grib2"
    b = prefix_dir / f"{prefix_stem}_pgrbb.grib2"
    return a, b

def find_forecast_files(key_or_path: str, search_dirs: list[Path]) -> dict:
    """
    Resolve files for a forecast 'key' like '20250720_06_004' OR a path/prefix.

    Rules:
    - If key_or_path is an existing .grib2 file, look for its sibling matching
      the other part (pgrba/pgrbb) and return both if present.
    - If key_or_path includes directories but not a suffix, treat it as a prefix
      directory + stem and build candidates there.
    - Otherwise, search each directory in search_dirs for {key}_pgrba.grib2 and {key}_pgrbb.grib2.
    """
    files: dict[str, Path] = {}

    p = Path(key_or_path)
    if p.suffix == ".grib2" and p.exists():
        name = p.name
        stem = name.replace("_pgrba.grib2", "").replace("_pgrbb.grib2", "")
        cand_a, cand_b = _candidates_for_prefix(p.parent, stem)
        if cand_a.exists():
            files["pgrb2"] = cand_a
        if cand_b.exists():
            files["pgrb2b"] = cand_b
        return files

    # If it includes a directory, search only there
    if p.parent != Path(".") and p.parent.exists() and p.name:
        cand_a, cand_b = _candidates_for_prefix(p.parent, p.name)
        if cand_a.exists():
            files["pgrb2"] = cand_a
        if cand_b.exists():
            files["pgrb2b"] = cand_b
        return files

    # Otherwise search provided search_dirs
    for d in search_dirs:
        cand_a, cand_b = _candidates_for_prefix(d, key_or_path)
        if cand_a.exists():
            files["pgrb2"] = cand_a
        if cand_b.exists():
            files["pgrb2b"] = cand_b
        if files:
            break
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
        print(f"  Processing pgrb2 -> {files_dict['pgrb2']}")
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

        surface_geopotential = open_surface_geopotential(files_dict["pgrb2"])
        validate_dataset(surface_geopotential, "surface geopotential")
        ds_list.append(surface_geopotential)

        surface_solar_radiation = open_surface_solar_radiation(files_dict["pgrb2"])
        validate_dataset(surface_solar_radiation, "surface solar radiation")
        ds_list.append(surface_solar_radiation)

    if "pgrb2b" in files_dict:
        print(f"  Processing pgrb2b -> {files_dict['pgrb2b']}")
        iso_ds2 = open_isobaric_ds2(files_dict["pgrb2b"])
        validate_dataset(iso_ds2, "isobaric_ds2")
        ds_list.append(iso_ds2)

    if not ds_list:
        raise FileNotFoundError("No valid GRIB files found for this forecast step")

    return xr.merge(ds_list)


# ======================
# Two-forecast merge
# ======================

def process_two_forecasts(key1: str, key2: str, search_dirs: list[Path], output_dir: Path):
    """
    Process two forecast keys/paths (e.g. 20250720_06_004 + 20250720_12_004)
    and save concatenated Zarr into output_dir.
    """
    print(f"🔍 Resolving forecast files for {key1} and {key2}")
    files1 = find_forecast_files(key1, search_dirs)
    files2 = find_forecast_files(key2, search_dirs)

    missing = []
    if "pgrb2" not in files1:
        missing.append(f"pgrb2 for {key1}")
    if "pgrb2" not in files2:
        missing.append(f"pgrb2 for {key2}")
    if missing:
        raise FileNotFoundError("Missing required files: " + ", ".join(missing))

    print(f"✅ Merging forecast step {key1}")
    ds1 = merge_forecast_step(files1)
    print(f"✅ Merging forecast step {key2}")
    ds2 = merge_forecast_step(files2)

    # Add synthetic time dim
    ds1 = ds1.expand_dims(time=[0])
    ds2 = ds2.expand_dims(time=[1])

    combined = xr.concat([ds1, ds2], dim="time")

    # Save Zarr
    output_dir.mkdir(parents=True, exist_ok=True)
    # Use a neutral stem for filename (strip directories/suffixes if paths were passed)
    stem1 = Path(key1).stem.replace("_pgrba", "").replace("_pgrbb", "")
    out_path = output_dir / f"{stem1}_output.zarr"
    out_path_nc = output_dir / f"{stem1}_output.nc"
    print(f"💾 Saving to Zarr -> {out_path}")
    combined.to_zarr(out_path, mode="w")
    print(f"💾 Saving to NetCDF -> {out_path_nc}")
    combined.to_netcdf(out_path_nc, mode="w")
    print(f"✅ Done. Files saved to: {stem1}_output")


def parse_args():
    p = argparse.ArgumentParser(
        description="Merge two forecast steps (GRIB) into a small Zarr time series."
    )
    p.add_argument("key1", help="Forecast key or path (e.g. 20250720_06_004 or /data/run/20250720_06_004 or a .grib2 file)")
    p.add_argument("key2", help="Second forecast key or path")
    p.add_argument(
        "-d", "--data-dir",
        action="append",
        default=["./extraction_data"],
        help="Directory to search for files. Can be used multiple times. Defaults to ./extraction_data"
    )
    p.add_argument(
        "-o", "--output-dir",
        default="./outputs",
        help="Directory to write Zarr output. Defaults to ./outputs"
    )
    return p.parse_args()

def main():
    args = parse_args()
    search_dirs = [Path(d).expanduser().resolve() for d in args.data_dir]
    output_dir = Path(args.output_dir).expanduser().resolve()

    start = time.time()
    try:
        process_two_forecasts(args.key1, args.key2, search_dirs, output_dir)
    finally:
        print(f"⏱ Total time: {time.time()-start:.1f}s")

if __name__ == "__main__":
    main()
