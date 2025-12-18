#!/bin/bash

set -e

if [[ "$PROFILE" == "ON" ]]; then
  mkdir /presto_profiles

  if [[ -z $PROFILE_ARGS ]]; then
    PROFILE_ARGS="-t nvtx,cuda,osrt 
                  --cuda-memory-usage=true 
                  --cuda-um-cpu-page-faults=true 
                  --cuda-um-gpu-page-faults=true 
                  --cudabacktrace=true"
  fi
  PROFILE_CMD="nsys launch $PROFILE_ARGS"
fi

ldconfig

# CRITICAL FIX: Set LD_LIBRARY_PATH to include:
# - conda/ucxx/lib: cuDF, RMM, UCXX (all 25.12 compatible)
# - gcc-toolset-13: newer libstdc++ with GLIBCXX_3.4.31
# - presto-native-libs: other Presto dependencies
export LD_LIBRARY_PATH="/opt/conda/envs/ucxx/lib:/opt/rh/gcc-toolset-13/root/usr/lib64:/usr/lib64/presto-native-libs:/usr/local/lib:${LD_LIBRARY_PATH}"

$PROFILE_CMD presto_server --etc-dir=/opt/presto-server/etc
