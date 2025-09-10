'''
Description
@uthor: Sadegh Sadeghi Tabas (sadegh.tabas@noaa.gov)
Revision history:
    -20231010: Sadegh Tabas, initial code
    -20231204: Sadegh Tabas, calculating toa incident solar radiation, parallelizing, updating units, and resolving memory issues
    -20240112: Sadegh Tabas, (i)removing Pysolar as tisr would be calc through GC, (ii) add NOMADS option for downloading data, (iii) add 37 pressure levels, (iv) configurations for hera
    -20240124: Linlin Cui, added pygrib method to extract variables from grib2 files
    -20240205: Sadegh Tabas, add 37 pressure levels, update s3 bucket
    -20240214: Linlin Cui, update pygrib method to account for 37 pressure levels
    -20240221: Sadegh Tabas, (i) updated acc precip variable IC, (ii) initialize s3 credentials for cloud machines, (iii) updated wgrib2 process, pygrib process, s3 and nomads functions
    -20240425: Sadegh Tabas, (i) update s3 bucket resource, 
    -20250910: Devin AI, fix hour mismatch by removing 6-hour offset for f006 files
'''
import os
import sys
from time import time
import glob
import argparse
import subprocess
from datetime import datetime, timedelta
import re
import boto3
import xarray as xr
import numpy as np
from botocore.config import Config
from botocore import UNSIGNED
import pygrib
import requests
from bs4 import BeautifulSoup


class GFSDataProcessor:
    def __init__(self, start_datetime, end_datetime, num_pressure_levels=13, download_source='nomads', output_directory=None, download_directory=None, download_pairs=True, keep_downloaded_data=True, aws=None):
        self.start_datetime = start_datetime
        self.end_datetime = end_datetime
        self.num_levels = num_pressure_levels
        self.download_source = download_source
        self.output_directory = output_directory
        self.download_directory = download_directory
        self.download_pairs = download_pairs
        self.keep_downloaded_data = keep_downloaded_data

        if self.download_source == 's3':
            self.s3 = boto3.client('s3', config=Config(signature_version=UNSIGNED))
    
        # Specify the S3 bucket name and root directory
        self.bucket_name = 'noaa-gfs-bdp-pds'
        
        self.root_directory = 'gdas'

        # Specify the local directory where you want to save the files
        if self.download_directory is None:
            self.local_base_directory = os.path.join(os.getcwd(), self.bucket_name+'_'+str(self.num_levels))  # Use current directory if not specified
        else:
            self.local_base_directory = os.path.join(self.download_directory, self.bucket_name+'_'+str(self.num_levels))

        # List of file formats to download
        self.forecast_hours = [f"f{h:03d}" for h in range(0, 12)]
        self.file_formats = [f"pgrb2.0p25.{fh}" for fh in self.forecast_hours]
        if self.num_levels == 37:
            self.file_formats += [f"pgrb2b.0p25.{fh}" for fh in self.forecast_hours]

    def s3bucket(self, date_str, time_str, local_directory):
        # Construct the S3 prefix for the directory
        s3_prefix = f"{self.root_directory}.{date_str}/{time_str}/"

        
        def get_data(s3_prefix, file_format, local_directory):
            # List objects in the S3 directory
            s3_objects = self.s3.list_objects_v2(Bucket=self.bucket_name, Prefix=s3_prefix)
            for obj in s3_objects.get('Contents', []):
                obj_key = obj['Key']
                if obj_key.endswith(f'.{file_format}'):
                    # Define the local file path
                    local_file_path = os.path.join(local_directory, os.path.basename(obj_key))

                    # Download the file from S3 to the local path
                    self.s3.download_file(self.bucket_name, obj_key, local_file_path)
                    print(f"Downloaded {obj_key} to {local_file_path}")

                 
        for file_format in self.file_formats:
            get_data(s3_prefix, file_format, local_directory)

        
    
    def nomads(self, date_str, time_str, local_directory):

        
        def get_data(date_str, time_str, file_format, local_directory):
            # Construct the URL for the data directory
            gdas_url = f"https://nomads.ncep.noaa.gov/pub/data/nccf/com/gfs/prod/{self.root_directory}.{date_str}/{time_str}/atmos/"
            
            # Get the list of files from the URL
            response = requests.get(gdas_url)
            if response.status_code == 200:
                # Parse the HTML content using BeautifulSoup
                soup = BeautifulSoup(response.content, 'html.parser')
                
                # Find all anchor tags (links) in the HTML
                anchor_tags = soup.find_all('a')
                
                # Extract file URLs from href attributes of anchor tags
                file_urls = [gdas_url + tag['href'] for tag in anchor_tags if tag.get('href')]
    
                for file_url in file_urls: 
                    
                    if file_url.endswith(f'.{file_format}'):
                        
                        # Define the local file path
                        local_file_path = os.path.join(local_directory, os.path.basename(file_url))
                        
                        # Download the file from S3 to the local path
                        try:
                            # Run the wget command
                            subprocess.run(['wget', file_url, '-O', local_file_path], check=True)
                            print(f"Download completed: {file_url} => {local_file_path}")
                        except subprocess.CalledProcessError as e:
                            print(f"Error downloading {file_url}: {e}")

        for file_format in self.file_formats:
            get_data(date_str, time_str, file_format, local_directory)


    
        
    def download_data(self):
        # Calculate the number of 6-hour intervals
        delta = (self.end_datetime - self.start_datetime)
        total_intervals = int(delta.total_seconds() / 3600 / 6)  # 6 hours per interval

        # Loop through the 6-hour intervals
        current_datetime = self.start_datetime
        while current_datetime <= self.end_datetime:
            date_str = current_datetime.strftime("%Y%m%d")
            time_str = current_datetime.strftime("%H")
            
            # Define the local directory path where the file will be saved
            local_directory = os.path.join(self.local_base_directory, date_str, time_str)

            # Create the local directory if it doesn't exist
            os.makedirs(local_directory, exist_ok=True)
            
            if self.download_source == 's3':
                self.s3bucket(date_str, time_str, local_directory)
            else:
                self.nomads(date_str, time_str, local_directory)
                
            

            # Move to the next 6-hour interval
            current_datetime += timedelta(hours=6)

        print("Download completed.")

    def process_data_with_wgrib2(self, forecast_hours=None):
        # Define the directory where your GRIB2 files are located
        data_directory = self.local_base_directory

        # Default to original behavior if no forecast hours specified
        if forecast_hours is None:
            forecast_hours = ['f000', 'f006']

        # Create a dictionary to specify the variables, levels, and whether to extract only the first time step (if needed)
        variables_to_extract = {}
        
        for fh in forecast_hours:
            if fh in ['f000', 'f001', 'f002', 'f003', 'f004', 'f005']:
                variables_to_extract[f'.pgrb2.0p25.{fh}'] = {
                    ':HGT:': {
                        'levels': [':surface:'],
                        'first_time_step_only': True,
                    },
                    ':TMP:': {
                        'levels': [':2 m above ground:'],
                    },
                    ':PRMSL:': {
                        'levels': [':mean sea level:'],
                    },
                    ':VGRD|UGRD:': {
                        'levels': [':10 m above ground:'],
                    },
                    ':SPFH|VVEL|VGRD|UGRD|HGT|TMP:': {
                        'levels': [':(50|100|150|200|250|300|400|500|600|700|850|925|1000) mb:'],
                    },
                }
            elif fh in ['f006', 'f007', 'f008', 'f009', 'f010', 'f011']:
                variables_to_extract[f'.pgrb2.0p25.{fh}'] = {
                    ':LAND:': {
                        'levels': [':surface:'],
                        'first_time_step_only': True,
                    },
                    '^(597):': {  # APCP
                        'levels': [':surface:'],
                    },
                }

        if self.num_levels == 37:
            for fh in forecast_hours:
                if fh in ['f000', 'f001', 'f002', 'f003', 'f004', 'f005']:
                    variables_to_extract[f'.pgrb2.0p25.{fh}'][':SPFH|VVEL|VGRD|UGRD|HGT|TMP:']['levels'] = [':(1|2|3|5|7|10|20|30|50|70|100|150|200|250|300|350|400|450|500|550|600|650|700|750|800|850|900|925|950|975|1000) mb:']
                    variables_to_extract[f'.pgrb2b.0p25.{fh}'] = {}
                    variables_to_extract[f'.pgrb2b.0p25.{fh}'][':SPFH|VVEL|VGRD|UGRD|HGT|TMP:'] = {}
                    variables_to_extract[f'.pgrb2b.0p25.{fh}'][':SPFH|VVEL|VGRD|UGRD|HGT|TMP:']['levels'] = [':(125|175|225|775|825|875) mb:']
       
        # Create an empty list to store the extracted datasets
        extracted_datasets = []
        files = []
        print("Start extracting variables and associated levels from grib2 files:")
        # Loop through each folder (e.g., gdas.yyyymmdd)
        date_folders = sorted(next(os.walk(data_directory))[1])
        for date_folder in date_folders:
            date_folder_path = os.path.join(data_directory, date_folder)

            # Loop through each hour (e.g., '00', '06', '12', '18')
            for hour in ['00', '06', '12', '18']:
                subfolder_path = os.path.join(date_folder_path, hour)

                # Check if the subfolder exists before processing
                if os.path.exists(subfolder_path):
                    # Loop through each GRIB2 file (.f000, .f001, .f006)
                    for file_extension, variable_data in variables_to_extract.items():
                        for variable, data in variable_data.items():
                            levels = data['levels']
                            first_time_step_only = data.get('first_time_step_only', False)  # Default to False if not specified

                            pattern = os.path.join(subfolder_path, f'gdas.t*z{file_extension}')
                            # Use glob to search for files matching the pattern
                            matching_files = glob.glob(pattern)
                            
                            # Check if there's exactly one matching file
                            if len(matching_files) == 1:
                                grib2_file = matching_files[0]
                                print("Found file:", grib2_file)
                            else:
                                print("Error: Found multiple or no matching files.")
                                
                            # Extract the specified variables with levels from the GRIB2 file
                            for level in levels:
                                output_file = f'{variable}_{level}_{date_folder}_{hour}{file_extension}_{self.num_levels}.nc'
                                files.append(output_file)
                                
                                # Extracting levels using regular expression
                                matches = re.findall(r'\d+', level)
                                
                                # Convert the extracted matches to integers
                                curr_levels = [int(match) for match in matches]
                                
                                # Get the number of levels
                                number_of_levels = len(curr_levels)
                                
                                # Use wgrib2 to extract the variable with level
                                wgrib2_command = ['wgrib2', '-nc_nlev', f'{number_of_levels}', grib2_file, '-match', f'{variable}', '-match', f'{level}', '-netcdf', output_file]
                                subprocess.run(wgrib2_command, check=True)

                                # Open the extracted netcdf file as an xarray dataset
                                ds = xr.open_dataset(output_file)

                                # if variable == '^(597):':
                                #    ds['time'] = ds['time'] - np.timedelta64(6, 'h')

                                # If specified, extract only the first time step
                                if variable not in [':LAND:', ':HGT:']:
                                    extracted_datasets.append(ds)
                                else:
                                    if first_time_step_only:
                                        # Append the dataset to the list
                                        ds = ds.isel(time=0)
                                        extracted_datasets.append(ds)
                                        variables_to_extract[file_extension][variable]['first_time_step_only'] = False
                                
                                # Optionally, remove the intermediate GRIB2 file
                                # os.remove(output_file)
        print("Merging grib2 files:")
        # ds = xr.merge(extracted_datasets) [OLD FORMAT - FAILS WITH NEWER XARRAY]
        ds = xr.combine_by_coords(
            extracted_datasets,
            combine_attrs="drop_conflicts",
            join="outer"
        )
        
        print("Merging process completed.")
        
        print("Processing, Renaming and Reshaping the data")
        # Drop the 'level' dimension
        ds = ds.drop_dims('level')

        # Rename variables and dimensions
        ds = ds.rename({
            'latitude': 'lat',
            'longitude': 'lon',
            'plevel': 'level',
            'HGT_surface': 'geopotential_at_surface',
            'LAND_surface': 'land_sea_mask',
            'PRMSL_meansealevel': 'mean_sea_level_pressure',
            'TMP_2maboveground': '2m_temperature',
            'UGRD_10maboveground': '10m_u_component_of_wind',
            'VGRD_10maboveground': '10m_v_component_of_wind',
            'APCP_surface': 'total_precipitation_6hr',
            'HGT': 'geopotential',
            'TMP': 'temperature',
            'SPFH': 'specific_humidity',
            'VVEL': 'vertical_velocity',
            'UGRD': 'u_component_of_wind',
            'VGRD': 'v_component_of_wind'
        })

        # Assign 'datetime' as coordinates
        ds = ds.assign_coords(datetime=ds.time)
        
        # Convert data types
        ds['lat'] = ds['lat'].astype('float32')
        ds['lon'] = ds['lon'].astype('float32')
        ds['level'] = ds['level'].astype('int32')

        # Adjust time values relative to the first time step
        ds['time'] = ds['time'] - ds.time[0]

        # Expand dimensions
        ds = ds.expand_dims(dim='batch')
        ds['datetime'] = ds['datetime'].expand_dims(dim='batch')

        # Squeeze dimensions
        ds['geopotential_at_surface'] = ds['geopotential_at_surface'].squeeze('batch')
        ds['land_sea_mask'] = ds['land_sea_mask'].squeeze('batch')

        # Update geopotential unit to m2/s2 by multiplying 9.80665
        ds['geopotential_at_surface'] = ds['geopotential_at_surface'] * 9.80665
        ds['geopotential'] = ds['geopotential'] * 9.80665

        # Update total_precipitation_6hr unit to (m) from (kg/m^2) by dividing it by 1000kg/m³
        ds['total_precipitation_6hr'] = ds['total_precipitation_6hr'] / 1000
        
        # Define the output NetCDF file
        date = (self.start_datetime + timedelta(hours=6)).strftime('%Y%m%d%H')
        steps = str(len(ds['time']))
        
        if forecast_hours is None:
            fh_suffix = ""
        else:
            fh_suffix = f"_fh-{'_'.join(forecast_hours)}"

        if self.output_directory is None:
            self.output_directory = os.getcwd()  # Use current directory if not specified
        os.makedirs(self.output_directory, exist_ok=True)
        output_netcdf = os.path.join(self.output_directory, f"source-gdas_date-{date}_res-0.25_levels-{self.num_levels}_steps-{steps}{fh_suffix}.nc")

        # Save the merged dataset as a NetCDF file
        ds.to_netcdf(output_netcdf)
        print(f"Saved output to {output_netcdf}")
        for file in files:
            os.remove(file)
            
        # Optionally, remove downloaded data
        if not self.keep_downloaded_data:
            self.remove_downloaded_data()

        print(f"Process completed successfully, your inputs for GraphCast model generated at:\n {output_netcdf}")
        return output_netcdf

    def process_forecast_pairs_with_wgrib2(self):
        """
        Process forecast pairs using the refactored process_data_with_wgrib2 function.
        Creates six 2-step files per cycle: (f000,f006), (f001,f007), (f002,f008), 
        (f003,f009), (f004,f010), (f005,f011)
        """
        forecast_hours = [f"f{h:03d}" for h in range(0, 12)]
        
        for i in range(6):
            pair_hours = [forecast_hours[i], forecast_hours[i+6]]
            print(f"Processing forecast pair: {pair_hours}")
            self.process_data_with_wgrib2(forecast_hours=pair_hours)

    def process_data_with_pygrib(self):
        # Define the directory where your GRIB2 files are located
        data_directory = self.local_base_directory

        # Create a dictionary to specify the variables and levels to extract
        variables_to_extract = {
            '.pgrb2.0p25.f000': {
                'gh': {  # geopotential height
                    'typeOfLevel': 'surface',
                    'level': 0,
                },
                't2m': {  # 2 metre temperature
                    'typeOfLevel': 'heightAboveGround',
                    'level': 2,
                },
                'msl': {  # mean sea level pressure
                    'typeOfLevel': 'meanSea',
                    'level': 0,
                },
                'u10': {  # 10 metre U wind component
                    'typeOfLevel': 'heightAboveGround',
                    'level': 10,
                },
                'v10': {  # 10 metre V wind component
                    'typeOfLevel': 'heightAboveGround',
                    'level': 10,
                },
                'z': {  # geopotential
                    'typeOfLevel': 'isobaricInhPa',
                    'level': [50, 100, 150, 200, 250, 300, 400, 500, 600, 700, 850, 925, 1000],
                },
                't': {  # temperature
                    'typeOfLevel': 'isobaricInhPa',
                    'level': [50, 100, 150, 200, 250, 300, 400, 500, 600, 700, 850, 925, 1000],
                },
                'q': {  # specific humidity
                    'typeOfLevel': 'isobaricInhPa',
                    'level': [50, 100, 150, 200, 250, 300, 400, 500, 600, 700, 850, 925, 1000],
                },
                'w': {  # vertical velocity
                    'typeOfLevel': 'isobaricInhPa',
                    'level': [50, 100, 150, 200, 250, 300, 400, 500, 600, 700, 850, 925, 1000],
                },
                'u': {  # U component of wind
                    'typeOfLevel': 'isobaricInhPa',
                    'level': [50, 100, 150, 200, 250, 300, 400, 500, 600, 700, 850, 925, 1000],
                },
                'v': {  # V component of wind
                    'typeOfLevel': 'isobaricInhPa',
                    'level': [50, 100, 150, 200, 250, 300, 400, 500, 600, 700, 850, 925, 1000],
                },
            },
            '.pgrb2.0p25.f006': {
                'tp': {  # total precipitation 
                    'typeOfLevel': 'surface',
                    'level': 0,
                },
                'lsm': {  # land sea mask
                    'typeOfLevel': 'surface',
                    'level': 0,
                },
            }
        }

        if self.num_levels == 37:
            for file_extension in ['.pgrb2.0p25.f000']:
                for var_name in ['z', 't', 'q', 'w', 'u', 'v']:
                    variables_to_extract[file_extension][var_name]['level'] = [1, 2, 3, 5, 7, 10, 20, 30, 50, 70, 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500, 550, 600, 650, 700, 750, 775, 800, 825, 850, 875, 900, 925, 950, 975, 1000]
            
            variables_to_extract['.pgrb2b.0p25.f000'] = {}
            for var_name in ['z', 't', 'q', 'w', 'u', 'v']:
                variables_to_extract['.pgrb2b.0p25.f000'][var_name] = {
                    'typeOfLevel': 'isobaricInhPa',
                    'level': [125, 175, 225, 775, 825, 875],
                }

        # Create an empty list to store the extracted datasets
        extracted_datasets = []

        print("Start extracting variables and associated levels from grib2 files:")
        # Loop through each folder (e.g., gdas.yyyymmdd)
        date_folders = sorted(next(os.walk(data_directory))[1])
        for date_folder in date_folders:
            date_folder_path = os.path.join(data_directory, date_folder)

            # Loop through each hour (e.g., '00', '06', '12', '18')
            for hour in ['00', '06', '12', '18']:
                subfolder_path = os.path.join(date_folder_path, hour)

                # Check if the subfolder exists before processing
                if os.path.exists(subfolder_path):
                    # Loop through each GRIB2 file (.f000, .f001, .f006)
                    for file_extension, variable_data in variables_to_extract.items():
                        pattern = os.path.join(subfolder_path, f'gdas.t*z{file_extension}')
                        # Use glob to search for files matching the pattern
                        matching_files = glob.glob(pattern)
                        
                        # Check if there's exactly one matching file
                        if len(matching_files) == 1:
                            grib2_file = matching_files[0]
                            print("Found file:", grib2_file)
                        else:
                            print("Error: Found multiple or no matching files.")
                            continue
                        
                        for var_name, var_info in variable_data.items():
                            type_of_level = var_info['typeOfLevel']
                            levels = var_info['level']
                            
                            if not isinstance(levels, list):
                                levels = [levels]
                            
                            for level in levels:
                                data_array = self.get_dataarray(grib2_file, var_name, type_of_level, level)
                                
                                if data_array is not None:
                                    extracted_datasets.append(data_array)

        print("Merging grib2 files:")
        ds = xr.merge(extracted_datasets)
        
        print("Merging process completed.")
        
        print("Processing, Renaming and Reshaping the data")

        # Update total_precipitation_6hr unit to (m) from (kg/m^2) by dividing it by 1000kg/m³
        ds['total_precipitation_6hr'] = ds['total_precipitation_6hr'] / 1000

        # Define the output NetCDF file
        date = (self.start_datetime + timedelta(hours=6)).strftime('%Y%m%d%H')
        steps = str(len(ds['time']))

        if self.output_directory is None:
            self.output_directory = os.getcwd()  # Use current directory if not specified
        os.makedirs(self.output_directory, exist_ok=True)
        output_netcdf = os.path.join(self.output_directory, f"source-gdas_date-{date}_res-0.25_levels-{self.num_levels}_steps-{steps}.nc")

        # Save the merged dataset as a NetCDF file
        ds.to_netcdf(output_netcdf)
        print(f"Saved output to {output_netcdf}")
            
        # Optionally, remove downloaded data
        if not self.keep_downloaded_data:
            self.remove_downloaded_data()

        print(f"Process completed successfully, your inputs for GraphCast model generated at:\n {output_netcdf}")
        return output_netcdf

    def remove_downloaded_data(self):
        import shutil
        if os.path.exists(self.local_base_directory):
            shutil.rmtree(self.local_base_directory)
            print(f"Removed downloaded data directory: {self.local_base_directory}")

    def get_dataarray(self, grib_file, var_name, type_of_level, level):
        try:
            grbs = pygrib.open(grib_file)
            
            variable_message = grbs.select(shortName=var_name, typeOfLevel=type_of_level, level=level)
            
            if not variable_message:
                print(f"Variable {var_name} with level {level} not found in {grib_file}")
                return None
            
            variable_message = variable_message[0]
            
            data, lats, lons = variable_message.data()
    
            steps = variable_message[0].validDate
            if var_name=='tp':
                steps = steps + timedelta(hours=6)
            #precipitation rate has two stepType ('instant', 'avg'), use 'instant')
            if len(variable_message) > 2:
                data = []
                lats = []
                lons = []
                for msg in variable_message:
                    if msg.stepType == 'instant':
                        data_temp, lats_temp, lons_temp = msg.data()
                        data.append(data_temp)
                        lats.append(lats_temp)
                        lons.append(lons_temp)
                data = np.array(data)
                lats = np.array(lats)
                lons = np.array(lons)
            else:
                data, lats, lons = variable_message.data()
            
            if var_name in ['gh', 't2m', 'msl', 'u10', 'v10', 'tp', 'lsm']:
                if var_name == 'gh':
                    var_name_new = 'geopotential_at_surface'
                    data = data * 9.80665  # Convert to m^2/s^2
                elif var_name == 't2m':
                    var_name_new = '2m_temperature'
                elif var_name == 'msl':
                    var_name_new = 'mean_sea_level_pressure'
                elif var_name == 'u10':
                    var_name_new = '10m_u_component_of_wind'
                elif var_name == 'v10':
                    var_name_new = '10m_v_component_of_wind'
                elif var_name == 'tp':
                    var_name_new = 'total_precipitation_6hr'
                elif var_name == 'lsm':
                    var_name_new = 'land_sea_mask'
                
                da = xr.DataArray(
                    data,
                    dims=['lat', 'lon'],
                    coords={'lat': lats[:, 0], 'lon': lons[0, :], 'time': steps},
                    name=var_name_new
                )
            else:
                if var_name == 'z':
                    var_name_new = 'geopotential'
                    data = data * 9.80665  # Convert to m^2/s^2
                elif var_name == 't':
                    var_name_new = 'temperature'
                elif var_name == 'q':
                    var_name_new = 'specific_humidity'
                elif var_name == 'w':
                    var_name_new = 'vertical_velocity'
                elif var_name == 'u':
                    var_name_new = 'u_component_of_wind'
                elif var_name == 'v':
                    var_name_new = 'v_component_of_wind'
                
                da = xr.DataArray(
                    data,
                    dims=['lat', 'lon'],
                    coords={'lat': lats[:, 0], 'lon': lons[0, :], 'level': level, 'time': steps},
                    name=var_name_new
                )
            
            grbs.close()
            return da

        except Exception as e:
            print(f"Error processing {var_name} at level {level}: {e}")
            return None


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Download and process GFS data")
    parser.add_argument("start_date", help="Start date in YYYYMMDDHH format")
    parser.add_argument("end_date", help="End date in YYYYMMDDHH format")
    parser.add_argument("-l", "--level", help="Number of pressure levels (13 or 37)", type=int, default=13)
    parser.add_argument("-m", "--method", help="Processing method: wgrib2 or pygrib", default="wgrib2")
    parser.add_argument("-s", "--source", help="the source repository to download gdas grib2 data, options: nomads (up-to-date), s3", default="s3")
    parser.add_argument("-o", "--output", help="Output directory for processed data")
    parser.add_argument("-d", "--download", help="Download directory for raw data")
    parser.add_argument("-p", "--pair", help="Write six 2-step files per cycle: (f000,f006)..(f005,f011)", default="true")
    parser.add_argument("-k", "--keep", help="Keep downloaded data (yes or no)", default="no")

    args = parser.parse_args()

    start_datetime = datetime.strptime(args.start_date, "%Y%m%d%H")
    end_datetime = datetime.strptime(args.end_date, "%Y%m%d%H")

    processor = GFSDataProcessor(
        start_datetime=start_datetime,
        end_datetime=end_datetime,
        num_pressure_levels=args.level,
        download_source=args.source,
        output_directory=args.output,
        download_directory=args.download,
        download_pairs=(args.pair.lower() == "true"),
        keep_downloaded_data=(args.keep.lower() == "yes")
    )

    processor.download_data()

    if args.method == "wgrib2":
        if processor.download_pairs:
            processor.process_forecast_pairs_with_wgrib2()
        else:
            processor.process_data_with_wgrib2()
    elif args.method == "pygrib":
        processor.process_data_with_pygrib()
    else:
        print(f"Unknown processing method: {args.method}")
        sys.exit(1)
