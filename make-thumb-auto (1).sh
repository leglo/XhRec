#!/bin/bash
set -uE -o pipefail

INPUT="${1:-}"
OUTPUT="${2:-}"
FONT="${FONT:-/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf}"

LOCK_FILE="/tmp/ffmpeg-global.lock"
LOG_FILE="/tmp/ffmpeg-queue.log"
TIMEOUT_SECONDS=1800
LOCK_WAIT_SECONDS=60
MAX_LOG_SIZE=$((20 * 1024 * 1024))

TASK_ID="$(date +%Y%m%d-%H%M%S)-$$"
CMD_STR="make-thumb-auto.sh \"$INPUT\" \"$OUTPUT\""

if [ -z "$INPUT" ] || [ -z "$OUTPUT" ]; then
  echo "Usage: $0 <input_video> <output_image>" >&2
  exit 2
fi

# 日志轮转
if [ -f "$LOG_FILE" ]; then
  LOG_SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$LOG_SIZE" -ge "$MAX_LOG_SIZE" ]; then
    mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
    : > "$LOG_FILE"
  fi
fi

log() {
  echo "$(date '+%F %T') [$TASK_ID] $*" >> "$LOG_FILE"
}

cleanup() {
  local ec=$?

  if [ "$ec" -ne 0 ]; then
    rm -f -- "$OUTPUT" "${OUTPUT}.part" "${OUTPUT}.tmp"
    if [ -n "${FAIL_TXT:-}" ]; then
      {
        echo "make-thumb-auto task failed"
        echo "time: $(date '+%F %T')"
        echo "task_id: $TASK_ID"
        echo "pid: $$"
        echo "exit_code: $ec"
        echo "input: $INPUT"
        echo "output: $OUTPUT"
        echo "log_file: $LOG_FILE"
      } > "$FAIL_TXT"
    fi
  fi

  if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi

  log "script exit($ec): $CMD_STR"
}
trap cleanup EXIT

OUT_DIR="$(dirname "$OUTPUT")"
OUT_BASE="$(basename "$OUTPUT")"
OUT_STEM="${OUT_BASE%.*}"
mkdir -p -- "$OUT_DIR" 2>/dev/null || true
FAIL_TXT="${OUT_DIR}/${OUT_STEM}.failed.txt"
rm -f -- "$FAIL_TXT"

exec 9>"$LOCK_FILE"
log "waiting for lock: $CMD_STR"

if ! flock -w "$LOCK_WAIT_SECONDS" 9; then
  log "lock timeout after ${LOCK_WAIT_SECONDS}s: $CMD_STR"
  exit 200
fi

log "start: $CMD_STR"

run_ffmpeg() {
  timeout --signal=TERM --kill-after=10s "$TIMEOUT_SECONDS" "$@" >> "$LOG_FILE" 2>&1
}

is_positive_number() {
  local v="$1"
  awk -v x="$v" 'BEGIN { exit !(x ~ /^[0-9]+([.][0-9]+)?$/ && x > 0) }'
}

get_duration_from_filename() {
  local name
  name="$(basename "$1")"
  if [[ "$name" =~ ([0-9]{1,3})h([0-9]{1,2})m([0-9]{1,2})s ]]; then
    local h="${BASH_REMATCH[1]}"
    local m="${BASH_REMATCH[2]}"
    local s="${BASH_REMATCH[3]}"
    awk -v h="$h" -v m="$m" -v s="$s" 'BEGIN { printf "%.3f", (h*3600 + m*60 + s) }'
    return 0
  fi
  return 1
}

format_hms_from_seconds() {
  local sec="$1"
  awk -v t="$sec" '
    BEGIN {
      if (t < 0) t = 0
      total = int(t)
      h = int(total / 3600)
      m = int((total % 3600) / 60)
      s = int(total % 60)
      printf "%02d:%02d:%02d", h, m, s
    }'
}

get_reliable_duration() {
  local path="$1"
  local format_dur=""
  local stream_dur=""
  local file_dur=""
  local final_dur=""
  local source=""

  format_dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$path" | tr -d '\r')"
  stream_dur="$(ffprobe -v error -select_streams v:0 -show_entries stream=duration -of csv=p=0 "$path" | tr -d '\r')"

  log "ffprobe format.duration=${format_dur:-<empty>}"
  log "ffprobe stream.duration=${stream_dur:-<empty>}"

  if file_dur="$(get_duration_from_filename "$path" 2>/dev/null)"; then
    log "filename duration=${file_dur}s"
  else
    file_dur=""
    log "filename duration=<none>"
  fi

  if [ -n "${format_dur:-}" ] && is_positive_number "$format_dur"; then
    final_dur="$format_dur"
    source="format"
  elif [ -n "${stream_dur:-}" ] && is_positive_number "$stream_dur"; then
    final_dur="$stream_dur"
    source="stream"
  else
    final_dur=""
    source="none"
  fi

  if [ -n "${file_dur:-}" ] && [ -n "${final_dur:-}" ] && is_positive_number "$file_dur" && is_positive_number "$final_dur"; then
    if awk -v p="$final_dur" -v f="$file_dur" 'BEGIN { exit !(p > f * 1.2) }'; then
      log "duration override: ffprobe=${final_dur}s > filename*1.2=${file_dur}s, use filename"
      final_dur="$file_dur"
      source="filename_override"
    fi
  elif [ -z "${final_dur:-}" ] && [ -n "${file_dur:-}" ] && is_positive_number "$file_dur"; then
    final_dur="$file_dur"
    source="filename_fallback"
  fi

  if [ -z "${final_dur:-}" ] || ! is_positive_number "$final_dur"; then
    final_dur="1.000"
    source="hardcoded_fallback"
  fi

  log "duration selected=${final_dur}s source=$source"
  printf "%s\n" "$final_dur"
}

get_video_size() {
  local path="$1"
  local size=""
  size="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$path" | tr -d '\r')"
  if [[ "$size" =~ ^([0-9]+)x([0-9]+)$ ]]; then
    printf "%s\n" "$size"
  else
    printf "1920x1080\n"
  fi
}

make_black_frame() {
  local frame_file="$1"
  local thumb_w="$2"
  local thumb_h="$3"
  local escaped_time="$4"

  log "make black frame: $frame_file"

  run_ffmpeg \
    ffmpeg \
    -hide_banner \
    -loglevel error \
    -nostats \
    -f lavfi \
    -i "color=c=black:s=${thumb_w}x${thumb_h}:r=1" \
    -frames:v 1 \
    -update 1 \
    -vf "drawtext=fontfile=${FONT}:text='${escaped_time}':x=w-tw-12:y=h-th-12:fontsize=52:fontcolor=white:borderw=3:bordercolor=black:box=1:boxcolor=black@0.7:boxborderw=8,format=yuvj420p" \
    -q:v 6 \
    -y \
    "$frame_file"

  [ -s "$frame_file" ]
}

DURATION="$(get_reliable_duration "$INPUT")"
DURATION_INT="$(awk -v d="$DURATION" 'BEGIN{ n=int(d); if (n<1) n=1; print n }')"
DURATION_TEXT="$(format_hms_from_seconds "$DURATION")"

# 分档：最少 4x4，最多 7x7
# <10秒        -> 4x4
# 10秒~30秒    -> 5x5
# 30秒~5分钟   -> 6x6
# 5分钟以上    -> 7x7
if [ "$DURATION_INT" -lt 10 ]; then
  TILE="4x4"
  COUNT=16
elif [ "$DURATION_INT" -lt 30 ]; then
  TILE="5x5"
  COUNT=25
elif [ "$DURATION_INT" -lt 300 ]; then
  TILE="6x6"
  COUNT=36
else
  TILE="7x7"
  COUNT=49
fi

VIDEO_SIZE="$(get_video_size "$INPUT")"
VIDEO_W="${VIDEO_SIZE%x*}"
VIDEO_H="${VIDEO_SIZE#*x}"

THUMB_W=400
THUMB_H="$(awk -v vw="$VIDEO_W" -v vh="$VIDEO_H" -v tw="$THUMB_W" '
  BEGIN {
    h = int((vh * tw / vw) + 0.5)
    if (h < 2) h = 2
    print h
  }'
)"

TMP_DIR="$(mktemp -d /tmp/thumbgrid.XXXXXX)"

log "input=$INPUT"
log "duration=${DURATION}s"
log "duration_text=${DURATION_TEXT}"
log "tile=$TILE count=$COUNT"
log "video_size=${VIDEO_W}x${VIDEO_H}"
log "thumb_size=${THUMB_W}x${THUMB_H}"
log "output=$OUTPUT"
log "temp_dir=$TMP_DIR"

i=0
while [ "$i" -lt "$COUNT" ]; do
  INDEX=$((i + 1))

  TSEC="$(awk -v i="$i" -v count="$COUNT" -v dur="$DURATION" '
    BEGIN {
      t=((i+0.5)*dur)/count
      safeTail = dur/100.0
      if (safeTail > 0.20) safeTail = 0.20
      maxT = dur - safeTail
      if (maxT < 0) maxT = 0
      if (t > maxT) t = maxT
      if (t < 0) t = 0
      printf "%.3f", t
    }'
  )"

  TIME_TEXT="$(format_hms_from_seconds "$TSEC")"
  ESCAPED_TIME_TEXT="${TIME_TEXT//:/\\:}"
  FRAME_FILE="$(printf "%s/frame_%03d.jpg" "$TMP_DIR" "$INDEX")"

  log "capture $INDEX/$COUNT at $TIME_TEXT ($TSEC s)"

  rm -f -- "$FRAME_FILE"

  if ! run_ffmpeg \
    ffmpeg \
    -hide_banner \
    -loglevel error \
    -nostats \
    -ss "$TSEC" \
    -i "$INPUT" \
    -frames:v 1 \
    -update 1 \
    -vf "drawtext=fontfile=${FONT}:text='${ESCAPED_TIME_TEXT}':x=w-tw-12:y=h-th-12:fontsize=52:fontcolor=white:borderw=3:bordercolor=black:box=1:boxcolor=black@0.7:boxborderw=8,scale=${THUMB_W}:-1,format=yuvj420p" \
    -q:v 6 \
    -y \
    "$FRAME_FILE"
  then
    log "fast seek failed at $TIME_TEXT, retry with accurate seek"

    rm -f -- "$FRAME_FILE"

    run_ffmpeg \
      ffmpeg \
      -hide_banner \
      -loglevel error \
      -nostats \
      -i "$INPUT" \
      -ss "$TSEC" \
      -frames:v 1 \
      -update 1 \
      -vf "drawtext=fontfile=${FONT}:text='${ESCAPED_TIME_TEXT}':x=w-tw-12:y=h-th-12:fontsize=52:fontcolor=white:borderw=3:bordercolor=black:box=1:boxcolor=black@0.7:boxborderw=8,scale=${THUMB_W}:-1,format=yuvj420p" \
      -q:v 6 \
      -y \
      "$FRAME_FILE"
  fi

  if [ ! -s "$FRAME_FILE" ]; then
    log "capture failed, use black frame: $FRAME_FILE"
    rm -f -- "$FRAME_FILE"

    if ! make_black_frame "$FRAME_FILE" "$THUMB_W" "$THUMB_H" "$ESCAPED_TIME_TEXT"; then
      log "black frame failed: $FRAME_FILE"
      exit 1
    fi
  fi

  i=$((i + 1))
done

log "start tile compose"

run_ffmpeg \
  ffmpeg \
  -hide_banner \
  -loglevel error \
  -nostats \
  -framerate 1 \
  -i "$TMP_DIR/frame_%03d.jpg" \
  -vf "tile=${TILE},format=yuvj420p" \
  -frames:v 1 \
  -q:v 6 \
  -y \
  "$OUTPUT"

if [ ! -s "$OUTPUT" ]; then
  log "output not generated: $OUTPUT"
  exit 1
fi

rm -f -- "$FAIL_TXT"
log "end(0): $CMD_STR"
exit 0