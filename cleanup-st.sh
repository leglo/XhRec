#!/bin/bash
set -uo pipefail

BASE="/opt/1panel/www/sites/down/ST"
LOG="/var/log/cleanup-st.log"

{
  echo "==== $(date '+%F %T') cleanup start ===="

  find "$BASE" -type f \( -name '*.event' -o -name '*.thumb.jpg' -o -name '*.mp4' \) -mtime +7 -print -delete

  echo "==== $(date '+%F %T') cleanup end ===="
  echo
} >> "$LOG" 2>&1
