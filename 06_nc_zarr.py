#!/usr/bin/env python3
import sys
import xarray as xr
import numpy as np
import pandas as pd
from datetime import timedelta

def merge_nc_to_zarr(nc1_path, nc2_path, output_zarr):
    # Open both NetCDF files
    ds1 = xr.open_dataset(nc1_path)
    ds2 = xr.open_dataset(nc2_path)

    # Ensure they both have a time dimension
    if "time" not in ds1.dims and "time" not in ds1.coords:
        raise ValueError(f"{nc1_path} has no time dimension/coordinate!")
    if "time" not in ds2.dims and "time" not in ds2.coords:
        raise ValueError(f"{nc2_path} has no time dimension/coordinate!")

    # Get the first time in ds2 to calculate alignment
    first_time_ds2 = pd.to_datetime(ds2.time.values[0])

    # Shift ds1 times to be 6 hours earlier than ds2's first timestamp
    shifted_time_ds1 = first_time_ds2 - timedelta(hours=6)
    # Calculate the offset needed for ds1
    offset = shifted_time_ds1 - pd.to_datetime(ds1.time.values[0])

    ds1["time"] = pd.to_datetime(ds1.time.values) + offset

    # Concatenate along time
    merged_ds = xr.concat([ds1, ds2], dim="time")

    # Sort times just in case
    merged_ds = merged_ds.sortby("time")

    # Save to Zarr
    merged_ds.to_zarr(output_zarr, mode="w")
    print(f"✅ Merged Zarr saved to: {output_zarr}")

if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: merge_nc_to_zarr.py <file1.nc> <file2.nc> <output.zarr>")
        sys.exit(1)

    nc1_path = sys.argv[1]
    nc2_path = sys.argv[2]
    output_zarr = sys.argv[3]

    merge_nc_to_zarr(nc1_path, nc2_path, output_zarr)
