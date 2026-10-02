#!/usr/bin/env bash
# ~/.claude/statusline.sh
# Claude Code status line: identity/git, context+cost, 5h/7d limits, live subagents.
# Deps: jq, git. Bash 3.2 compatible (macOS stock bash).

input=$(cat)

# ---------------- one jq pass, one field per line ----------------
{
  read -r MODEL;  read -r DIR;    read -r PCT;    read -r TOK
  read -r CTXMAX; read -r COST;   read -r CENTS;  read -r DUR_MS
  read -r EFFORT; read -r ADD;    read -r DEL
  read -r H5;     read -r H5R;    read -r D7;     read -r D7R
  read -r SPL;    read -r SPLR;   read -r SID;    read -r PRNUM; read -r PRSTATE
} < <(printf '%s' "$input" | jq -r '
  [ (.model.display_name // "?"),
    (.workspace.current_dir // "."),
    ((.context_window.used_percentage // 0) | floor),
    ((.context_window.total_input_tokens // 0) | floor),
    ((.context_window.context_window_size // 200000) | floor),
    (.cost.total_cost_usd // 0),
    (((.cost.total_cost_usd // 0) * 100) | floor),
    ((.cost.total_duration_ms // 0) | floor),
    (.effort.level // ""),
    (.cost.total_lines_added // 0),
    (.cost.total_lines_removed // 0),
    ((.rate_limits.five_hour.used_percentage   // -1) | floor),
    ((.rate_limits.five_hour.resets_at         //  0) | floor),
    ((.rate_limits.seven_day.used_percentage   // -1) | floor),
    ((.rate_limits.seven_day.resets_at         //  0) | floor),
    ((.rate_limits.spend_limit.used_percentage // -1) | floor),
    ((.rate_limits.spend_limit.resets_at       //  0) | floor),
    (.session_id // "nosession"),
    (.pr.number // ""),
    (.pr.review_state // "")
  ] | .[] | tostring')

NOW=$(date +%s)
TMP="${TMPDIR:-/tmp}"

# ---------------- palette ----------------
c()   { printf '\033[38;5;%sm' "$1"; }
DIM=$(c 245);  MDL=$(c 110);  DR=$(c 180);  BRC=$(c 140)
GRN=$(c 114);  YEL=$(c 221);  ORG=$(c 179);  RED=$(c 174)
CYN=$(c 109);  RST=$'\033[0m'
SEP="${DIM}│${RST}"

# 4-tier threshold colour
tone() {
  if   [ "$1" -ge 90 ]; then printf '%s' "$RED"
  elif [ "$1" -ge 75 ]; then printf '%s' "$ORG"
  elif [ "$1" -ge 50 ]; then printf '%s' "$YEL"
  else                       printf '%s' "$GRN"; fi
}

# bar PCT WIDTH
bar() {
  local p=$1 w=$2 f e t
  f=$(( p * w / 100 )); [ "$f" -gt "$w" ] && f=$w; [ "$f" -lt 0 ] && f=0
  e=$(( w - f )); t=""
  [ "$f" -gt 0 ] && printf -v BSEG "%${f}s" && t="${BSEG// /█}"
  [ "$e" -gt 0 ] && printf -v BSEG "%${e}s" && t="${t}${BSEG// /░}"
  printf '%s' "$t"
}

# humanised token count
kfmt() {
  if   [ "$1" -ge 1000000 ]; then printf '%d.%dM' $(( $1 / 1000000 )) $(( ($1 % 1000000) / 100000 ))
  elif [ "$1" -ge 1000 ];    then printf '%dk'    $(( $1 / 1000 ))
  else                            printf '%d'     "$1"; fi
}

# countdown to an epoch timestamp
eta() {
  local d=$(( $1 - NOW ))
  [ "$d" -le 0 ] && { printf 'now'; return; }
  if   [ "$d" -ge 86400 ]; then printf '%dd%dh'  $(( d / 86400 )) $(( (d % 86400) / 3600 ))
  elif [ "$d" -ge 3600 ];  then printf '%dh%02dm' $(( d / 3600 ))  $(( (d % 3600) / 60 ))
  else                          printf '%dm'      $(( d / 60 )); fi
}

# ---------------- widths ----------------
COLS=${COLUMNS:-120}
if   [ "$COLS" -ge 130 ]; then BW=16; LW=10
elif [ "$COLS" -ge 100 ]; then BW=12; LW=8
else                           BW=8;  LW=6; fi

# ---------------- git, cached 3s per session ----------------
GCACHE="$TMP/cc-statusline-$SID"
GMT=$(stat -c %Y "$GCACHE" 2>/dev/null || stat -f %m "$GCACHE" 2>/dev/null || echo 0)
if [ ! -f "$GCACHE" ] || [ $(( NOW - GMT )) -ge 3 ]; then
  if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
    BR=$(git -C "$DIR" branch --show-current 2>/dev/null)
    [ -z "$BR" ] && BR=$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null)
    ST=$(git -C "$DIR" diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
    MD=$(git -C "$DIR" diff --numstat 2>/dev/null | wc -l | tr -d ' ')
    UN=$(git -C "$DIR" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
    read -r BH AH <<< "$(git -C "$DIR" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null)"
    printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$BR" "$ST" "$MD" "$UN" "${BH:-0}" "${AH:-0}" > "$GCACHE"
  else
    printf '\n0\n0\n0\n0\n0\n' > "$GCACHE"
  fi
fi
{ read -r BR; read -r ST; read -r MD; read -r UN; read -r BH; read -r AH; } < "$GCACHE"

# ============ LINE 1 — model : effort | dir | git | PR ============
L1="${MDL}${MODEL}${RST}"
[ -n "$EFFORT" ] && L1="${L1}${DIM}:${EFFORT}${RST}"
L1="${L1} ${SEP} ${DR}${DIR##*/}${RST}"
if [ -n "$BR" ]; then
  G="${BRC}${BR}${RST}"
  [ "${ST:-0}" -gt 0 ] && G="${G} ${GRN}+${ST}${RST}"
  [ "${MD:-0}" -gt 0 ] && G="${G} ${ORG}~${MD}${RST}"
  [ "${UN:-0}" -gt 0 ] && G="${G} ${DIM}?${UN}${RST}"
  [ "${AH:-0}" -gt 0 ] && G="${G} ${CYN}^${AH}${RST}"
  [ "${BH:-0}" -gt 0 ] && G="${G} ${RED}v${BH}${RST}"
  L1="${L1} ${SEP} ${G}"
fi
if [ -n "$PRNUM" ]; then
  case "$PRSTATE" in
    approved)          PC="$GRN" ;;
    changes_requested) PC="$RED" ;;
    draft)             PC="$DIM" ;;
    *)                 PC="$YEL" ;;
  esac
  L1="${L1} ${SEP} ${PC}PR#${PRNUM}${RST}"
fi

# ============ LINE 2 — context | cost | elapsed | diff ============
CT=$(tone "$PCT")
L2="${DIM}ctx${RST} ${CT}$(bar "$PCT" "$BW")${RST} ${CT}${PCT}%${RST} ${DIM}$(kfmt "$TOK")/$(kfmt "$CTXMAX")${RST}"

if   [ "$CENTS" -ge 2000 ]; then CC="$RED"
elif [ "$CENTS" -ge 500 ];  then CC="$ORG"
elif [ "$CENTS" -ge 100 ];  then CC="$YEL"
else                             CC="$GRN"; fi
L2="${L2} ${SEP} ${CC}$(printf '$%.2f' "$COST")${RST}"

S=$(( DUR_MS / 1000 )); HH=$(( S / 3600 )); MM=$(( (S % 3600) / 60 )); SS=$(( S % 60 ))
if [ "$HH" -gt 0 ]; then EL=$(printf '%dh%02dm' "$HH" "$MM"); else EL=$(printf '%dm%02ds' "$MM" "$SS"); fi
L2="${L2} ${SEP} ${DIM}${EL}${RST}"

if [ "${ADD:-0}" -gt 0 ] || [ "${DEL:-0}" -gt 0 ]; then
  L2="${L2} ${SEP} ${GRN}+${ADD}${RST}${DIM}/${RST}${RED}-${DEL}${RST}"
fi

# ============ LINE 3 — 5h session limit | 7d weekly limit | spend ============
L3=""
if [ "$H5" -ge 0 ]; then
  T=$(tone "$H5")
  L3="${DIM}5h${RST} ${T}$(bar "$H5" "$LW")${RST} ${T}${H5}%${RST}"
  [ "$H5R" -gt 0 ] && L3="${L3} ${DIM}↺$(eta "$H5R")${RST}"
fi
if [ "$D7" -ge 0 ]; then
  T=$(tone "$D7")
  [ -n "$L3" ] && L3="${L3} ${SEP} "
  L3="${L3}${DIM}7d${RST} ${T}$(bar "$D7" "$LW")${RST} ${T}${D7}%${RST}"
  [ "$D7R" -gt 0 ] && L3="${L3} ${DIM}↺$(eta "$D7R")${RST}"
fi
if [ "$SPL" -ge 0 ]; then
  T=$(tone "$SPL")
  [ -n "$L3" ] && L3="${L3} ${SEP} "
  L3="${L3}${DIM}spend${RST} ${T}${SPL}%${RST}"
  [ "$SPLR" -gt 0 ] && L3="${L3} ${DIM}↺$(eta "$SPLR")${RST}"
fi

# ============ LINE 4 — live subagents (written by subagent-statusline.sh) ============
L4=""
ACACHE="$TMP/cc-agents-$SID"
if [ -f "$ACACHE" ]; then
  AMT=$(stat -c %Y "$ACACHE" 2>/dev/null || stat -f %m "$ACACHE" 2>/dev/null || echo 0)
  if [ $(( NOW - AMT )) -le 20 ]; then
    { read -r ACOUNT; read -r ASEG; } < "$ACACHE"
    [ "${ACOUNT:-0}" -gt 0 ] && L4="$ASEG"
  fi
fi

# ---------------- emit (drop a line by deleting its printf) ----------------
printf '%s\n' "$L1"
printf '%s\n' "$L2"
[ -n "$L3" ] && printf '%s\n' "$L3"
[ -n "$L4" ] && printf '%s\n' "$L4"
exit 0
