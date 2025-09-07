#!/usr/bin/env python3
"""
GraphCast Forecasting Script

This script processes existing zarr forecast files through the GraphCast operational model,
predicting each 6-hour timestep out to 10 days ahead (240 hours total), and merges all
zarr forecast outputs into a single comprehensive file.

Usage:
    python run_graphcast_forecast.py

Output:
    graphcast_forecast_yyyy_mm_dd_hh.zarr - Single merged forecast file covering
    from earliest 6 hours to latest 6 hours + 246 hours ahead
"""

import sys
import os
import time
import datetime
from pathlib import Path
from typing import List, Dict, Optional
import logging

import xarray as xr
import numpy as np
import pandas as pd

try:
    import jax
    import jax.numpy as jnp
    import haiku as hk
    from google.cloud import storage
    
    from graphcast import autoregressive
    from graphcast import casting
    from graphcast import checkpoint
    from graphcast import data_utils
    from graphcast import graphcast
    from graphcast import normalization
    from graphcast import rollout
    from graphcast import xarray_jax
    from graphcast import xarray_tree
    
    GRAPHCAST_AVAILABLE = True
except ImportError as e:
    GRAPHCAST_AVAILABLE = False
    IMPORT_ERROR = str(e)

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('graphcast_forecast.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

ZARR_INPUT_DIR = Path("./outputs")
GRAPHCAST_OUTPUT_DIR = Path("./graphcast_outputs")
GRAPHCAST_OUTPUT_DIR.mkdir(exist_ok=True)

FORECAST_HOURS = 240  # 10 days
FORECAST_INTERVAL = 6  # 6-hour intervals
NUM_FORECAST_STEPS = FORECAST_HOURS // FORECAST_INTERVAL  # 40 steps

class GraphCastForecaster:
    """GraphCast forecasting engine"""
    
    def __init__(self):
        self.model = None
        self.params = None
        self.state = None
        self.model_config = None
        self.task_config = None
        self.normalization_stats = None
        
    def check_dependencies(self) -> bool:
        """Check if GraphCast dependencies are available"""
        if not GRAPHCAST_AVAILABLE:
            logger.error(f"GraphCast dependencies not available: {IMPORT_ERROR}")
            logger.error("Please install GraphCast using:")
            logger.error("pip install --upgrade https://github.com/deepmind/graphcast/archive/master.zip")
            return False
        return True
    
    def load_model(self, model_name: str = "GraphCast_operational") -> bool:
        """Load GraphCast operational model"""
        try:
            logger.info(f"Loading GraphCast model: {model_name}")
            
            gcs_client = storage.Client.create_anonymous_client()
            gcs_bucket = gcs_client.get_bucket("dm_graphcast")
            dir_prefix = "graphcast/"
            
            params_file = f"params/{model_name}.npz"
            logger.info(f"Downloading model parameters: {params_file}")
            
            with gcs_bucket.blob(f"{dir_prefix}{params_file}").open("rb") as f:
                ckpt = checkpoint.load(f, graphcast.CheckPoint)
                self.params = ckpt.params
                self.state = {}
                self.model_config = ckpt.model_config
                self.task_config = ckpt.task_config
                
            logger.info(f"Model loaded successfully")
            logger.info(f"Model description: {ckpt.description}")
            
            self._load_normalization_stats(gcs_bucket, dir_prefix)
            
            self._build_model()
            
            return True
            
        except Exception as e:
            logger.error(f"Failed to load GraphCast model: {e}")
            return False
    
    def _load_normalization_stats(self, gcs_bucket, dir_prefix: str):
        """Load normalization statistics"""
        logger.info("Loading normalization statistics...")
        
        with gcs_bucket.blob(f"{dir_prefix}stats/diffs_stddev_by_level.nc").open("rb") as f:
            self.diffs_stddev_by_level = xr.load_dataset(f).compute()
            
        with gcs_bucket.blob(f"{dir_prefix}stats/mean_by_level.nc").open("rb") as f:
            self.mean_by_level = xr.load_dataset(f).compute()
            
        with gcs_bucket.blob(f"{dir_prefix}stats/stddev_by_level.nc").open("rb") as f:
            self.stddev_by_level = xr.load_dataset(f).compute()
    
    def _build_model(self):
        """Build the GraphCast model with normalization"""
        logger.info("Building GraphCast model...")
        
        def construct_wrapped_graphcast(model_config, task_config):
            predictor = graphcast.GraphCast(model_config, task_config)
            
            predictor = casting.Bfloat16Cast(predictor)
            
            predictor = normalization.InputsAndResiduals(
                predictor,
                diffs_stddev_by_level=self.diffs_stddev_by_level,
                mean_by_level=self.mean_by_level,
                stddev_by_level=self.stddev_by_level
            )
            
            predictor = autoregressive.Predictor(predictor, gradient_checkpointing=True)
            
            return predictor
        
        @hk.transform_with_state
        def run_forward(model_config, task_config, inputs, targets_template, forcings):
            predictor = construct_wrapped_graphcast(model_config, task_config)
            return predictor(inputs, targets_template=targets_template, forcings=forcings)
        
        def with_configs(fn):
            return lambda *args, **kwargs: fn(
                *args, model_config=self.model_config, task_config=self.task_config, **kwargs
            )
        
        def with_params(fn):
            return lambda *args, **kwargs: fn(
                self.params, self.state, *args, **kwargs
            )
        
        def drop_state(fn):
            return lambda **kw: fn(**kw)[0]
        
        self.run_forward_jitted = drop_state(
            with_params(jax.jit(with_configs(run_forward.apply)))
        )
        
        logger.info("GraphCast model built successfully")
    
    def convert_zarr_to_graphcast_format(self, zarr_path: Path) -> Dict[str, xr.Dataset]:
        """Convert zarr file to GraphCast input format"""
        logger.info(f"Converting zarr file to GraphCast format: {zarr_path}")
        
        ds = xr.open_zarr(zarr_path)
        
        
        if 'time' in ds.dims and ds.dims['time'] >= 2:
            inputs = ds.isel(time=slice(0, 2))  # First two timesteps
            targets_template = ds.isel(time=slice(1, 2)) * np.nan  # Template for predictions
            
            if 'dswrf' in ds.data_vars:
                forcings = ds[['dswrf']].isel(time=slice(0, 2))
            else:
                forcings = xr.Dataset()
        else:
            raise ValueError(f"Zarr file must have at least 2 timesteps, got {ds.dims.get('time', 0)}")
        
        return {
            'inputs': inputs,
            'targets_template': targets_template,
            'forcings': forcings
        }
    
    def run_forecast(self, zarr_path: Path) -> xr.Dataset:
        """Run GraphCast forecast on zarr input"""
        logger.info(f"Running GraphCast forecast on: {zarr_path}")
        
        data = self.convert_zarr_to_graphcast_format(zarr_path)
        
        targets_template = data['targets_template']
        extended_targets = []
        
        for step in range(NUM_FORECAST_STEPS):
            step_target = targets_template.copy()
            new_time = targets_template.time.values[0] + np.timedelta64(step * FORECAST_INTERVAL, 'h')
            step_target = step_target.assign_coords(time=[new_time])
            extended_targets.append(step_target)
        
        extended_targets_template = xr.concat(extended_targets, dim='time')
        
        extended_forcings = self._create_extended_forcings(
            data['forcings'], NUM_FORECAST_STEPS
        )
        
        logger.info(f"Running {NUM_FORECAST_STEPS} forecast steps...")
        
        predictions = rollout.chunked_prediction(
            self.run_forward_jitted,
            rng=jax.random.PRNGKey(0),
            inputs=data['inputs'],
            targets_template=extended_targets_template,
            forcings=extended_forcings
        )
        
        logger.info("GraphCast forecast completed successfully")
        return predictions
    
    def _create_extended_forcings(self, forcings: xr.Dataset, num_steps: int) -> xr.Dataset:
        """Create extended forcings for the full forecast period"""
        if len(forcings.data_vars) == 0:
            return forcings
        
        extended_forcings = []
        
        for step in range(num_steps):
            step_forcing = forcings.isel(time=-1).copy()  # Use last available forcing
            new_time = forcings.time.values[-1] + np.timedelta64(step * FORECAST_INTERVAL, 'h')
            step_forcing = step_forcing.assign_coords(time=new_time).expand_dims('time')
            extended_forcings.append(step_forcing)
        
        return xr.concat(extended_forcings, dim='time')


def find_zarr_files() -> List[Path]:
    """Find all zarr files in the input directory"""
    zarr_files = []
    
    if not ZARR_INPUT_DIR.exists():
        logger.warning(f"Input directory does not exist: {ZARR_INPUT_DIR}")
        return zarr_files
    
    for item in ZARR_INPUT_DIR.iterdir():
        if item.is_dir() and item.suffix == '.zarr':
            zarr_files.append(item)
    
    logger.info(f"Found {len(zarr_files)} zarr files: {[f.name for f in zarr_files]}")
    return sorted(zarr_files)


def extract_datetime_from_zarr_name(zarr_path: Path) -> Optional[datetime.datetime]:
    """Extract datetime from zarr filename"""
    name = zarr_path.stem  # Remove .zarr extension
    
    try:
        parts = name.split('_')
        if len(parts) >= 2:
            date_str = parts[0]  # YYYYMMDD
            hour_str = parts[1]  # HH
            
            year = int(date_str[:4])
            month = int(date_str[4:6])
            day = int(date_str[6:8])
            hour = int(hour_str)
            
            return datetime.datetime(year, month, day, hour)
    except (ValueError, IndexError) as e:
        logger.warning(f"Could not parse datetime from {zarr_path.name}: {e}")
    
    return None


def merge_forecasts(forecast_results: List[Dict]) -> xr.Dataset:
    """Merge all forecast results into a single comprehensive dataset"""
    logger.info("Merging all forecast results...")
    
    if not forecast_results:
        raise ValueError("No forecast results to merge")
    
    forecast_results.sort(key=lambda x: x['initial_time'])
    
    all_predictions = []
    
    for result in forecast_results:
        predictions = result['predictions']
        initial_time = result['initial_time']
        
        predictions = predictions.assign_attrs(initial_forecast_time=initial_time.isoformat())
        all_predictions.append(predictions)
    
    merged = xr.concat(all_predictions, dim='forecast_run')
    
    forecast_times = [result['initial_time'] for result in forecast_results]
    merged = merged.assign_coords(forecast_run=forecast_times)
    
    logger.info(f"Merged {len(forecast_results)} forecast runs")
    return merged


def generate_output_filename(forecast_results: List[Dict]) -> str:
    """Generate output filename based on forecast data"""
    if not forecast_results:
        now = datetime.datetime.now()
        return f"graphcast_forecast_{now.strftime('%Y_%m_%d_%H')}.zarr"
    
    earliest_time = min(result['initial_time'] for result in forecast_results)
    return f"graphcast_forecast_{earliest_time.strftime('%Y_%m_%d_%H')}.zarr"


def main():
    """Main forecasting workflow"""
    logger.info("Starting GraphCast forecasting workflow")
    
    forecaster = GraphCastForecaster()
    
    if not forecaster.check_dependencies():
        logger.error("GraphCast dependencies not available. Please install them first.")
        sys.exit(1)
    
    if not forecaster.load_model():
        logger.error("Failed to load GraphCast model")
        sys.exit(1)
    
    zarr_files = find_zarr_files()
    
    if not zarr_files:
        logger.error("No zarr files found in input directory")
        logger.error(f"Please ensure zarr files are available in: {ZARR_INPUT_DIR}")
        sys.exit(1)
    
    forecast_results = []
    
    for zarr_path in zarr_files:
        try:
            logger.info(f"Processing zarr file: {zarr_path.name}")
            
            initial_time = extract_datetime_from_zarr_name(zarr_path)
            if initial_time is None:
                logger.warning(f"Skipping {zarr_path.name} - could not extract datetime")
                continue
            
            predictions = forecaster.run_forecast(zarr_path)
            
            forecast_results.append({
                'zarr_path': zarr_path,
                'initial_time': initial_time,
                'predictions': predictions
            })
            
            logger.info(f"Completed forecast for {zarr_path.name}")
            
        except Exception as e:
            logger.error(f"Failed to process {zarr_path.name}: {e}")
            continue
    
    if not forecast_results:
        logger.error("No forecasts were successfully generated")
        sys.exit(1)
    
    try:
        merged_forecast = merge_forecasts(forecast_results)
        
        output_filename = generate_output_filename(forecast_results)
        output_path = GRAPHCAST_OUTPUT_DIR / output_filename
        
        logger.info(f"Saving merged forecast to: {output_path}")
        merged_forecast.to_zarr(output_path, mode='w')
        
        logger.info("GraphCast forecasting workflow completed successfully!")
        logger.info(f"Output file: {output_path}")
        logger.info(f"Forecast covers {len(forecast_results)} initial times")
        logger.info(f"Each forecast extends {FORECAST_HOURS} hours ({NUM_FORECAST_STEPS} steps)")
        
    except Exception as e:
        logger.error(f"Failed to merge and save forecasts: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
