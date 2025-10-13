# =========
# Mamba Builder: create a named env under /opt/conda
# =========
FROM mambaorg/micromamba:1.5.10 AS mamba_builder
ENV MAMBA_ROOT_PREFIX=/opt/conda
SHELL ["/bin/bash", "-lc"]

# Need root for apt
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*

# Create clean environment with Python
RUN micromamba create -y -n graphcast python=3.11 \
 && micromamba clean -a -y

# Fetch the env spec (or COPY your own for reproducible builds)
# RUN curl -fsSL https://raw.githubusercontent.com/Benedict-Hyland/graphcast/main/NCEP/environment.yml \
#     -o /tmp/environment.yml

# Run git clone to get the graphcast repository for the setup.py script
RUN git clone https://github.com/Benedict-Hyland/graphcast.git /tmp/graphcast

# Create a named env (NOT at /opt/conda)
# This lands at /opt/conda/envs/graphcast
WORKDIR /tmp/graphcast
RUN micromamba run -n graphcast python -m pip install --no-cache-dir .
# RUN micromamba create -y -n graphcast -f /tmp/environment.yml \
#  && micromamba clean -a -y

# Sanity testing the GraphCast builder
RUN micromamba run -n graphcast python -c "import graphcast; print('GraphCast installed at:', graphcast.__file__)"

# =========
# WGrib Builder: create a named env under /opt/conda
# =========
FROM debian:bookworm AS wgrib_builder

RUN apt update
RUN apt install -y build-essential cmake gfortran libaec-dev libpng-dev libopenjp2-7-dev libnetcdf-dev wget tar

WORKDIR /src
RUN wget https://github.com/NOAA-EMC/wgrib2/archive/refs/tags/v3.7.0.tar.gz
RUN tar -xvzf v3.7.0.tar.gz

WORKDIR /src/wgrib2-3.7.0

RUN mkdir build
WORKDIR /src/wgrib2-3.7.0/build

RUN cmake -B build -S .. -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/opt/wgrib2 \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  -DCMAKE_INSTALL_RPATH="\$ORIGIN/../lib" \
  -DUSE_AEC=ON -DUSE_PNG=ON -DUSE_OPENJPEG=ON -DUSE_NETCDF=ON

RUN cmake --build build -j"$(nproc)"

RUN cmake --install build

# =========
# Runtime: slim glibc base, copy only the env, add tini
# =========
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    tini ca-certificates git wget curl unzip \
    libaec0 libnetcdf19 libpng16-16 libopenjp2-7 \
    libaec-dev libpng-dev libopenjp2-7-dev libnetcdf-dev \
  && rm -rf /var/lib/apt/lists/* \
  && update-ca-certificates

RUN curl -fsSl "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o awscliv2.zip \
  && unzip awscliv2.zip \
  && ./aws/install

RUN git clone https://github.com/Benedict-Hyland/graphcast.git /graphcast

RUN mkdir -p /app
WORKDIR /app
# COPY ./python-prepare.sh /app/python-prepare.sh
# RUN chmod +x /app/python-prepare.sh

# Copy just the environment directory to keep image small
# (This dereferences hardlinks; everything needed ends up here)
COPY --from=mamba_builder /opt/conda/envs/graphcast /opt/env
COPY --from=wgrib_builder /opt/wgrib2 /opt/wgrib2

# Use this env by default — no activation needed
ENV PATH="/opt/env/bin:/opt/wgrib2/bin:${PATH}"

WORKDIR /app
COPY startup.sh /app/startup.sh
RUN chmod +x /app/startup.sh

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/startup.sh"]

