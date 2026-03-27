#!/bin/bash
# Run agorasink pipeline at 10fps (Holoscan-compatible)
# Usage: ./run_10fps.sh [channel] [device]
#   channel  — Agora channel name (default: gmsl_cam0)
#   device   — video device (default: /dev/video0)

export GST_PLUGIN_PATH=/usr/local/lib/aarch64-linux-gnu/gstreamer-1.0

CHANNEL="${1:-gmsl_cam0}"
DEVICE="${2:-/dev/video0}"
APP_ID="89bfa55ce22e4cd8af5451c23a45769d"

echo "Starting 10fps pipeline: device=$DEVICE channel=$CHANNEL"

gst-launch-1.0 -e \
    nvv4l2camerasrc device="$DEVICE" ! \
    'video/x-raw(memory:NVMM), format=UYVY, width=1280, height=720, framerate=120/1' ! \
    videorate drop-only=true ! \
    'video/x-raw(memory:NVMM), format=UYVY, width=1280, height=720, framerate=10/1' ! \
    nvvidconv ! \
    'video/x-raw(memory:NVMM), format=NV12' ! \
    nvv4l2h264enc \
        maxperf-enable=1 \
        preset-level=1 \
        control-rate=1 \
        bitrate=1000000 \
        insert-sps-pps=1 \
        iframeinterval=10 \
        num-B-Frames=0 ! \
    h264parse config-interval=-1 ! \
    agorasink \
        appid="$APP_ID" \
        channel="$CHANNEL"
