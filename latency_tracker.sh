#!/bin/bash
# Jetson Sender-Side Latency Tracker
# Logs per-element GStreamer latency + system metrics to CSV

DURATION=${1:-300}  # default 5 minutes
LOG_DIR="/tmp/latency_logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
ELEMENT_LOG="$LOG_DIR/sender_elements_${TIMESTAMP}.csv"
SUMMARY_LOG="$LOG_DIR/sender_summary_${TIMESTAMP}.csv"
SYSTEM_LOG="$LOG_DIR/sender_system_${TIMESTAMP}.csv"

export GST_PLUGIN_PATH=/usr/local/lib/aarch64-linux-gnu/gstreamer-1.0
export GST_TRACERS="latency(flags=pipeline+element)"
export GST_DEBUG="GST_TRACER:7"

APP_ID="${AGORA_APP_ID:-89bfa55ce22e4cd8af5451c23a45769d}"
CHANNEL="${AGORA_CHANNEL:-gmsl_cam}"

echo "=== Jetson Sender Latency Tracker ==="
echo "Duration: ${DURATION}s"
echo "Element log: $ELEMENT_LOG"
echo "Summary log: $SUMMARY_LOG"
echo "System log:  $SYSTEM_LOG"
echo ""

# CSV headers
echo "wall_clock_ms,element,latency_ns,latency_ms" > "$ELEMENT_LOG"
echo "timestamp,capsfilter0_ms,videorate0_ms,nvvconv0_ms,nvv4l2h264enc0_ms,h264parse0_ms,total_pipeline_ms,out_video_fps" > "$SUMMARY_LOG"
echo "timestamp,cpu_percent,mem_used_mb,gpu_freq_mhz,enc_freq_mhz" > "$SYSTEM_LOG"

# Start system monitoring in background
(
    while true; do
        ts=$(date +%s%3N)
        cpu=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' 2>/dev/null || echo "0")
        mem=$(free -m | awk '/Mem:/{print $3}' 2>/dev/null || echo "0")
        gpu_freq=$(cat /sys/devices/gpu.0/devfreq/17000000.ga10b/cur_freq 2>/dev/null || echo "0")
        gpu_freq_mhz=$((gpu_freq / 1000000))
        enc_freq=$(cat /sys/kernel/debug/bpmp/debug/clk/nafll_nvenc/rate 2>/dev/null || echo "0")
        enc_freq_mhz=$((enc_freq / 1000000))
        echo "$ts,$cpu,$mem,$gpu_freq_mhz,$enc_freq_mhz" >> "$SYSTEM_LOG"
        sleep 2
    done
) &
SYSTEM_PID=$!

# Run GStreamer pipeline with tracing
timeout "$DURATION" gst-launch-1.0 -e \
  nvv4l2camerasrc device=/dev/video0 ! \
  'video/x-raw(memory:NVMM),format=UYVY,width=1280,height=720,framerate=120/1' ! \
  videorate drop-only=true ! \
  'video/x-raw(memory:NVMM),format=UYVY,width=1280,height=720,framerate=30/1' ! \
  nvvidconv ! \
  'video/x-raw(memory:NVMM),format=NV12' ! \
  nvv4l2h264enc maxperf-enable=1 preset-level=1 control-rate=1 \
      bitrate=1000000 insert-sps-pps=1 iframeinterval=30 num-B-Frames=0 ! \
  h264parse config-interval=-1 ! \
  agorasink appid="$APP_ID" channel="$CHANNEL" verbose=true \
  2>&1 | while IFS= read -r line; do

    # Parse element-latency traces
    if echo "$line" | grep -q "element-latency,"; then
        element=$(echo "$line" | grep -oP 'element=\(string\)\K[^,]+')
        latency_ns=$(echo "$line" | grep -oP 'time=\(guint64\)\K[0-9]+')
        ts_ns=$(echo "$line" | grep -oP 'ts=\(guint64\)\K[0-9]+')
        if [ -n "$element" ] && [ -n "$latency_ns" ]; then
            latency_ms=$(awk "BEGIN {printf \"%.3f\", $latency_ns / 1000000}")
            echo "$ts_ns,$element,$latency_ns,$latency_ms" >> "$ELEMENT_LOG"
        fi
    fi

    # Parse fps output
    if echo "$line" | grep -q "Out video fps:"; then
        fps=$(echo "$line" | grep -oP 'Out video fps: \K[0-9]+')
        echo "  [FPS] Out: $fps"
    fi

    # Print agorasink verbose output (not trace lines)
    if echo "$line" | grep -q "agorasink:" && ! echo "$line" | grep -q "TRACE"; then
        echo "  $line"
    fi

    # Print connection events
    if echo "$line" | grep -q "onConnect\|agora has been"; then
        echo "  [EVENT] $line"
    fi

done

# Stop system monitor
kill $SYSTEM_PID 2>/dev/null

echo ""
echo "=== Pipeline stopped ==="
echo ""

# Generate summary
echo "=== Per-Element Latency Summary ==="
echo ""

if [ -f "$ELEMENT_LOG" ] && [ $(wc -l < "$ELEMENT_LOG") -gt 1 ]; then
    for elem in capsfilter0 videorate0 nvvconv0 nvv4l2h264enc0 h264parse0; do
        count=$(grep ",$elem," "$ELEMENT_LOG" | wc -l)
        if [ "$count" -gt 0 ]; then
            avg=$(grep ",$elem," "$ELEMENT_LOG" | awk -F',' '{sum+=$4; n++} END {if(n>0) printf "%.3f", sum/n; else print "0"}')
            min=$(grep ",$elem," "$ELEMENT_LOG" | awk -F',' 'NR==1||$4<min{min=$4} END {printf "%.3f", min}')
            max=$(grep ",$elem," "$ELEMENT_LOG" | awk -F',' 'NR==1||$4>max{max=$4} END {printf "%.3f", max}')
            p95=$(grep ",$elem," "$ELEMENT_LOG" | awk -F',' '{print $4}' | sort -n | awk -v n="$count" 'NR==int(n*0.95){print}')
            printf "%-25s  samples=%-6d  min=%-8s  avg=%-8s  p95=%-8s  max=%-8s ms\n" "$elem" "$count" "$min" "$avg" "${p95:-N/A}" "$max"
        fi
    done

    echo ""

    # Total pipeline latency per frame cycle
    total_avg=$(grep ",nvv4l2h264enc0," "$ELEMENT_LOG" | awk -F',' '{sum+=$4; n++} END {if(n>0) printf "%.3f", sum/n; else print "0"}')
    nvvidconv_avg=$(grep ",nvvconv0," "$ELEMENT_LOG" | awk -F',' '{sum+=$4; n++} END {if(n>0) printf "%.3f", sum/n; else print "0"}')
    pipeline_total=$(awk "BEGIN {printf \"%.3f\", $total_avg + $nvvidconv_avg + 0.3}")

    echo "=== Total Sender Pipeline Latency ==="
    echo "  nvvidconv:        ${nvvidconv_avg}ms"
    echo "  nvv4l2h264enc:    ${total_avg}ms"
    echo "  other:            ~0.3ms"
    echo "  ─────────────────────────"
    echo "  TOTAL:            ~${pipeline_total}ms"
fi

echo ""
echo "Logs saved to: $LOG_DIR/"
ls -la "$LOG_DIR"/sender_*_${TIMESTAMP}.*
