#!/bin/bash
# ~/.claude/statusline.sh — Claude Code status line
#
#   1  identity  model:effort ⚡ │ dir │ git │ worktree │ PR │ agent │ session
#   2  session   context bar │ prompt cache │ ~cost │ active time │ churn │ compactions
#   3  limits    5h │ 7d │ spend  (bars, ⏲ reset countdown, pace projection)
#   4  agents    live subagents (written by ~/.claude/subagent-statusline.sh)
#   5  warnings  only when something needs attention
#
# Every line is fitted to $COLUMNS by dropping its least important segments.
# Data is local only: stdin JSON, one cached git call, the session transcript.
# Helpers return through globals, never $(...): each subshell costs a fork,
# and forks are what make status lines slow. Deps: jq, git. Bash 3.2 compatible.

export LC_ALL=en_US.UTF-8      # ${#str} must count characters, not bytes
IFS= read -r -d '' input

# ---------------- config ----------------
TONE_YEL=50; TONE_ORG=75; TONE_RED=90       # % thresholds for context and limits
COST_YEL=100; COST_ORG=500; COST_RED=2000   # cents
GIT_TTL=3                                   # seconds between git refreshes
RECACHE_WARN=20000                          # tokens; warn when a cold cache costs more
PAD=4                                       # columns Claude Code keeps around the line

# ---------------- one jq pass, one field per line ----------------
{
  read -r NOW
  read -r MODEL;   read -r MODEL_ID; read -r CWD;    read -r PROJ;   read -r ADDED
  read -r WT;      read -r SNAME;    read -r EFFORT; read -r FAST;   read -r VIM
  read -r AGENT;   read -r STYLE
  read -r PCT;     read -r TOK;      read -r CTXMAX
  read -r COST;    read -r CENTS;    read -r DUR_MS; read -r API_MS; read -r ADD; read -r DEL
  read -r H5;      read -r H5R;      read -r D7;     read -r D7R;    read -r SPL; read -r SPLR
  read -r PC_ON;   read -r PC_WARM;  read -r PC_TTL; read -r PC_EXP; read -r PC_HIT
  read -r PC_MISS; read -r PC_RECOLD
  read -r SID;     read -r PRNUM;    read -r PRSTATE; read -r PRKIND; read -r TRANSCRIPT
} < <(jq -r '
  def s: if . == null then "" else tostring | gsub("[\n\r\t\u001b\u0007]"; " ") end;
  def i($d): if type == "number" then floor else $d end;
  [ (now | floor),
    (.model.display_name // "?"), (.model.id // ""),
    (.workspace.current_dir // .cwd // "."), (.workspace.project_dir // ""),
    ((.workspace.added_dirs // []) | length),
    (.worktree.name // .workspace.git_worktree // ""),
    (.session_name // ""),
    (.effort.level // ""), (.fast_mode // false),
    (.vim.mode // ""), (.agent.name // ""), (.output_style.name // "default"),
    (.context_window.used_percentage | i(-1)),
    (.context_window.total_input_tokens | i(0)),
    (.context_window.context_window_size | i(200000)),
    (.cost.total_cost_usd // 0), ((.cost.total_cost_usd // 0) * 100 | floor),
    (.cost.total_duration_ms | i(0)), (.cost.total_api_duration_ms | i(0)),
    (.cost.total_lines_added | i(0)), (.cost.total_lines_removed | i(0)),
    (.rate_limits.five_hour.used_percentage   | i(-1)), (.rate_limits.five_hour.resets_at   | i(0)),
    (.rate_limits.seven_day.used_percentage   | i(-1)), (.rate_limits.seven_day.resets_at   | i(0)),
    (.rate_limits.spend_limit.used_percentage | i(-1)), (.rate_limits.spend_limit.resets_at | i(0)),
    (if .prompt_cache.caching_observed == true then 1 else 0 end),
    (if .prompt_cache.warm == true then 1 else 0 end),
    (.prompt_cache.ttl // ""), (.prompt_cache.expires_at | i(0)),
    (if (.prompt_cache.hit_ratio | type) == "number" then (.prompt_cache.hit_ratio * 100 | floor) else -1 end),
    (.prompt_cache.misses | i(0)), (.prompt_cache.recache_tokens_if_cold | i(0)),
    (.session_id // "nosession"), (.pr.number // ""), (.pr.review_state // ""), (.pr.kind // ""),
    (.transcript_path // "")
  ] | .[] | s' <<< "$input" 2>/dev/null)

# Bad or missing input must never break the layout
int() { [[ ${!1} =~ ^-?[0-9]+$ ]] || printf -v "$1" '%s' "$2"; }
for v in ADDED TOK DUR_MS API_MS ADD DEL H5R D7R SPLR PC_ON PC_WARM PC_EXP \
         PC_MISS PC_RECOLD CENTS; do int "$v" 0; done
for v in PCT H5 D7 SPL PC_HIT; do int "$v" -1; done
int CTXMAX 200000
[[ $NOW =~ ^[0-9]+$ ]] || NOW=$(date +%s)
[[ $COST =~ ^[0-9.eE+-]+$ ]] || COST=0
[ -n "$MODEL" ] || MODEL="?"
[ -n "$CWD" ]   || CWD="."
SID=${SID//[^A-Za-z0-9_-]/}; [ -n "$SID" ] || SID=nosession

TMP="${TMPDIR:-/tmp}"; TMP="${TMP%/}"
COLS=${COLUMNS:-0}; int COLS 0; [ "$COLS" -ge 40 ] || COLS=120
MAXW=$(( COLS - PAD ))

# ---------------- palette (256-colour) ----------------
E=$'\033['
DIM="${E}38;5;245m"; FG="${E}38;5;252m"; GRN="${E}38;5;114m"; YEL="${E}38;5;221m"
ORG="${E}38;5;208m"; RED="${E}38;5;203m"; CYN="${E}38;5;109m"; BLU="${E}38;5;110m"
MAG="${E}38;5;176m"; TAN="${E}38;5;180m"; PUR="${E}38;5;140m"
BOLD="${E}1m"; RST="${E}0m"
SEP=" ${DIM}│${RST} "

# ---------------- helpers (results in globals) ----------------
# tone PCT → TN   (higher is worse: context, limits)
tone() {
  if   [ "$1" -ge "$TONE_RED" ]; then TN=$RED
  elif [ "$1" -ge "$TONE_ORG" ]; then TN=$ORG
  elif [ "$1" -ge "$TONE_YEL" ]; then TN=$YEL
  else                                TN=$GRN; fi
}

# tone_up PCT → TU   (higher is better: cache hit ratio)
tone_up() {
  if   [ "$1" -ge 80 ]; then TU=$GRN
  elif [ "$1" -ge 50 ]; then TU=$YEL
  else                       TU=$ORG; fi
}

# bar PCT WIDTH → BAR
bar() {
  local p=$1 w=$2 f e B
  BAR=""
  [ "$p" -lt 0 ] && p=0
  f=$(( p * w / 100 )); [ "$f" -gt "$w" ] && f=$w
  e=$(( w - f ))
  [ "$f" -gt 0 ] && { printf -v B "%${f}s" ""; BAR="${B// /█}"; }
  [ "$e" -gt 0 ] && { printf -v B "%${e}s" ""; BAR="${BAR}${B// /░}"; }
}

# kfmt N → K   (950 · 9.5k · 96k · 1M · 1.2M)
kfmt() {
  local n=$1 d
  if [ "$n" -ge 1000000 ]; then
    d=$(( n % 1000000 / 100000 ))
    if [ "$d" -eq 0 ]; then K="$(( n / 1000000 ))M"; else K="$(( n / 1000000 )).${d}M"; fi
  elif [ "$n" -ge 10000 ]; then K="$(( n / 1000 ))k"
  elif [ "$n" -ge 1000 ];  then K="$(( n / 1000 )).$(( n % 1000 / 100 ))k"
  else                          K="$n"; fi
}

# span SECS → SP   (3d4h · 2h10m · 48m · 1m25s · 30s)
span() {
  local d=$1
  [ "$d" -lt 0 ] && d=0
  if   [ "$d" -ge 86400 ]; then SP="$(( d / 86400 ))d$(( d % 86400 / 3600 ))h"
  elif [ "$d" -ge 3600 ];  then printf -v SP '%dh%02dm' $(( d / 3600 )) $(( d % 3600 / 60 ))
  elif [ "$d" -ge 600 ];   then SP="$(( d / 60 ))m"
  elif [ "$d" -ge 60 ];    then printf -v SP '%dm%02ds' $(( d / 60 )) $(( d % 60 ))
  else                          SP="${d}s"; fi
}

# plural N WORD SUFFIX → PL
plural() { if [ "$1" -eq 1 ]; then PL="$1 $2"; else PL="$1 $2$3"; fi; }

# ---------------- segment fitting ----------------
# add LINE PRIO TEXT — lower PRIO is more important and survives longer
add() { eval "L$1T+=(\"\$3\"); L$1P+=(\"\$2\")"; }

# vlen TEXT → VL   (visible width, colour codes stripped; plain slicing,
# because extglob patterns are pathologically slow in bash 3.2)
vlen() {
  local s=$1 out=""
  while [[ $s == *$'\033['* ]]; do
    out+=${s%%$'\033['*}
    s=${s#*$'\033['}
    s=${s#*m}
  done
  out+=$s
  VL=${#out}
}

# print line N, dropping its least important segments until it fits
render() {
  local -a T P
  eval "T=(\"\${L$1T[@]}\"); P=(\"\${L$1P[@]}\")"
  local n=${#T[@]} i total cnt worst wi out=""
  [ "$n" -eq 0 ] && return
  while :; do
    total=0; cnt=0
    for (( i = 0; i < n; i++ )); do
      [ -n "${T[i]}" ] || continue
      vlen "${T[i]}"; total=$(( total + VL )); cnt=$(( cnt + 1 ))
    done
    [ "$cnt" -eq 0 ] && return
    total=$(( total + (cnt - 1) * 3 ))
    if [ "$total" -le "$MAXW" ] || [ "$cnt" -le 1 ]; then break; fi
    worst=-1; wi=-1
    for (( i = 0; i < n; i++ )); do
      [ -n "${T[i]}" ] && [ "${P[i]}" -ge "$worst" ] && { worst=${P[i]}; wi=$i; }
    done
    T[wi]=""
  done
  for (( i = 0; i < n; i++ )); do
    [ -n "${T[i]}" ] || continue
    out="${out:+$out$SEP}${T[i]}"
  done
  printf '%s\n' "$out"
}

# bar widths scale with the terminal
if   [ "$COLS" -ge 160 ]; then BW=20
elif [ "$COLS" -ge 130 ]; then BW=16
elif [ "$COLS" -ge 100 ]; then BW=12
else                           BW=8; fi
LW=$BW   # limit bars match the context bar

# ---------------- git: one lock-free call, cached per session ----------------
# cache: refreshed-at, dir, branch, oid, staged, modified, untracked, conflicts, stash, ahead, behind
GCACHE="$TMP/cc-sl-git-$SID"
GAT=0 GDIR="" BR="" OID="" ST=0 MD=0 UN=0 CF=0 SH=0 AH=0 BH=0
[ -f "$GCACHE" ] && { read -r GAT; read -r GDIR; read -r BR; read -r OID; read -r ST; read -r MD
                      read -r UN;  read -r CF;   read -r SH; read -r AH;  read -r BH; } < "$GCACHE"
int GAT 0
if [ "$GDIR" != "$CWD" ] || [ $(( NOW - GAT )) -ge "$GIT_TTL" ]; then
  BR="" OID="" ST=0 MD=0 UN=0 CF=0 SH=0 AH=0 BH=0
  while IFS= read -r ln; do
    case "$ln" in
      "# branch.head "*) BR=${ln#\# branch.head } ;;
      "# branch.oid "*)  OID=${ln#\# branch.oid }; OID=${OID:0:7} ;;
      "# branch.ab "*)   ab=${ln#\# branch.ab +}; AH=${ab%% *}; BH=${ab##*-} ;;
      "# stash "*)       SH=${ln#\# stash } ;;
      [12]" "*)          [ "${ln:2:1}" != "." ] && ST=$(( ST + 1 ))
                         [ "${ln:3:1}" != "." ] && MD=$(( MD + 1 )) ;;
      "u "*)             CF=$(( CF + 1 )) ;;
      "? "*)             UN=$(( UN + 1 )) ;;
    esac
  done < <(git --no-optional-locks -C "$CWD" status --porcelain=v2 --branch --show-stash 2>/dev/null)
  [ "$BR" = "(detached)" ] && BR="@${OID}"
  printf '%s\n' "$NOW" "$CWD" "$BR" "$OID" "$ST" "$MD" "$UN" "$CF" "$SH" "$AH" "$BH" \
    > "$GCACHE.$$" 2>/dev/null && mv -f "$GCACHE.$$" "$GCACHE" 2>/dev/null
fi
for v in ST MD UN CF SH AH BH; do int "$v" 0; done

# ---------------- compactions: rescan the transcript only when it changed ----------------
CMP=0
if [ -f "$TRANSCRIPT" ]; then
  CCACHE="$TMP/cc-sl-cmp-$SID"
  if [ "$TRANSCRIPT" -nt "$CCACHE" ]; then
    CMP=$(/usr/bin/grep -c '"subtype":"compact_boundary"' "$TRANSCRIPT" 2>/dev/null)
    printf '%s\n' "${CMP:-0}" > "$CCACHE" 2>/dev/null
  else
    read -r CMP < "$CCACHE"
  fi
  int CMP 0
fi

# subscription users (rate limits present) pay a plan, not this list-price estimate
SUB=0
[ "$H5" -ge 0 ] || [ "$D7" -ge 0 ] || [ "$SPL" -ge 0 ] && SUB=1

# ═════════════ LINE 1 — identity, location, git ═════════════
case "$MODEL_ID $MODEL" in
  *[Oo]pus*)   MC=$MAG ;;
  *[Ff]able*)  MC=$CYN ;;
  *[Ss]onnet*) MC=$BLU ;;
  *[Hh]aiku*)  MC=$GRN ;;
  *)           MC=$FG ;;
esac
S="${MC}${BOLD}${MODEL}${RST}"
case "$EFFORT" in
  low)    S="${S}${DIM}:low${RST}" ;;
  medium) S="${S}${BLU}:medium${RST}" ;;
  high)   S="${S}${YEL}:high${RST}" ;;
  xhigh)  S="${S}${ORG}:xhigh${RST}" ;;
  max)    S="${S}${RED}:max${RST}" ;;
  ?*)     S="${S}${DIM}:${EFFORT}${RST}" ;;
esac
[ "$FAST" = "true" ] && S="${S} ${YEL}⚡${RST}"
add 1 0 "$S"

# directory: home-relative path, so a folder named "Claude" can't read as the app
D=$CWD
case "$D" in "$HOME") D="~" ;; "$HOME"/*) D="~/${D#"$HOME"/}" ;; esac
[ "${#D}" -gt 40 ] && D="…${D: -39}"
[ "$ADDED" -gt 0 ] && D="${D} ${DIM}+${ADDED}dir${RST}"
add 1 6 "${TAN}${D}${RST}"

if [ -n "$BR" ]; then
  [ "${#BR}" -gt 28 ] && BR="${BR:0:27}…"
  if [ $(( ST + MD + UN + CF )) -eq 0 ]; then G="${GRN}⎇ ${BR}${RST}"; else G="${PUR}⎇ ${BR}${RST}"; fi
  [ "$CF" -gt 0 ] && G="${G} ${RED}⚔${CF}${RST}"
  [ "$ST" -gt 0 ] && G="${G} ${GRN}+${ST}${RST}"
  [ "$MD" -gt 0 ] && G="${G} ${ORG}~${MD}${RST}"
  [ "$UN" -gt 0 ] && G="${G} ${DIM}?${UN}${RST}"
  [ "$SH" -gt 0 ] && G="${G} ${DIM}≡${SH}${RST}"
  [ "$AH" -gt 0 ] && G="${G} ${CYN}↑${AH}${RST}"
  [ "$BH" -gt 0 ] && G="${G} ${RED}↓${BH}${RST}"
  add 1 1 "$G"
fi

[ -n "$WT" ] && add 1 4 "${DIM}wt:${RST}${CYN}${WT}${RST}"

if [ -n "$PRNUM" ]; then
  if [ "$PRKIND" = "mr" ]; then PRL="!${PRNUM}"; else PRL="#${PRNUM}"; fi
  case "$PRSTATE" in
    approved)          P="${GRN}${PRL} ✓${RST}" ;;
    changes_requested) P="${RED}${PRL} ✗${RST}" ;;
    draft)             P="${DIM}${PRL} draft${RST}" ;;
    pending)           P="${YEL}${PRL} ◷${RST}" ;;
    *)                 P="${YEL}${PRL}${RST}" ;;
  esac
  add 1 3 "$P"
fi

[ -n "$VIM" ]   && add 1 2 "${BOLD}${VIM}${RST}"
[ -n "$AGENT" ] && add 1 5 "${YEL}@${AGENT}${RST}"
if [ -n "$SNAME" ]; then
  [ "${#SNAME}" -gt 60 ] && SNAME="${SNAME:0:59}…"
  add 1 8 "${DIM}“${SNAME}”${RST}"
fi
[ -n "$STYLE" ] && [ "$STYLE" != "default" ] && add 1 9 "${DIM}style:${STYLE}${RST}"

# ═════════════ LINE 2 — context, cache, cost, time ═════════════
kfmt "$CTXMAX"; KMAX=$K
if [ "$PCT" -ge 0 ]; then
  tone "$PCT"; bar "$PCT" "$BW"; kfmt "$TOK"
  add 2 0 "${DIM}ctx${RST} ${TN}${BAR} ${PCT}%${RST} ${DIM}${K}/${KMAX}${RST}"
else
  bar 0 "$BW"
  add 2 0 "${DIM}ctx ${BAR} —  0/${KMAX}${RST}"
fi

if [ "$PC_ON" -eq 1 ]; then
  if [ "$PC_WARM" -eq 1 ]; then CS="${GRN}●${RST}"; else CS="${DIM}○${RST}"; fi
  CS="${CS} ${DIM}cache${RST}"
  [ "$PC_HIT" -ge 0 ] && { tone_up "$PC_HIT"; CS="${CS} ${TU}${PC_HIT}%${RST}"; }
  if [ "$PC_WARM" -eq 1 ] && [ "$PC_EXP" -gt 0 ]; then
    LEFT=$(( PC_EXP - NOW )); span "$LEFT"
    if   [ "$LEFT" -lt 300 ]; then CT=$ORG
    elif [ "$LEFT" -lt 600 ]; then CT=$YEL
    else                           CT=$GRN; fi
    CS="${CS} ${DIM}cold in${RST} ${CT}${SP}${RST}"
  elif [ "$PC_WARM" -eq 0 ]; then
    CS="${CS} ${ORG}cold${RST}"
    [ "$PC_RECOLD" -gt 0 ] && { kfmt "$PC_RECOLD"; CS="${CS} ${DIM}(${K} to rebuild)${RST}"; }
  fi
  [ "$PC_MISS" -gt 0 ] && { plural "$PC_MISS" miss es; CS="${CS} ${DIM}${PL}${RST}"; }
  add 2 1 "$CS"
fi

# session cost: always "~" (Claude Code's list-price estimate); dimmed on a plan,
# where the usage limits are the real constraint
printf -v COSTS '~$%.2f' "$COST" 2>/dev/null || COSTS='~$?'
if [ "$SUB" -eq 1 ]; then CC=$DIM
elif [ "$CENTS" -ge "$COST_RED" ]; then CC=$RED
elif [ "$CENTS" -ge "$COST_ORG" ]; then CC=$ORG
elif [ "$CENTS" -ge "$COST_YEL" ]; then CC=$YEL
else                                    CC=$GRN; fi
add 2 2 "${CC}${COSTS}${RST}"

# active time: time Claude was working, not time the window was open
if [ "$API_MS" -gt 0 ]; then
  span $(( API_MS / 1000 ))
  add 2 6 "${DIM}⏱ ${SP} active${RST}"
fi

if [ "$ADD" -gt 0 ] || [ "$DEL" -gt 0 ]; then
  add 2 4 "${GRN}+${ADD}${RST}${DIM}/${RST}${RED}-${DEL}${RST}"
fi
[ "$CMP" -gt 0 ] && add 2 5 "${DIM}⟳${CMP}${RST}"

# ═════════════ LINE 3 — usage limits ═════════════
# pace WINDOW_SECS USED_PCT RESETS_AT → PACE = seconds until 100% at the
# current rate, set only when that lands before the window resets
pace() {
  local w=$1 u=$2 r=$3 left elapsed ttf
  PACE=""
  [ "$w" -gt 0 ] && [ "$r" -gt 0 ] && [ "$u" -gt 0 ] && [ "$u" -lt 100 ] || return
  left=$(( r - NOW )); elapsed=$(( w - left ))
  [ "$elapsed" -ge 900 ] && [ "$left" -gt 0 ] || return
  ttf=$(( (100 - u) * elapsed / u ))
  [ "$ttf" -lt "$left" ] && PACE=$ttf
}

# limit PRIO LABEL PCT RESETS_AT WINDOW_SECS
limit() {
  local S L
  printf -v L '%-3s' "$2"   # same width as "ctx", so the bars start in one column
  tone "$3"; bar "$3" "$LW"
  S="${DIM}${L}${RST} ${TN}${BAR} $3%${RST}"
  [ "$4" -gt 0 ] && { span $(( $4 - NOW )); S="${S} ${DIM}⏲ ${SP}${RST}"; }
  pace "$5" "$3" "$4"
  [ -n "$PACE" ] && { span "$PACE"; S="${S} ${ORG}⇡out ${SP}${RST}"; }
  add 3 "$1" "$S"
}
[ "$H5"  -ge 0 ] && limit 0 5h    "$H5"  "$H5R"  18000
[ "$D7"  -ge 0 ] && limit 1 7d    "$D7"  "$D7R"  604800
[ "$SPL" -ge 0 ] && limit 2 spend "$SPL" "$SPLR" 0

# ═════════════ LINE 4 — live subagents ═════════════
# cache: written-at, running count, segment
ACACHE="$TMP/cc-agents-$SID"
if [ -f "$ACACHE" ]; then
  { read -r AAT; read -r ACOUNT; read -r ASEG; } < "$ACACHE"
  int AAT 0; int ACOUNT 0
  [ $(( NOW - AAT )) -le 20 ] && [ "$ACOUNT" -gt 0 ] && [ -n "$ASEG" ] && add 4 0 "$ASEG"
fi

# ═════════════ LINE 5 — warnings ═════════════
W() { add 5 "$1" "${2}▲ $3${RST}"; }

if   [ "$PCT" -ge "$TONE_RED" ]; then W 0 "$RED" "context ${PCT}% — /compact now"
elif [ "$PCT" -ge "$TONE_ORG" ]; then W 1 "$ORG" "context ${PCT}% — /compact soon"
fi

[ "$CF" -gt 0 ] && { plural "$CF" "merge conflict" s; W 0 "$RED" "$PL"; }

# warn_limit LABEL PCT RESETS_AT WINDOW_SECS
warn_limit() {
  local r=""
  [ "$3" -gt 0 ] && { span $(( $3 - NOW )); r=" · resets ${SP}"; }
  if   [ "$2" -ge 100 ];         then W 0 "$RED" "$1 limit reached${r}"
  elif [ "$2" -ge "$TONE_RED" ]; then W 0 "$RED" "$1 limit $2%${r}"
  elif [ "$2" -ge "$TONE_ORG" ]; then W 1 "$ORG" "$1 limit $2%${r}"
  else
    pace "$4" "$2" "$3"
    [ -n "$PACE" ] && { span "$PACE"; W 2 "$ORG" "$1 on pace to run out in ${SP}${r}"; }
  fi
}
[ "$H5"  -ge 0 ] && warn_limit 5h    "$H5"  "$H5R"  18000
[ "$D7"  -ge 0 ] && warn_limit 7d    "$D7"  "$D7R"  604800
[ "$SPL" -ge 0 ] && warn_limit spend "$SPL" "$SPLR" 0

if [ "$PC_ON" -eq 1 ]; then
  kfmt "$PC_RECOLD"
  if [ "$PC_WARM" -eq 1 ] && [ "$PC_EXP" -gt 0 ] && [ $(( PC_EXP - NOW )) -lt 300 ] \
     && [ "$PC_RECOLD" -ge "$RECACHE_WARN" ]; then
    span $(( PC_EXP - NOW ))
    W 3 "$YEL" "cache cold in ${SP} — ${K} to rebuild"
  elif [ "$PC_WARM" -eq 0 ] && [ "$PC_RECOLD" -ge "$RECACHE_WARN" ]; then
    W 3 "$ORG" "cache cold — next message rewrites ${K}"
  fi
fi

[ "$BH" -gt 0 ] && W 5 "$YEL" "branch ${BH} behind upstream"

# ---------------- emit ----------------
render 1
render 2
render 3
render 4
render 5
exit 0
