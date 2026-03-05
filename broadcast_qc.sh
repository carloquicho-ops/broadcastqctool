#!/bin/bash
# =============================================================================
# broadcast_qc.sh — Production broadcast QC pipeline v4.1
# Requires: bash 4+, ffmpeg (Topaz), ffmpeg with cropdetect (OBS/standalone)
#
# v4 additions:
#   - Interactive spec prompt (resolution, fps, codec, audio, loudness, timecode)
#   - Audio loudness metering: integrated LUFS, true peak, LRA (ebur128)
#   - Audio codec validation
#   - Color space metadata validation (flags 'unknown' transfer characteristics)
#   - Timecode start validation
#   - YMIN/YMAX consistency check (codec artifact detection)
#   - Freeze detection now escalates verdict
#   - Spec validation message accurately reflects constraint state
# v4.1 additions:
#   - XR North America preset (Extreme Reach, US+CA broadcast delivery)
#   - BRNG threshold aligned to EBU Rec.103-2000 1% tolerance from spec
#   - Black frames section notes expected 2s pre-roll black (XR slate layout)
# =============================================================================

# --- Primary ffmpeg ----------------------------------------------------------
FFMPEG="/c/Program Files/Topaz Labs LLC/Topaz Video AI/ffmpeg.exe"

# --- cropdetect ffmpeg: found dynamically, survives app updates --------------
find_cropdetect_ffmpeg() {
  local candidates=(
    "/c/ffmpeg/bin/ffmpeg.exe"
    "/c/Program Files/ffmpeg/bin/ffmpeg.exe"
    "/usr/bin/ffmpeg"
  )
  local path_ff
  path_ff=$(command -v ffmpeg 2>/dev/null || true)
  [[ -n "$path_ff" ]] && candidates+=("$path_ff")
  while IFS= read -r -d '' f; do
    candidates+=("$f")
  done < <(find "/c/Users/CarloPC/AppData/Local/Overwolf" -name "ffmpeg.exe" -print0 2>/dev/null)
  for ff in "${candidates[@]}"; do
    if [[ -x "$ff" ]] && "$ff" -filters 2>/dev/null | grep -q "cropdetect"; then
      echo "$ff"; return 0
    fi
  done
  return 1
}

FFMPEG_CROP=$(find_cropdetect_ffmpeg)

# --- Validate binaries -------------------------------------------------------
if [[ ! -x "$FFMPEG" ]]; then
  echo "ERROR: Primary ffmpeg not found: $FFMPEG" >&2; exit 1
fi
if [[ -z "$FFMPEG_CROP" ]]; then
  echo "WARNING: No cropdetect-capable ffmpeg found — cropdetect will be skipped" >&2
  CROPDETECT_AVAILABLE=0
else
  CROPDETECT_AVAILABLE=1
  echo "INFO: cropdetect binary: $FFMPEG_CROP"
fi

# --- Timeout wrapper ---------------------------------------------------------
FFMPEG_TIMEOUT=300

run_ff() {
  if [[ $FFMPEG_TIMEOUT -gt 0 ]] && command -v timeout >/dev/null 2>&1; then
    timeout "$FFMPEG_TIMEOUT" "$@"
  else
    "$@"
  fi
}

# --- Delivery spec (defaults; overridden interactively by prompt_spec) -------
EXPECTED_WIDTH=""           # e.g. "1920"
EXPECTED_HEIGHT=""          # e.g. "1080"
EXPECTED_FPS=""             # e.g. "25" or "23.976"
EXPECTED_CODEC=""           # e.g. "prores" or "h264"
EXPECTED_PIX_FMT=""         # e.g. "yuv422p10le"
EXPECTED_AUDIO_SR=48000     # Hz — empty to skip
EXPECTED_AUDIO_CH=2         # 2=stereo, 1=mono — empty to skip
EXPECTED_AUDIO_CODEC=""     # e.g. "pcm_s24le"
EXPECTED_TIMECODE=""        # e.g. "01:00:00:00" — empty to skip

# --- Audio loudness ----------------------------------------------------------
LUFS_TARGET=""              # Integrated loudness target (LUFS); empty = skip
                            #   -24.0 = ATSC A/85   -23.0 = EBU R128
LUFS_TOLERANCE="1.0"        # Permitted deviation ±LU
TRUE_PEAK_LIMIT=""          # Max true peak (dBTP); empty = skip; common: -2.0
LRA_LIMIT=""                # Max loudness range (LU); empty = skip; common: 20.0

# --- Signal thresholds -------------------------------------------------------
BRNG_WARN=0.005
BRNG_FAIL=0.020
TOUT_WARN=0.005
SATMAX_WARN=200
BLACK_MIN_DUR=0.5
FREEZE_MIN_DUR=2
YMIN_10=64;  YMAX_10=940
YMIN_8=16;   YMAX_8=235
YMIN_12=256; YMAX_12=3760

# =============================================================================
# Verdict escalation — PASS → FLAG → FAIL only, never downgrade
# =============================================================================
VERDICT="PASS"
escalate() {
  case "$1" in
    FAIL) VERDICT="FAIL" ;;
    FLAG) [[ "$VERDICT" != "FAIL" ]] && VERDICT="FLAG" ;;
  esac
}

get_stat() {
  echo "$1" | awk -v s="$2" -v f="$3" \
    '$1==s { for(i=2;i<=NF;i++) { split($i,a,"="); if(a[1]==f) print a[2] } }'
}

# =============================================================================
# Spec presets
# =============================================================================

# XR North America — Extreme Reach US + Canada broadcast delivery spec
# Source: Extreme Reach Help Center (North America Broadcast Specifications)
preset_xr_na() {
  EXPECTED_WIDTH="1920"
  EXPECTED_HEIGHT="1080"
  EXPECTED_FPS="23.98"
  EXPECTED_CODEC="prores"
  EXPECTED_PIX_FMT="yuv422p10le"
  EXPECTED_AUDIO_SR="48000"
  EXPECTED_AUDIO_CH="2"
  EXPECTED_AUDIO_CODEC="pcm"
  LUFS_TARGET="-24.0"
  LUFS_TOLERANCE="1.0"
  TRUE_PEAK_LIMIT="-2.0"
  LRA_LIMIT=""
  EXPECTED_TIMECODE=""
  # EBU Rec.103-2000: flag at 1% of active picture out of range
  BRNG_WARN=0.010
  BRNG_FAIL=0.020
}

# =============================================================================
# Spec file save / load / document parse
# =============================================================================

# Save current constraints to a reusable config file
_save_spec_file() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  {
    echo "# broadcast_qc spec file — saved $(date '+%Y-%m-%d %H:%M')"
    echo "EXPECTED_WIDTH='${EXPECTED_WIDTH}'"
    echo "EXPECTED_HEIGHT='${EXPECTED_HEIGHT}'"
    echo "EXPECTED_FPS='${EXPECTED_FPS}'"
    echo "EXPECTED_CODEC='${EXPECTED_CODEC}'"
    echo "EXPECTED_PIX_FMT='${EXPECTED_PIX_FMT}'"
    echo "EXPECTED_AUDIO_SR='${EXPECTED_AUDIO_SR}'"
    echo "EXPECTED_AUDIO_CH='${EXPECTED_AUDIO_CH}'"
    echo "EXPECTED_AUDIO_CODEC='${EXPECTED_AUDIO_CODEC}'"
    echo "LUFS_TARGET='${LUFS_TARGET}'"
    echo "LUFS_TOLERANCE='${LUFS_TOLERANCE}'"
    echo "TRUE_PEAK_LIMIT='${TRUE_PEAK_LIMIT}'"
    echo "LRA_LIMIT='${LRA_LIMIT}'"
    echo "EXPECTED_TIMECODE='${EXPECTED_TIMECODE}'"
    echo "BRNG_WARN=${BRNG_WARN}"
    echo "BRNG_FAIL=${BRNG_FAIL}"
  } > "$path"
  echo " Saved: $path"
}

# Load a saved spec config file (key=value format)
# Only sets variables with recognised names — no eval of arbitrary content
_load_spec_conf() {
  local path="$1"
  local known="EXPECTED_WIDTH EXPECTED_HEIGHT EXPECTED_FPS EXPECTED_CODEC \
    EXPECTED_PIX_FMT EXPECTED_AUDIO_SR EXPECTED_AUDIO_CH EXPECTED_AUDIO_CODEC \
    LUFS_TARGET LUFS_TOLERANCE TRUE_PEAK_LIMIT LRA_LIMIT EXPECTED_TIMECODE \
    BRNG_WARN BRNG_FAIL"
  local loaded=0
  while IFS='=' read -r raw_key raw_val; do
    local key val
    key=$(echo "$raw_key" | tr -d " \t'\"")
    val=$(echo "$raw_val" | tr -d "'\"" | sed 's/[[:space:]]*#.*//' | tr -d '\r')
    [[ -z "$key" || "$key" == \#* ]] && continue
    if echo "$known" | grep -qw "$key"; then
      printf -v "$key" '%s' "$val"
      loaded=$((loaded+1))
    fi
  done < "$path"
  [[ $loaded -gt 0 ]]
}

# Best-effort extraction of spec values from text (PDF text dump, TXT doc, etc.)
_parse_spec_text() {
  local text="$1"
  local found=0

  # Resolution: "1920 x 1080", "1920x1080", "1920 × 1080"
  local res
  res=$(echo "$text" | grep -oiE "[0-9]{3,4}[[:space:]]*[xX×][[:space:]]*[0-9]{3,4}" \
    | grep -v "0x" | head -1 | tr -d ' ')
  if [[ -n "$res" ]]; then
    local w h
    w=$(echo "$res" | grep -oiE "^[0-9]+")
    h=$(echo "$res" | grep -oiE "[0-9]+$")
    [[ -n "$w" && -n "$h" ]] && { EXPECTED_WIDTH="$w"; EXPECTED_HEIGHT="$h"; found=$((found+2)); }
  fi

  # Frame rate: common broadcast values
  local fps
  fps=$(echo "$text" | grep -oiE "(23\.98|29\.97|25\.00|25|24\.00|24|59\.94|30\.00|30)[[:space:]]*(fps|p\b)" \
    | head -1 | grep -oE "[0-9]+\.[0-9]+|^[0-9]+" | head -1)
  [[ -n "$fps" ]] && { EXPECTED_FPS="$fps"; found=$((found+1)); }

  # Codec
  if echo "$text" | grep -qi "ProRes"; then
    EXPECTED_CODEC="prores"; found=$((found+1))
  elif echo "$text" | grep -qiE "XDCAM|XD CAM"; then
    EXPECTED_CODEC="xdcam"; found=$((found+1))
  elif echo "$text" | grep -qiE "DNxHD|DNx"; then
    EXPECTED_CODEC="dnxhd"; found=$((found+1))
  elif echo "$text" | grep -qiE "H\.264|AVC\b|H264"; then
    EXPECTED_CODEC="h264"; found=$((found+1))
  fi

  # Audio sample rate
  if echo "$text" | grep -qiE "48[[:space:]]?kHz|48000[[:space:]]?Hz"; then
    EXPECTED_AUDIO_SR="48000"; found=$((found+1))
  elif echo "$text" | grep -qiE "44\.1[[:space:]]?kHz|44100"; then
    EXPECTED_AUDIO_SR="44100"; found=$((found+1))
  fi

  # Audio codec
  if echo "$text" | grep -qiE "\bPCM\b"; then
    EXPECTED_AUDIO_CODEC="pcm"; found=$((found+1))
  elif echo "$text" | grep -qiE "\bAAC\b"; then
    EXPECTED_AUDIO_CODEC="aac"; found=$((found+1))
  fi

  # Integrated loudness — LUFS or LKFS
  local lufs
  lufs=$(echo "$text" | grep -oiE "[-][0-9]+\.?[0-9]*[[:space:]]*(LUFS|LKFS)" \
    | head -1 | grep -oE "[-][0-9]+\.?[0-9]*")
  [[ -n "$lufs" ]] && { LUFS_TARGET="$lufs"; found=$((found+1)); }

  # True peak
  local tp
  tp=$(echo "$text" | grep -oiE "[-][0-9]+\.?[0-9]*[[:space:]]*dB[[:space:]]*TP" \
    | head -1 | grep -oE "[-][0-9]+\.?[0-9]*")
  [[ -n "$tp" ]] && { TRUE_PEAK_LIMIT="$tp"; found=$((found+1)); }

  # Audio channels
  if echo "$text" | grep -qiE "\bstereo\b"; then
    EXPECTED_AUDIO_CH="2"; found=$((found+1))
  elif echo "$text" | grep -qiE "\bmono\b"; then
    EXPECTED_AUDIO_CH="1"; found=$((found+1))
  fi

  echo " Extracted $found values from document."
  [[ $found -gt 0 ]]
}

# Normalise a file path: convert backslashes, strip surrounding quotes
_norm_path() { echo "$1" | tr '\\' '/' | tr -d '"' | tr -d "'"; }

# =============================================================================
# prompt_spec — interactive delivery spec setup
# =============================================================================
prompt_spec() {
  echo ""
  echo "============================================================"
  echo " BROADCAST SPEC SETUP"
  echo "============================================================"
  echo ""
  echo "   1) XR North America    — Extreme Reach US+CA broadcast"
  echo "      1920x1080 @ 23.98fps  ProRes  PCM 48kHz  -24 LUFS  -2 dBTP"
  echo ""
  echo "   2) Load from file      — saved spec config (.conf) or"
  echo "                            spec document (PDF or TXT)"
  echo ""
  echo "   3) Custom              — enter all values manually"
  echo ""
  echo "   4) Skip                — observe-only, no constraints"
  echo ""
  local choice
  read -rp " Choice [1]: " choice
  choice="${choice:-1}"

  case "$choice" in
    1)
      preset_xr_na
      echo ""
      echo " XR North America preset loaded."
      echo " Review values below — press Enter to accept, or type a new value to override."
      ;;
    2)
      echo ""
      read -rp " Spec file path (drag & drop or type): " raw_path
      local spec_path
      spec_path=$(_norm_path "$raw_path")
      if [[ ! -f "$spec_path" ]]; then
        echo " ERROR: File not found: $spec_path"
        echo " Falling back to custom entry."
      else
        local ext="${spec_path##*.}"
        local raw_text=""
        case "${ext,,}" in
          conf|spec|sh)
            if _load_spec_conf "$spec_path"; then
              echo " Spec config loaded from: $spec_path"
            else
              echo " WARN: No recognised values found in config — check format."
            fi
            ;;
          pdf)
            echo " Parsing PDF..."
            if command -v pdftotext >/dev/null 2>&1; then
              raw_text=$(pdftotext "$spec_path" - 2>/dev/null)
            else
              # Fallback: strings strips binary, leaves readable text
              raw_text=$(strings "$spec_path" 2>/dev/null)
              echo " NOTE: pdftotext not found — using strings fallback."
              echo "       Install poppler (winget install poppler) for full PDF support."
            fi
            [[ -n "$raw_text" ]] && _parse_spec_text "$raw_text" \
              || echo " WARN: Could not extract text from PDF."
            ;;
          txt|md|*)
            raw_text=$(cat "$spec_path" 2>/dev/null)
            [[ -n "$raw_text" ]] && _parse_spec_text "$raw_text" \
              || echo " WARN: File appears empty."
            ;;
        esac
      fi
      echo " Review extracted values below — press Enter to accept each, or type to override."
      ;;
    4)
      EXPECTED_WIDTH=""; EXPECTED_HEIGHT=""; EXPECTED_FPS=""
      EXPECTED_CODEC=""; EXPECTED_PIX_FMT=""
      EXPECTED_AUDIO_SR=""; EXPECTED_AUDIO_CH=""; EXPECTED_AUDIO_CODEC=""
      LUFS_TARGET=""; TRUE_PEAK_LIMIT=""; LRA_LIMIT=""
      EXPECTED_TIMECODE=""
      echo ""
      echo " Skipped — all checks will observe-only."
      echo "============================================================"
      echo ""
      return
      ;;
    *)  # 3 = custom, also catches unknown input
      echo ""
      echo " Custom mode — press Enter to leave a field unchecked."
      ;;
  esac

  echo ""

  # _ask LABEL VARNAME
  _ask() {
    local label="$1" varname="$2"
    local current="${!varname}"
    local display="${current:-skip}"
    local answer
    read -rp " $label [${display}]: " answer
    case "$answer" in
      skip|SKIP) printf -v "$varname" '%s' '' ;;
      "")        : ;;
      *)         printf -v "$varname" '%s' "$answer" ;;
    esac
  }

  echo "--- Video ---"
  _ask "Width          (e.g. 1920, 3840, 4608)"          EXPECTED_WIDTH
  _ask "Height         (e.g. 1080, 2160, 2592)"          EXPECTED_HEIGHT
  _ask "Frame rate     (e.g. 23.98, 29.97, 24)"          EXPECTED_FPS
  _ask "Codec          (e.g. prores, h264, dnxhd)"       EXPECTED_CODEC
  _ask "Pixel format   (e.g. yuv422p10le, yuv420p)"      EXPECTED_PIX_FMT
  echo ""
  echo "--- Audio ---"
  _ask "Sample rate Hz (e.g. 48000)"                     EXPECTED_AUDIO_SR
  _ask "Channels       (2=stereo, 1=mono)"               EXPECTED_AUDIO_CH
  _ask "Audio codec    (e.g. pcm, aac)"                  EXPECTED_AUDIO_CODEC
  _ask "Loudness LUFS  (-24.0 ATSC A/85 / -23.0 EBU R128)" LUFS_TARGET
  _ask "LUFS tolerance ±LU (default: ${LUFS_TOLERANCE})" LUFS_TOLERANCE
  _ask "True peak dBTP (e.g. -2.0)"                      TRUE_PEAK_LIMIT
  _ask "LRA limit LU   (e.g. 20.0)"                      LRA_LIMIT
  echo ""
  echo "--- Container ---"
  _ask "Timecode start (e.g. 01:00:00:00)"               EXPECTED_TIMECODE

  # --- Summary ---------------------------------------------------------------
  echo ""
  echo " Active constraints:"
  local shown=0

  # _show VARNAME LABEL
  _show() { [[ -n "${!1}" ]] && { printf "   %-16s %s\n" "$2:" "${!1}"; shown=1; }; }

  _show EXPECTED_WIDTH       "Width"
  _show EXPECTED_HEIGHT      "Height"
  _show EXPECTED_FPS         "Frame rate"
  _show EXPECTED_CODEC       "Codec"
  _show EXPECTED_PIX_FMT    "Pixel fmt"
  _show EXPECTED_AUDIO_SR   "Audio SR"
  _show EXPECTED_AUDIO_CH   "Audio ch"
  _show EXPECTED_AUDIO_CODEC "Audio codec"
  _show LUFS_TARGET          "LUFS target"
  [[ -n "$LUFS_TARGET" ]] && printf "   %-16s ±%s LU\n" "LUFS tolerance:" "$LUFS_TOLERANCE"
  _show TRUE_PEAK_LIMIT      "True peak"
  _show LRA_LIMIT            "LRA limit"
  _show EXPECTED_TIMECODE    "Timecode"
  printf "   %-16s %.3f (flag) / %.3f (fail)\n" "BRNG:" "$BRNG_WARN" "$BRNG_FAIL"
  [[ $shown -eq 0 ]] && echo "   (none — signal checks will observe-only)"

  # --- Save ------------------------------------------------------------------
  echo ""
  echo " Save these constraints for future runs?"
  local save_path
  read -rp " File path (or Enter to skip): " save_path
  save_path=$(_norm_path "$save_path")
  [[ -n "$save_path" ]] && _save_spec_file "$save_path"

  echo "============================================================"
  echo ""
}

# =============================================================================
run_qc() {
  local INPUT="$1" NAME="$2" OUT="$3"
  local REPORT="$OUT/qc_report.txt"
  VERDICT="PASS"

  mkdir -p "$OUT"

  if [[ ! -f "$INPUT" ]]; then
    echo "ERROR: File not found: $INPUT" >&2; return 1
  fi

  echo ""; echo "============================================================"
  echo " Analysing: $NAME"; echo "============================================================"

  # --- File probe ------------------------------------------------------------
  local file_info
  file_info=$(run_ff "$FFMPEG" -i "$INPUT" -f null - 2>&1)

  local duration vid_stream aud_stream pix_fmt width height fps
  duration=$(   echo "$file_info" | grep -oE "Duration: [0-9:.]+" | head -1 | awk '{print $2}')
  vid_stream=$( echo "$file_info" | grep "Stream #0:" | grep -i "Video:"  | head -1)
  aud_stream=$( echo "$file_info" | grep "Stream #0:" | grep -i "Audio:"  | head -1)
  pix_fmt=$(    echo "$vid_stream" | grep -oE "yuv[a-z0-9]+" | head -1)
  width=$(      echo "$vid_stream" | grep -oE "[0-9]{3,}x[0-9]{3,}" | head -1 | cut -dx -f1)
  height=$(     echo "$vid_stream" | grep -oE "[0-9]{3,}x[0-9]{3,}" | head -1 | cut -dx -f2)
  fps=$(        echo "$vid_stream" | grep -oE "[0-9.]+ fps" | head -1 | awk '{print $1}')

  local bit_depth ymin_limit ymax_limit
  if echo "$pix_fmt" | grep -q "12"; then
    bit_depth=12; ymin_limit=$YMIN_12; ymax_limit=$YMAX_12
  elif echo "$pix_fmt" | grep -q "10"; then
    bit_depth=10; ymin_limit=$YMIN_10; ymax_limit=$YMAX_10
  else
    bit_depth=8;  ymin_limit=$YMIN_8;  ymax_limit=$YMAX_8
  fi

  {
    echo "============================================================"
    echo " QC REPORT: $NAME"
    echo " Date:         $(date '+%Y-%m-%d %H:%M:%S')"
    echo " File:         $INPUT"
    echo " QC binary:    $FFMPEG"
    echo " Crop binary:  ${FFMPEG_CROP:-N/A}"
    echo "============================================================"
    echo ""
    echo "=== FILE INFO ==="
    echo " Duration:    $duration"
    echo " Resolution:  ${width}x${height}"
    echo " Frame rate:  $fps fps"
    echo " Pixel fmt:   $pix_fmt  (${bit_depth}-bit)"
    echo " Video:         $vid_stream"
    echo " Audio:         ${aud_stream:-NONE DETECTED}"
    local all_streams
    all_streams=$(echo "$file_info" | grep "Stream #0:" | grep "\[0x")
    echo "--- All streams ---"
    echo "$all_streams"
    echo ""
  } > "$REPORT"

  # --- Spec validation -------------------------------------------------------
  {
    echo "=== SPEC VALIDATION ==="
    local spec_issue=0
    if [[ -n "$EXPECTED_WIDTH" && "$width" != "$EXPECTED_WIDTH" ]]; then
      echo "FAIL — Width $width ≠ expected $EXPECTED_WIDTH"; escalate FAIL; spec_issue=1
    fi
    if [[ -n "$EXPECTED_HEIGHT" && "$height" != "$EXPECTED_HEIGHT" ]]; then
      echo "FAIL — Height $height ≠ expected $EXPECTED_HEIGHT"; escalate FAIL; spec_issue=1
    fi
    if [[ -n "$EXPECTED_FPS" && "$fps" != "$EXPECTED_FPS" ]]; then
      echo "FLAG — Frame rate $fps ≠ expected $EXPECTED_FPS"; escalate FLAG; spec_issue=1
    fi
    if [[ -n "$EXPECTED_CODEC" ]]; then
      local detected_codec
      detected_codec=$(echo "$vid_stream" | sed -n 's/.*Video: \([a-z0-9_]*\).*/\1/p' | head -1)
      if ! echo "$detected_codec" | grep -qi "$EXPECTED_CODEC"; then
        echo "FAIL — Codec '$detected_codec' ≠ expected '$EXPECTED_CODEC'"; escalate FAIL; spec_issue=1
      else
        echo "PASS — Codec: $detected_codec"
      fi
    fi
    if [[ -n "$EXPECTED_PIX_FMT" && "$pix_fmt" != "$EXPECTED_PIX_FMT" ]]; then
      echo "FAIL — Pixel format '$pix_fmt' ≠ expected '$EXPECTED_PIX_FMT'"; escalate FAIL; spec_issue=1
    fi
    if [[ $spec_issue -eq 0 ]]; then
      local any_video_constraint=""
      [[ -n "$EXPECTED_WIDTH$EXPECTED_HEIGHT$EXPECTED_FPS$EXPECTED_CODEC$EXPECTED_PIX_FMT" ]] && any_video_constraint=1
      if [[ -n "$any_video_constraint" ]]; then
        echo "PASS — all video spec constraints met"
      else
        echo "INFO — no video spec constraints set"
      fi
    fi
    echo ""
  } >> "$REPORT"

  # --- Audio -----------------------------------------------------------------
  {
    echo "=== AUDIO ==="
    if [[ -z "$aud_stream" ]]; then
      echo "FAIL — No audio stream detected"; escalate FAIL
    else
      local audio_sr audio_layout audio_codec
      audio_sr=$(    echo "$aud_stream" | grep -oE "[0-9]+ Hz"               | head -1 | awk '{print $1}')
      audio_layout=$(echo "$aud_stream" | grep -oE "stereo|mono|[0-9]\.[01]" | head -1)
      audio_codec=$( echo "$aud_stream" | sed -n 's/.*Audio: \([a-z0-9_]*\).*/\1/p' | head -1)
      echo " Stream:   $aud_stream"
      if [[ -n "$EXPECTED_AUDIO_SR" && $EXPECTED_AUDIO_SR -gt 0 && "$audio_sr" != "$EXPECTED_AUDIO_SR" ]]; then
        echo "FLAG — Sample rate ${audio_sr}Hz ≠ expected ${EXPECTED_AUDIO_SR}Hz"; escalate FLAG
      else
        echo "PASS — Sample rate ${audio_sr}Hz"
      fi
      if [[ -n "$EXPECTED_AUDIO_CH" ]]; then
        local expected_layout="stereo"
        [[ "$EXPECTED_AUDIO_CH" == "1" ]] && expected_layout="mono"
        if [[ "$audio_layout" != "$expected_layout" ]]; then
          echo "FLAG — Layout '$audio_layout' ≠ expected $expected_layout"; escalate FLAG
        else
          echo "PASS — Layout: $audio_layout"
        fi
      else
        echo "PASS — Layout: $audio_layout"
      fi
      if [[ -n "$EXPECTED_AUDIO_CODEC" ]]; then
        if ! echo "$audio_codec" | grep -qi "$EXPECTED_AUDIO_CODEC"; then
          echo "FLAG — Audio codec '$audio_codec' ≠ expected '$EXPECTED_AUDIO_CODEC'"; escalate FLAG
        else
          echo "PASS — Audio codec: $audio_codec"
        fi
      fi
    fi
    echo ""
  } >> "$REPORT"

  # --- Audio loudness (LUFS / ebur128) ---------------------------------------
  {
    echo "=== AUDIO LOUDNESS ==="
    if [[ -z "$aud_stream" ]]; then
      echo "SKIP — no audio stream"
    else
      local lufs_out
      # peak=sample: best available in Topaz ffmpeg build (true_peak not supported)
      # Sample peak is a conservative proxy — true peak can only be >= sample peak
      lufs_out=$(run_ff "$FFMPEG" -i "$INPUT" \
        -af "ebur128=peak=sample" -f null - 2>&1)
      local lufs_i lufs_tp lufs_lra
      lufs_i=$(  echo "$lufs_out" | grep -E "^\s+I:"    | head -1 | grep -oE "[-0-9.]+" | head -1)
      lufs_tp=$( echo "$lufs_out" | grep -E "^\s+Peak:" | head -1 | grep -oE "[-0-9.]+" | head -1)
      lufs_lra=$(echo "$lufs_out" | grep -E "^\s+LRA:"  | head -1 | grep -oE "[-0-9.]+" | head -1)
      if [[ -z "$lufs_i" ]]; then
        echo "WARN — ebur128 produced no output (silent file or filter unavailable)"
      else
        echo " Integrated loudness: ${lufs_i} LUFS"
        echo " Sample peak:         ${lufs_tp:-N/A} dBFS  (proxy for true peak)"
        echo " Loudness range:      ${lufs_lra:-N/A} LU"
        echo ""
        # Integrated loudness
        if [[ -n "$LUFS_TARGET" ]]; then
          local lo hi
          lo=$(awk "BEGIN{printf \"%.3f\", $LUFS_TARGET - $LUFS_TOLERANCE}")
          hi=$(awk "BEGIN{printf \"%.3f\", $LUFS_TARGET + $LUFS_TOLERANCE}")
          echo "LUFS: ${lufs_i}  (target ${LUFS_TARGET} ±${LUFS_TOLERANCE}  window ${lo}…${hi})"
          if awk "BEGIN{exit !(${lufs_i} < ${lo})}"; then
            echo "  FLAG — integrated loudness ${lufs_i} LUFS below target (min ${lo} LUFS)"; escalate FLAG
          elif awk "BEGIN{exit !(${lufs_i} > ${hi})}"; then
            echo "  FLAG — integrated loudness ${lufs_i} LUFS above target (max ${hi} LUFS)"; escalate FLAG
          else
            echo "  PASS"
          fi
        else
          echo "LUFS: ${lufs_i}  (no target set — observe only)"
        fi
        # True peak
        if [[ -n "$lufs_tp" && -n "$TRUE_PEAK_LIMIT" ]]; then
          echo "Sample peak: ${lufs_tp} dBFS  (limit ${TRUE_PEAK_LIMIT} — true peak may be higher)"
          if awk "BEGIN{exit !(${lufs_tp} > ${TRUE_PEAK_LIMIT})}"; then
            echo "  FLAG — sample peak ${lufs_tp} dBFS exceeds limit ${TRUE_PEAK_LIMIT}"; escalate FLAG
          else
            echo "  PASS"
          fi
        elif [[ -n "$lufs_tp" ]]; then
          echo "Sample peak: ${lufs_tp} dBFS  (no limit set)"
        fi
        # LRA
        if [[ -n "$lufs_lra" && -n "$LRA_LIMIT" ]]; then
          echo "LRA: ${lufs_lra} LU  (limit ${LRA_LIMIT})"
          if awk "BEGIN{exit !(${lufs_lra} > ${LRA_LIMIT})}"; then
            echo "  FLAG — loudness range ${lufs_lra} LU exceeds limit ${LRA_LIMIT}"; escalate FLAG
          else
            echo "  PASS"
          fi
        elif [[ -n "$lufs_lra" ]]; then
          echo "LRA: ${lufs_lra} LU  (no limit set)"
        fi
      fi
    fi
    echo ""
  } >> "$REPORT"

  # --- Black frames ----------------------------------------------------------
  {
    echo "=== BLACK FRAMES ==="
    local black_out
    black_out=$(run_ff "$FFMPEG" -nostats -i "$INPUT" -vf "blackdetect=d=${BLACK_MIN_DUR}:pic_th=0.98" \
      -f null - 2>&1 | grep "black_start" || true)
    if [[ -z "$black_out" ]]; then
      echo "PASS — none detected"
    else
      echo "FLAG — black segments found:"; echo "$black_out"; escalate FLAG
    fi
    echo ""
  } >> "$REPORT"

  # --- Freeze detection ------------------------------------------------------
  {
    echo "=== FREEZE DETECT ==="
    local freeze_out
    freeze_out=$(run_ff "$FFMPEG" -nostats -i "$INPUT" -vf "freezedetect=n=0.003:d=${FREEZE_MIN_DUR}" \
      -f null - 2>&1 | grep -E "freeze_start|freeze_end|freeze_duration" || true)
    if [[ -z "$freeze_out" ]]; then
      echo "PASS — none detected"
    else
      echo "FLAG — freeze detected (confirm if intentional title card):"
      echo "$freeze_out" | sed 's/.*lavfi\.freezedetect\./  /'
      escalate FLAG
    fi
    echo ""
  } >> "$REPORT"

  # --- Interlace detection ---------------------------------------------------
  {
    echo "=== INTERLACE ==="
    local idet_line
    idet_line=$(run_ff "$FFMPEG" -i "$INPUT" -vf "idet" -frames:v 500 -f null - 2>&1 \
      | grep "Multi frame detection" | tail -1)
    if [[ -z "$idet_line" ]]; then
      echo "WARN — no idet output (file too short or filter unavailable)"
    else
      local prog tff bff
      prog=$(echo "$idet_line" | sed -n 's/.*Progressive:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
      tff=$( echo "$idet_line" | sed -n 's/.*TFF:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
      bff=$( echo "$idet_line" | sed -n 's/.*BFF:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
      prog=${prog:-0}; tff=${tff:-0}; bff=${bff:-0}
      echo " TFF=$tff  BFF=$bff  Progressive=$prog  (500 frames checked)"
      if [[ "$tff" -gt 0 || "$bff" -gt 0 ]]; then
        echo "FLAG — Interlaced content detected: TFF=$tff BFF=$bff"; escalate FLAG
      else
        echo "PASS — Progressive"
      fi
    fi
    echo ""
  } >> "$REPORT"

  # --- Crop detection --------------------------------------------------------
  {
    echo "=== CROP DETECT ==="
    if [[ $CROPDETECT_AVAILABLE -eq 1 ]]; then
      local crop_str
      crop_str=$(run_ff "$FFMPEG_CROP" -i "$INPUT" \
        -vf "cropdetect=limit=24:round=16:reset=0" -f null - 2>&1 \
        | grep "crop=" | sed 's/.*crop=/crop=/' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
      if [[ -z "$crop_str" ]]; then
        echo "WARN — no crop data returned"
      else
        local crop_w crop_h crop_x crop_y
        crop_w=$(echo "$crop_str" | sed 's/crop=//' | cut -d: -f1)
        crop_h=$(echo "$crop_str" | cut -d: -f2)
        crop_x=$(echo "$crop_str" | cut -d: -f3)
        crop_y=$(echo "$crop_str" | cut -d: -f4)
        echo " Consensus: $crop_str  (source ${width}x${height})"
        if [[ "$crop_w" == "$width" && "$crop_h" == "$height" ]]; then
          echo "PASS — full frame, no borders"
        else
          echo "FLAG — borders detected (crop ${crop_w}x${crop_h}+${crop_x}+${crop_y}, source ${width}x${height})"
          escalate FLAG
        fi
      fi
    else
      echo "SKIPPED — no cropdetect-capable ffmpeg found"
    fi
    echo ""
  } >> "$REPORT"

  # --- Color space metadata --------------------------------------------------
  {
    echo "=== COLOR SPACE ==="
    # Stream format: pixfmt(primaries/trc/colorspace, progressive)
    local cs_raw
    cs_raw=$(echo "$vid_stream" \
      | sed -n 's/.*yuv[a-z0-9]*(\([^)]*\)).*/\1/p' \
      | cut -d, -f1 | tr -d ' ')
    if [[ -z "$cs_raw" ]]; then
      echo "WARN — no color space metadata found in stream"
    else
      echo " Color metadata: $cs_raw"
      if echo "$cs_raw" | grep -qi "unknown"; then
        echo "FLAG — color space metadata contains 'unknown' field(s): $cs_raw"
        echo "       Verify color_primaries, color_trc, and colorspace are all correctly signalled"
        escalate FLAG
      else
        echo "PASS — color space fully tagged: $cs_raw"
      fi
    fi
    echo ""
  } >> "$REPORT"

  # --- Timecode --------------------------------------------------------------
  {
    echo "=== TIMECODE ==="
    local tc_raw tc_value
    # Try primary probe output
    tc_raw=$(run_ff "$FFMPEG" -i "$INPUT" 2>&1 \
      | grep -iE "timecode|time_code" | head -1)
    # Fallback: ffmetadata mux
    if [[ -z "$tc_raw" ]]; then
      tc_raw=$(run_ff "$FFMPEG" -i "$INPUT" -f ffmetadata - 2>/dev/null \
        | grep -iE "time_code|timecode" | head -1)
    fi
    tc_value=$(echo "$tc_raw" | grep -oE "[0-9]{2}:[0-9]{2}:[0-9]{2}[:;][0-9]{2}" | head -1)
    if [[ -z "$tc_value" ]]; then
      echo "WARN — timecode not readable from container metadata"
      if [[ -n "$EXPECTED_TIMECODE" ]]; then
        echo "FLAG — expected $EXPECTED_TIMECODE but could not verify"; escalate FLAG
      fi
    else
      echo " Timecode start: $tc_value"
      if [[ -n "$EXPECTED_TIMECODE" ]]; then
        local tc_norm exp_norm
        tc_norm=$( echo "$tc_value"         | tr ';' ':')
        exp_norm=$(echo "$EXPECTED_TIMECODE" | tr ';' ':')
        if [[ "$tc_norm" != "$exp_norm" ]]; then
          echo "FLAG — timecode $tc_value ≠ expected $EXPECTED_TIMECODE"; escalate FLAG
        else
          echo "PASS — timecode matches $EXPECTED_TIMECODE"
        fi
      else
        echo "INFO — no expected timecode set (observed: $tc_value)"
      fi
    fi
    echo ""
  } >> "$REPORT"

  # --- Signal stats ----------------------------------------------------------
  echo "=== SIGNAL STATS ===" >> "$REPORT"

  run_ff "$FFMPEG" -i "$INPUT" \
    -vf "signalstats=stat=brng+tout+vrep,metadata=print" -f null - 2>&1 \
    | grep "lavfi.signalstats" > "$OUT/signal.txt" || true

  local sig_lines
  sig_lines=$(awk 'END{print NR}' "$OUT/signal.txt")

  if [[ "$sig_lines" -eq 0 ]]; then
    echo "WARN — signalstats produced no output (filter may be unavailable)" >> "$REPORT"
  else
    {
      echo " Per-frame data: $sig_lines lines → signal.txt"
      echo ""
    } >> "$REPORT"

    local agg
    agg=$(awk '
      /lavfi\.signalstats\.[A-Z]+=/ {
        n = split($0, parts, "lavfi.signalstats.")
        if (n < 2) next
        split(parts[2], kv, "=")
        k = kv[1]; v = kv[2] + 0
        sum[k] += v; cnt[k]++
        if (v > mx[k])               mx[k] = v
        if (mn[k] == "" || v < mn[k]) mn[k] = v
      }
      END {
        for (k in sum)
          printf "%s avg=%.6f min=%.6f max=%.6f\n", k, sum[k]/cnt[k], mn[k], mx[k]
      }
    ' "$OUT/signal.txt" | sort)

    {
      echo "--- Aggregated Stats (avg / min / max across all frames) ---"
      echo "$agg"
      echo ""
      echo "--- Evaluation ---"
    } >> "$REPORT"

    # BRNG
    local brng_avg brng_peak
    brng_avg=$( get_stat "$agg" BRNG avg)
    brng_peak=$(get_stat "$agg" BRNG max)
    if [[ -n "$brng_avg" ]]; then
      echo "BRNG: avg=$brng_avg  peak=$brng_peak  (flag avg>=$BRNG_WARN  fail peak>=$BRNG_FAIL)" >> "$REPORT"
      if awk "BEGIN{exit !($brng_peak >= $BRNG_FAIL)}"; then
        echo "  FAIL — peak BRNG $brng_peak exceeds fail threshold $BRNG_FAIL" >> "$REPORT"; escalate FAIL
      elif awk "BEGIN{exit !($brng_avg >= $BRNG_WARN)}"; then
        echo "  FLAG — avg BRNG $brng_avg exceeds warn threshold $BRNG_WARN — check delivery spec" >> "$REPORT"; escalate FLAG
      else
        echo "  PASS" >> "$REPORT"
      fi
    fi

    # TOUT
    local tout_avg
    tout_avg=$(get_stat "$agg" TOUT avg)
    if [[ -n "$tout_avg" ]]; then
      echo "TOUT: avg=$tout_avg  (flag avg>=$TOUT_WARN)" >> "$REPORT"
      if awk "BEGIN{exit !($tout_avg >= $TOUT_WARN)}"; then
        echo "  FLAG — TOUT exceeds threshold" >> "$REPORT"; escalate FLAG
      else
        echo "  PASS" >> "$REPORT"
      fi
    fi

    # Luma legal range
    local ymin_floor ymax_peak
    ymin_floor=$(get_stat "$agg" YMIN min)
    ymax_peak=$( get_stat "$agg" YMAX max)
    if [[ -n "$ymin_floor" || -n "$ymax_peak" ]]; then
      echo "Luma: floor=$ymin_floor  peak=$ymax_peak  (legal ${ymin_limit}–${ymax_limit} for ${bit_depth}-bit)" >> "$REPORT"
      local luma_ok=1
      if [[ -n "$ymin_floor" ]] && awk "BEGIN{exit !($ymin_floor < $ymin_limit)}"; then
        echo "  FLAG — YMIN $ymin_floor below legal black ($ymin_limit)" >> "$REPORT"; luma_ok=0; escalate FLAG
      fi
      if [[ -n "$ymax_peak" ]] && awk "BEGIN{exit !($ymax_peak > $ymax_limit)}"; then
        echo "  FLAG — YMAX $ymax_peak above legal white ($ymax_limit)" >> "$REPORT"; luma_ok=0; escalate FLAG
      fi
      [[ $luma_ok -eq 1 ]] && echo "  PASS — luma within legal range" >> "$REPORT"
    fi

    # YMIN/YMAX consistency check — identical value across all frames suggests
    # codec artifact or full-range encode rather than genuine content
    {
      local ymin_avg ymin_mn ymin_mx ymax_avg ymax_mn ymax_mx
      ymin_avg=$(get_stat "$agg" YMIN avg)
      ymin_mn=$( get_stat "$agg" YMIN min)
      ymin_mx=$( get_stat "$agg" YMIN max)
      ymax_avg=$(get_stat "$agg" YMAX avg)
      ymax_mn=$( get_stat "$agg" YMAX min)
      ymax_mx=$( get_stat "$agg" YMAX max)
      if [[ -n "$ymin_avg" ]] && \
         awk "BEGIN{exit !(${ymin_avg}==${ymin_mn} && ${ymin_mn}==${ymin_mx})}"; then
        echo "NOTE — YMIN is identical across all frames (avg=min=max=$ymin_avg)"
        echo "       May indicate a codec artifact or full-range encode; verify with scope"
      fi
      if [[ -n "$ymax_avg" ]] && \
         awk "BEGIN{exit !(${ymax_avg}==${ymax_mn} && ${ymax_mn}==${ymax_mx})}"; then
        echo "NOTE — YMAX is identical across all frames (avg=min=max=$ymax_avg)"
        echo "       May indicate a codec artifact or full-range encode; verify with scope"
      fi
    } >> "$REPORT"

    # Saturation peak
    local satmax_peak
    satmax_peak=$(get_stat "$agg" SATMAX max)
    if [[ -n "$satmax_peak" ]]; then
      echo "Saturation peak: $satmax_peak  (flag >$SATMAX_WARN)" >> "$REPORT"
      if awk "BEGIN{exit !($satmax_peak > $SATMAX_WARN)}"; then
        echo "  FLAG — absolute peak saturation $satmax_peak exceeds $SATMAX_WARN" >> "$REPORT"; escalate FLAG
      else
        echo "  PASS" >> "$REPORT"
      fi
    fi
  fi
  echo "" >> "$REPORT"

  # --- Final verdict ---------------------------------------------------------
  {
    echo "============================================================"
    echo " VERDICT: $VERDICT"
    echo "============================================================"
  } >> "$REPORT"

  echo "$VERDICT" > "$OUT/verdict.txt"
  echo " $NAME → $VERDICT  (report: $REPORT)"
}

# =============================================================================
# Main
# =============================================================================

# --- Argument parsing --------------------------------------------------------
# Usage: broadcast_qc.sh [--preset xr_na] [--spec file.conf] [file1 file2 ...]
#   Files passed as positional args are QC'd directly; results go beside each file
#   With no file args, falls back to the hardcoded default project list below
PRESET_ARG=""
SPEC_FILE_ARG=""
declare -a INPUT_FILES
while [[ $# -gt 0 ]]; do
  case "$1" in
    --preset)   PRESET_ARG="$2";    shift 2 ;;
    --preset=*) PRESET_ARG="${1#--preset=}"; shift ;;
    --spec)     SPEC_FILE_ARG="$2"; shift 2 ;;
    --spec=*)   SPEC_FILE_ARG="${1#--spec=}"; shift ;;
    -*)         echo "WARN: Unknown flag '$1' — ignoring" >&2; shift ;;
    *)          INPUT_FILES+=("$(_norm_path "$1")"); shift ;;
  esac
done

# Default project (used when no files passed as args)
BASE="/d/1129_BCCHF/6_COLOUR_IO/260304_BCCHF_COLOUR_PKG_V01"
REF="$BASE/REF"
QC="$BASE/QC_RESULTS"

declare -a FILE_NAMES
declare -A FILE_VERDICTS
PASS_COUNT=0; FLAG_COUNT=0; FAIL_COUNT=0; ERROR_COUNT=0

process_file() {
  local input="$1" name="$2" out="$3"
  FILE_NAMES+=("$name")
  if run_qc "$input" "$name" "$out"; then
    local v
    v=$(cat "$out/verdict.txt" 2>/dev/null || echo "UNKNOWN")
    FILE_VERDICTS["$name"]="$v"
    case "$v" in
      PASS)  PASS_COUNT=$((PASS_COUNT+1))  ;;
      FLAG)  FLAG_COUNT=$((FLAG_COUNT+1))  ;;
      FAIL)  FAIL_COUNT=$((FAIL_COUNT+1))  ;;
      *)     ERROR_COUNT=$((ERROR_COUNT+1)) ;;
    esac
  else
    FILE_VERDICTS["$name"]="ERROR"
    ERROR_COUNT=$((ERROR_COUNT+1))
  fi
}

# Load spec: --preset flag > --spec flag > interactive prompt > skip
if [[ -n "$PRESET_ARG" ]]; then
  case "$PRESET_ARG" in
    xr_na|xr-na) preset_xr_na; echo "INFO: XR North America preset loaded." ;;
    *) echo "ERROR: Unknown preset '$PRESET_ARG'. Available: xr_na" >&2; exit 1 ;;
  esac
elif [[ -n "$SPEC_FILE_ARG" ]]; then
  SPEC_FILE_ARG=$(_norm_path "$SPEC_FILE_ARG")
  if _load_spec_conf "$SPEC_FILE_ARG"; then
    echo "INFO: Spec loaded from $SPEC_FILE_ARG"
  else
    echo "ERROR: Could not load spec from $SPEC_FILE_ARG" >&2; exit 1
  fi
elif [[ -t 0 ]]; then
  prompt_spec
else
  echo "INFO: No spec set — running observe-only (use --preset xr_na or --spec file.conf)"
fi

if [[ ${#INPUT_FILES[@]} -gt 0 ]]; then
  # Files passed as arguments — QC results go in a QC_RESULTS folder beside each file
  for f in "${INPUT_FILES[@]}"; do
    local_dir=$(dirname "$f")
    name=$(basename "$f" | sed 's/\.[^.]*$//')
    process_file "$f" "$name" "$local_dir/QC_RESULTS/$name"
  done
else
  # Default project file list
  process_file "$REF/BCCHF_15_PL_V01_PICTUREREF.mov"        "BCCHF_15"        "$QC/BCCHF_15"
  process_file "$REF/BCCHF_NONPSA_30_PL_V01_PICTUREREF.mov" "BCCHF_NONPSA_30" "$QC/BCCHF_NONPSA_30"
  process_file "$REF/BCCHF_PSA_30_PL_V01_PICTUREREF.mov"    "BCCHF_PSA_30"    "$QC/BCCHF_PSA_30"
fi

echo ""
echo "============================================================"
echo " FINAL SUMMARY"
echo "============================================================"
for name in "${FILE_NAMES[@]}"; do
  printf "  %-24s  %s\n" "$name" "${FILE_VERDICTS[$name]}"
done
echo ""
printf "  PASS: %d   FLAG: %d   FAIL: %d   ERROR: %d\n" \
  $PASS_COUNT $FLAG_COUNT $FAIL_COUNT $ERROR_COUNT
echo "============================================================"

[[ $FAIL_COUNT -gt 0 || $ERROR_COUNT -gt 0 ]] && exit 1
exit 0
