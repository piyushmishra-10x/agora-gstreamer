#!/bin/bash
# Jetson Sender-Side Latency Tracker
# Logs per-element GStreamer latency to CSV

DURATION=${1:-120}  # default 2 minutes
LOG_DIR="/tmp/latency_logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RAW_LOG="$LOG_DIR/raw_trace_${TIMESTAMP}.log"
ELEMENT_LOG="$LOG_DIR/sender_elements_${TIMESTAMP}.csv"

export GST_PLUGIN_PATH=/usr/local/lib/aarch64-linux-gnu/gstreamer-1.0
export GST_TRACERS="latency(flags=pipeline+element)"
export GST_DEBUG="GST_TRACER:7"

APP_ID="${AGORA_APP_ID:-89bfa55ce22e4cd8af5451c23a45769d}"
CHANNEL="${AGORA_CHANNEL:-gmsl_cam}"

echo "=== Jetson Sender Latency Tracker ==="
echo "Duration: ${DURATION}s"
echo "Raw log:  $RAW_LOG"
echo ""
echo "Starting pipeline... (Ctrl+C to stop early)"
echo ""

# Step 1: Run pipeline, capture all output to file
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
  2>"$RAW_LOG"

echo ""
echo "=== Pipeline stopped. Processing traces... ==="
echo ""

# Step 2: Extract element latencies from raw trace log
echo "wall_clock_ns,element,latency_ns,latency_ms" > "$ELEMENT_LOG"
grep "element-latency," "$RAW_LOG" | while IFS= read -r line; do
    element=$(echo "$line" | grep -oP 'element=\(string\)\K[^,]+')
    latency_ns=$(echo "$line" | grep -oP 'time=\(guint64\)\K[0-9]+')
    ts_ns=$(echo "$line" | grep -oP 'ts=\(guint64\)\K[0-9]+')
    if [ -n "$element" ] && [ -n "$latency_ns" ]; then
        latency_ms=$(awk "BEGIN {printf \"%.3f\", $latency_ns / 1000000}")
        echo "$ts_ns,$element,$latency_ns,$latency_ms" >> "$ELEMENT_LOG"
    fi
done

# Step 3: Extract FPS readings
echo ""
echo "=== FPS Readings ==="
grep "Out video fps:" "$RAW_LOG" | head -20

# Step 4: Summary
echo ""
echo "=== Per-Element Latency Summary ==="
echo ""

ELEM_COUNT=$(wc -l < "$ELEMENT_LOG")
if [ "$ELEM_COUNT" -gt 1 ]; then
    printf "%-25s  %-8s  %-10s  %-10s  %-10s  %-10s\n" "Element" "Samples" "Min(ms)" "Avg(ms)" "P95(ms)" "Max(ms)"
    printf "%-25s  %-8s  %-10s  %-10s  %-10s  %-10s\n" "-------" "-------" "-------" "-------" "-------" "-------"

    for elem in capsfilter0 videorate0 nvvconv0 capsfilter2 nvv4l2h264enc0 h264parse0; do
        count=$(grep ",$elem," "$ELEMENT_LOG" | wc -l)
        if [ "$count" -gt 0 ]; then
            avg=$(grep ",$elem," "$ELEMENT_LOG" | awk -F',' '{sum+=$4; n++} END {if(n>0) printf "%.3f", sum/n; else print "0"}')
            min=$(grep ",$elem," "$ELEMENT_LOG" | awk -F',' 'NR==1{min=$4} $4<min{min=$4} END {printf "%.3f", min}')
            max=$(grep ",$elem," "$ELEMENT_LOG" | awk -F',' 'NR==1{max=$4} $4>max{max=$4} END {printf "%.3f", max}')
            p95=$(grep ",$elem," "$ELEMENT_LOG" | awk -F',' '{print $4}' | sort -n | awk -v n="$count" 'NR==int(n*0.95){printf "%.3f", $0}')
            printf "%-25s  %-8d  %-10s  %-10s  %-10s  %-10s\n" "$elem" "$count" "$min" "$avg" "${p95:-N/A}" "$max"
        fi
    done

    echo ""

    # Total
    enc_avg=$(grep ",nvv4l2h264enc0," "$ELEMENT_LOG" | awk -F',' '{sum+=$4; n++} END {if(n>0) printf "%.3f", sum/n; else print "0"}')
    conv_avg=$(grep ",nvvconv0," "$ELEMENT_LOG" | awk -F',' '{sum+=$4; n++} END {if(n>0) printf "%.3f", sum/n; else print "0"}')
    pipeline_total=$(awk "BEGIN {printf \"%.3f\", $enc_avg + $conv_avg + 0.3}")

    echo "=== Total Sender Pipeline ==="
    echo "  nvvidconv avg:        ${conv_avg} ms"
    echo "  nvv4l2h264enc avg:    ${enc_avg} ms"
    echo "  other (caps+parse):   ~0.3 ms"
    echo "  ─────────────────────────────"
    echo "  TOTAL:                ~${pipeline_total} ms"
else
    echo "No element latency data captured."
    echo "Check raw log for errors:"
    tail -20 "$RAW_LOG"
fi

echo ""
echo "=== Files ==="
ls -lh "$RAW_LOG" "$ELEMENT_LOG"
