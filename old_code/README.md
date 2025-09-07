# Weather Data Processing Pipeline

An automated pipeline for downloading, processing, and analyzing NOAA GFS weather data. This system continuously monitors for new weather forecasts, processes them through multiple stages, and prepares them for analysis.

## 🌟 Overview

This pipeline automates the entire workflow of weather data processing:

1. **Data Collection**: Downloads latest GFS weather data from NOAA servers
2. **File Monitoring**: Watches for new files and triggers processing
3. **Data Extraction**: Extracts specific meteorological variables and pressure levels
4. **File Merging**: Combines different data types (pressure, surface, flux) into unified GRIB datasets
5. **Timestamp Matching**: Identifies and processes time-series pairs from GRIB files for temporal analysis
6. **Format Conversion**: Converts paired GRIB files directly to Zarr format for analysis

## 📁 File Structure

```
weather_modelling/
├── 00_pipeline.sh           # Master orchestration script
├── 01_collect_data.sh       # Downloads weather data from NOAA
├── 02_watch_data_dir.sh     # Monitors ./data for new files
├── 03_watch_extract_dir.sh  # Monitors ./extraction_data and merges GRIB files
├── 04_merge_timestamps.sh   # Finds GRIB timestamp pairs and converts to Zarr
├── 05_grib_zarr.py         # Legacy GRIB to Zarr converter (deprecated)
├── 05_zarr.py              # New GRIB to Zarr converter with cfgrib
├── 02_extract_pressure.sh   # Extracts pressure level variables
├── 02_extract_pressure_b.sh # Extracts additional pressure levels
├── 02_extract_surface.sh    # Extracts surface-level variables
├── data/                    # Raw downloaded weather data
├── extraction_data/         # Extracted/filtered GRIB files
├── merged_data/             # Merged GRIB files
├── timestamp_merged/        # Time-series matched GRIB files (deprecated)
├── output.zarr/             # Final Zarr format files for analysis
├── logs/                    # Pipeline and script logs
├── old_code/                # Archived/deprecated scripts
├── pyproject.toml           # Python project dependencies (uv package manager)
├── uv.lock                  # Locked Python dependencies
├── main.py                  # Python entry point
└── .pids/                   # Process ID tracking
```

## 🔧 Script Descriptions

### Core Pipeline Scripts

#### `00_pipeline.sh` - Master Controller
- **Purpose**: Orchestrates the entire pipeline
- **Functions**:
  - Runs `01_collect_data.sh` every 30 minutes
  - Starts and monitors all watcher scripts
  - Manages process lifecycle and logging
  - Handles graceful shutdown and restart
- **Usage**: `./00_pipeline.sh {start|stop|restart|status|collect}`

#### `01_collect_data.sh` - Data Downloader
- **Purpose**: Downloads GFS weather data from NOAA servers
- **Functions**:
  - Finds latest available weather cycles
  - Downloads current and previous 6/12-hour forecasts
  - Fetches pgrb2, pgrb2b, and sfluxgrb files for forecast hours 000-006
  - Skips already downloaded files
- **Data Source**: `https://nomads.ncep.noaa.gov/pub/data/nccf/com/gfs/prod`

### Watcher Scripts

#### `02_watch_data_dir.sh` - Raw Data Monitor
- **Purpose**: Monitors `./data` directory for new downloads
- **Functions**:
  - Detects new GRIB files using inotify
  - Parses filename patterns to extract metadata
  - Triggers appropriate extraction scripts based on file type
- **File Pattern**: `YYYYMMDD_HH/gfs.tHHz.{pgrb2|pgrb2b|sfluxgrb}*.fFFF.grib2`

#### `03_watch_extract_dir.sh` - GRIB File Merger
- **Purpose**: Monitors `./extraction_data` and merges complete GRIB file sets
- **Functions**:
  - Waits for complete sets (pgrb2 + pgrb2b + sfluxgrb) with matching date/hour/forecast
  - Merges files using `wgrib2 -cat` command
  - Outputs merged files to `./merged_data/`
  - Prevents duplicate processing
- **Output Pattern**: `YYYYMMDD_HH_fFFF_merged.grib2`

#### `04_merge_timestamps.sh` - Temporal Analyzer & Zarr Converter
- **Purpose**: Identifies GRIB files from different runs and converts to Zarr
- **Functions**:
  - Finds merged GRIB files exactly 6 hours apart
  - Matches files with same forecast time (e.g., `20250708_18_f000` + `20250708_12_f000`)
  - Copies matching pairs to `./timestamp_merged/`
  - Automatically converts pairs to Zarr format using `05_zarr.py`
  - Outputs final analysis-ready files to `./output.zarr/`
- **Input Pattern**: `YYYYMMDD_HH_fFFF_merged.grib2`
- **Output Pattern**: `YYYYMMDD_fFFF_HH1_HH2.zarr`

#### `05_zarr.py` - GRIB to Zarr Converter
- **Purpose**: Converts paired GRIB files directly to Zarr format using modern cfgrib backend
- **Functions**:
  - Opens GRIB files using `cfgrib` engine with multi-index support
  - Automatically parses cycle times from filenames
  - Aligns timestamps for temporal analysis (enforces 6-hour offset)
  - Concatenates datasets along time dimension
  - Saves to Zarr format for efficient analysis with coordinate preservation
- **Usage**: `python 05_zarr.py <file1.grib2> <file2.grib2> <output.zarr>`
- **Features**: 
  - Handles coordinate collisions with multi-index
  - Preserves typeOfLevel and level dimensions
  - Automatic time sorting and validation

### Extraction Scripts

#### `02_extract_pressure.sh` - Pressure Level Extractor
- **Purpose**: Extracts atmospheric pressure level data
- **Variables**: TMP, UGRD, VGRD, HGT, SPFH, VVEL
- **Levels**: 1000-1 mb (29 pressure levels)
- **Input**: Raw pgrb2 GRIB files
- **Tool**: `wgrib2 -match`

#### `02_extract_pressure_b.sh` - Additional Pressure Levels
- **Purpose**: Extracts supplementary pressure levels
- **Variables**: TMP, UGRD, VGRD, HGT, VVEL
- **Levels**: 875, 825, 775, 225, 175, 125 mb
- **Input**: Raw pgrb2b GRIB files

#### `02_extract_surface.sh` - Surface Variable Extractor
- **Purpose**: Extracts surface-level meteorological data
- **Variables**: 
  - TMP:2 m above ground (temperature)
  - UGRD:10 m above ground (u-wind component)
  - VGRD:10 m above ground (v-wind component)
- **Input**: Raw sfluxgrb GRIB files

## 🚀 Quick Start

### Prerequisites

Install required system packages:
```bash
# Ubuntu/Debian
sudo apt update
sudo apt install inotify-tools wget curl

# Install wgrib2 (GRIB processing)
sudo apt install wgrib2
```

### Python Environment Setup

This project uses `uv` for fast Python package management:

```bash
# Install uv (if not already installed)
curl -LsSf https://astral.sh/uv/install.sh | sh

# Install dependencies from pyproject.toml
uv sync

# Activate virtual environment
source .venv/bin/activate
```

**Dependencies (managed via pyproject.toml)**:
- `cfgrib>=0.9.15.0` - GRIB file reading
- `xarray>=2025.7.1` - Multi-dimensional arrays
- `numpy>=2.3.1` - Numerical computing
- `pandas>=2.3.1` - Data manipulation
- `zarr>=3.1.0` - Chunked array storage

### Running the Pipeline

1. **Start the complete pipeline**:
   ```bash
   ./00_pipeline.sh start
   ```

2. **Check status**:
   ```bash
   ./00_pipeline.sh status
   ```

3. **Stop the pipeline**:
   ```bash
   ./00_pipeline.sh stop
   ```

4. **Manual data collection**:
   ```bash
   ./00_pipeline.sh collect
   ```

## 📊 Data Flow

```
NOAA GFS Data → 01_collect_data.sh → ./data/
                                      ↓
                              02_watch_data_dir.sh
                                      ↓
                              02_extract_*.sh → ./extraction_data/
                                                       ↓
                                               03_watch_extract_dir.sh
                                                       ↓ (merges pgrb2+pgrb2b+sfluxgrb)
                                               ./merged_data/ (GRIB)
                                                       ↓
                                               04_merge_timestamps.sh
                                                       ↓ (finds 6hr pairs)
                                               ./timestamp_merged/ (GRIB pairs)
                                                       ↓ (auto-converts)
                                               05_zarr.py → ./output.zarr/ (analysis-ready)
```

## 🔍 Monitoring and Logs

- **Pipeline logs**: `./logs/pipeline.log`
- **Script logs**: `./logs/{script_name}.log`
- **Process tracking**: `./.pids/{script_name}.pid`
- **Real-time monitoring**: `tail -f ./logs/pipeline.log`

## 🛠️ Maintenance and Troubleshooting

### Ensuring Reliability

1. **System Service Setup** (Recommended):
   ```bash
   # Create systemd service
   sudo tee /etc/systemd/system/weather-pipeline.service > /dev/null <<EOF
   [Unit]
   Description=Weather Data Processing Pipeline
   After=network.target

   [Service]
   Type=simple
   User=$USER
   WorkingDirectory=$(pwd)
   ExecStart=$(pwd)/00_pipeline.sh start
   Restart=always
   RestartSec=10

   [Install]
   WantedBy=multi-user.target
   EOF

   sudo systemctl daemon-reload
   sudo systemctl enable weather-pipeline.service
   sudo systemctl start weather-pipeline.service
   ```

2. **Cron Backup** (Alternative):
   ```bash
   # Add to crontab for auto-restart
   crontab -e
   # Add line:
   @reboot cd /path/to/weather_modelling && ./00_pipeline.sh start
   ```

### Health Checks

- **Check watcher status**: `./00_pipeline.sh status`
- **Verify data downloads**: `ls -la ./data/`
- **Check processing**: `ls -la ./merged_data/ ./timestamp_merged/ ./output.zarr/`
- **Monitor logs**: `tail -f ./logs/pipeline.log`

### Common Issues

1. **Missing dependencies**:
   ```bash
   # Check installations
   which wgrib2 inotifywait python
   uv run python -c "import xarray, cfgrib, zarr, pandas; print('✅ All Python deps available')"
   ```

2. **Permission errors**:
   ```bash
   # Fix script permissions
   chmod +x *.sh
   ```

3. **Disk space**:
   ```bash
   # Monitor disk usage
   df -h
   # Clean old data if needed
   find ./data -name "*.grib2" -mtime +7 -delete
   ```

4. **Process cleanup**:
   ```bash
   # Kill hung processes
   ./00_pipeline.sh stop
   killall inotifywait
   ```

### Performance Optimization

- **Disk I/O**: Use SSD storage for `./data` and `./merged_data`
- **CPU**: wgrib2 and cdo can be CPU-intensive during processing
- **Memory**: Monitor memory usage during large file processing
- **Network**: Ensure stable internet connection for NOAA downloads

## 📈 Next Steps

1. **Production Deployment**:
   - Set up systemd service for automatic startup
   - Configure log rotation
   - Implement disk space monitoring
   - Add email alerts for failures

2. **Data Analysis**:
   - Use processed Zarr files in `./output.zarr/` for weather analysis
   - Leverage multi-dimensional xarray datasets with preserved coordinates
   - Implement time-series analysis on 6-hour forecast pairs
   - Create visualization dashboards with xarray and matplotlib
   - Take advantage of Zarr's chunked storage for efficient large-dataset processing

3. **Scaling**:
   - Add more forecast hours (currently f000-f006)
   - Include additional meteorological variables
   - Implement parallel processing for large datasets

4. **Monitoring**:
   - Set up Prometheus/Grafana for metrics
   - Add health check endpoints
   - Implement automated backup strategies

## 🤝 Contributing

When modifying scripts:
1. Test changes in isolation first
2. Update this README for any workflow changes
3. Ensure proper error handling and logging
4. Maintain compatibility with existing file patterns

## 📜 License

This project processes public weather data from NOAA. Ensure compliance with NOAA data usage policies.