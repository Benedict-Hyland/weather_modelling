docker run --rm -it \
  -e AWS_REGION=eu-west-2 \
  myimage:latest


docker run -it \
  -v $HOME/.aws:/root/.aws:ro \
  -e AWS_PROFILE=default \
  -e AWS_SDK_LOAD_CONFIG=1 \
  -e AWS_REGION=eu-west-2 \
  downloader:latest


python NCEP/gdas_utility.py 2025090700 2025090706 --level 13 --source nomads -m wgrib2 --output ./outputs -d ./downloads --keep yes