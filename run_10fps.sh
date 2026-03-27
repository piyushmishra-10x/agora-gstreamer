#!/bin/bash
# Run agorasink pipeline at 10fps (Holoscan-compatible)
# Usage: ./run_10fps.sh [logname] [channel] [device]
#   logname  — name for the log file (default: auto-timestamped)
#   channel  — Agora channel name (default: gmsl_cam0)
#   device   — video device (default: /dev/video0)

export GST_PLUGIN_PATH=/usr/local/lib/aarch64-linux-gnu/gstreamer-1.0

LOGNAME="${1:-}"
CHANNEL="${2:-gmsl_cam0}"
DEVICE="${3:-/dev/video0}"
APP_ID="89bfa55ce22e4cd8af5451c23a45769d"

LOG_DIR="/tmp/latency_logs"
mkdir -p "$LOG_DIR"

if [ -n "$LOGNAME" ]; then
    LOGFILE="$LOG_DIR/${LOGNAME}.log"
else
    LOGFILE="$LOG_DIR/run_10fps_$(date +%Y%m%d_%H%M%S).log"
fi

echo "Starting 10fps pipeline: device=$DEVICE channel=$CHANNEL"
echo "Logging to: $LOGFILE"
echo ""

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
        channel="$CHANNEL" \
    2>&1 | tee "$LOGFILE"
