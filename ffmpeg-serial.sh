#!/bin/bash
set -uE -o pipefail

LOCK_FILE="/tmp/ffmpeg-global.lock"
LOG_FILE="/tmp/ffmpeg-queue.log"
TIMEOUT_SECONDS=600
LOCK_WAIT_SECONDS=60
MAX_LOG_SIZE=$((20 * 1024 * 1024))

CMD_STR="$*"
TASK_ID="$(date +%Y%m%d-%H%M%S)-$$"

# 日志轮转
if [ -f "$LOG_FILE" ]; then
  LOG_SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$LOG_SIZE" -ge "$MAX_LOG_SIZE" ]; then
    mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
    : > "$LOG_FILE"
  fi
fi

cleanup() {
  local ec=$?
  echo "$(date '+%F %T') [$TASK_ID] script exit($ec): $CMD_STR" >> "$LOG_FILE"
}
trap cleanup EXIT

exec 9>"$LOCK_FILE"

echo "$(date '+%F %T') [$TASK_ID] waiting for lock: $CMD_STR" >> "$LOG_FILE"

if ! flock -w "$LOCK_WAIT_SECONDS" 9; then
  echo "$(date '+%F %T') [$TASK_ID] lock timeout after ${LOCK_WAIT_SECONDS}s: $CMD_STR" >> "$LOG_FILE"
  exit 200
fi

echo "$(date '+%F %T') [$TASK_ID] start: $CMD_STR" >> "$LOG_FILE"

# 默认最后一个参数为输出文件；若明显不是路径，则置空
OUT_PATH="${!#}"
case "$OUT_PATH" in
  ""|-*)
    OUT_PATH=""
    ;;
esac

FAIL_TXT=""
if [ -n "$OUT_PATH" ]; then
  OUT_DIR="$(dirname "$OUT_PATH")"
  OUT_BASE="$(basename "$OUT_PATH")"
  OUT_STEM="${OUT_BASE%.*}"
  mkdir -p -- "$OUT_DIR" 2>/dev/null || true
  FAIL_TXT="${OUT_DIR}/${OUT_STEM}.failed.txt"
  rm -f -- "$FAIL_TXT"
fi

RET=0

timeout --signal=TERM --kill-after=10s "$TIMEOUT_SECONDS" "$@" >> "$LOG_FILE" 2>&1 || RET=$?

if [ "$RET" -ne 0 ]; then
  if [ -n "$OUT_PATH" ]; then
    rm -f -- "$OUT_PATH" "${OUT_PATH}.part" "${OUT_PATH}.tmp"
  fi

  if [ -n "$FAIL_TXT" ]; then
    {
      echo "ffmpeg task failed"
      echo "time: $(date '+%F %T')"
      echo "task_id: $TASK_ID"
      echo "pid: $$"
      echo "exit_code: $RET"
      if [ "$RET" -eq 124 ]; then
        echo "reason: timeout after ${TIMEOUT_SECONDS}s"
      elif [ "$RET" -eq 200 ]; then
        echo "reason: lock wait timeout after ${LOCK_WAIT_SECONDS}s"
      else
        echo "reason: ffmpeg exited with non-zero status"
      fi
      echo "output: ${OUT_PATH:-N/A}"
      echo "command: $CMD_STR"
      echo "log_file: $LOG_FILE"
    } > "$FAIL_TXT"
  fi
fi

echo "$(date '+%F %T') [$TASK_ID] end($RET): $CMD_STR" >> "$LOG_FILE"

exit "$RET"