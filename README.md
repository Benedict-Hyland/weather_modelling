# Weather Data Processing Pipeline

An automated pipeline for downloading, processing, and analyzing NOAA GFS weather data. This system continuously monitors for new weather forecasts, processes them through multiple stages, and prepares them for analysis.

## 🌟 Overview

This pipeline automates the entire workflow of weather data processing:

1. **Data Collection**: Downloads latest GFS weather data from NOAA servers
2. **File Monitoring**: Watches for new files and triggers processing
3. **Data Extraction**: Extracts specific meteorological variables and pressure levels
4. **File Merging**: Combines different data types (pressure, surface, flux) into unified datasets
5. **Format Conversion**: Converts GRIB2 files to NetCDF format for analysis
6. **Timestamp Matching**: Identifies and processes time-series pairs for temporal analysis

## 📁 File Structure

```
weather_modelling/
├── 00_pipeline.sh           # Master orchestration script
├── 01_collect_data.sh       # Downloads weather data from NOAA
├── 02_watch_data_dir.sh     # Monitors ./data for new files
├── 03_watch_extract_dir.sh  # Monitors ./extraction_data
├── 04_watch_merge_grib.sh   # Merges GRIB files and converts to NetCDF
├── 05_merge_timestamps.sh   # Finds timestamp pairs for analysis
├── 02_extract_pressure.sh   # Extracts pressure level variables
├── 02_extract_pressure_b.sh # Extracts additional pressure levels
├── 02_extract_surface.sh    # Extracts surface-level variables
├── data/                    # Raw downloaded weather data
├── extraction_data/         # Extracted/filtered GRIB files
├── merged_data/             # Merged and converted NetCDF files
├── timestamp_merged/        # Time-series matched files
├── logs/                    # Pipeline and script logs
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

#### `03_watch_extract_dir.sh` - Extraction Monitor
- **Purpose**: Monitors `./extraction_data` for processed files
- **Functions**: Currently watches extraction directory (implementation pending)

#### `04_watch_merge_grib.sh` - File Merger
- **Purpose**: Combines related GRIB files and converts to NetCDF
- **Functions**:
  - Waits for complete sets (pgrb2 + pgrb2b + sfluxgrb)
  - Merges files using `wgrib2 -cat`
  - Converts merged files to NetCDF using `cdo`
  - Outputs to `./merged_data/`
- **Output Pattern**: `YYYYMMDD_HH_fFFF_merged.nc`

#### `05_merge_timestamps.sh` - Temporal Analyzer
- **Purpose**: Identifies files from different runs with same forecast time
- **Functions**:
  - Finds NetCDF files exactly 6 hours apart
  - Matches files with same forecast time (e.g., `20250708_18_f000` + `20250708_12_f000`)
  - Extracts matching pairs to `./timestamp_merged/`
  - Prevents duplicate processing

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

# Install CDO (Climate Data Operators)
sudo apt install cdo
```

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
                                               04_watch_merge_grib.sh
                                                       ↓
                                               ./merged_data/ (NetCDF)
                                                       ↓
                                               05_merge_timestamps.sh
                                                       ↓
                                               ./timestamp_merged/
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
- **Check processing**: `ls -la ./merged_data/`
- **Monitor logs**: `tail -f ./logs/pipeline.log`

### Common Issues

1. **Missing dependencies**:
   ```bash
   # Check installations
   which wgrib2 cdo inotifywait
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
   - Use processed NetCDF files for weather analysis
   - Implement time-series analysis on timestamp pairs
   - Create visualization dashboards

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