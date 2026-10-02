#!/bin/bash
# ~/.claude/statusline.sh — Claude Code status line
#
#   1  identity  model:effort ⚡ │ dir │ git │ worktree │ PR │ agent │ session
#   2  session   context bar │ prompt cache │ ~cost │ active time │ churn │ compactions
#   3  limits    5h │ 7d │ spend  (pace-coloured bars with an elapsed tick, reset time, verdict)
#   4  agents    live subagents (written by ~/.claude/subagent-statusline.sh)
#   5  warnings  only when something needs attention
#
# Every line is fitted to $COLUMNS: segments first shrink to a short form,
# then the least important ones drop. Data is local only: stdin JSON, one
# cached git call per directory, and an incremental scan of the session transcript.
# Caches live in a private 0700 dir ($XDG_RUNTIME_DIR or $TMPDIR, /cc-sl-$UID).
# Helpers return through globals, never $(...): each subshell costs a fork,
# and forks are what make status lines slow. Deps: jq, git, perl. Bash 3.2 compatible.

# ${#str} must count characters, not bytes: take the first UTF-8 locale that
# exists here (a missing one silently falls back to C), checked without a fork
{ for _l in en_US.UTF-8 C.UTF-8 en_US.utf8 C.utf8 UTF-8; do
    LC_ALL=$_l; _t='█'; [ "${#_t}" -eq 1 ] && break
  done; } 2>/dev/null
export LC_ALL
IFS= read -r -d '' input

# ---------------- config ----------------
TONE_YEL=50; TONE_ORG=75; TONE_RED=90       # % thresholds (context; limits with no window)
CTX_YEL=300000; CTX_ORG=500000; CTX_RED=750000   # absolute context size, tokens (matters on 1M windows)
PACE_YEL=95;  PACE_ORG=115; PACE_RED=130    # used% ÷ elapsed% ×100; 95+ = "near pace"
PACE_MIN=900                                # seconds into a window before pace counts
PACE_MIN_PCT=20                             # …and % of the window (1h of 5h, ~34h of 7d)
PACE_ALARM=50                               # % used before pace may go past yellow, show ⇡out or warn
COST_YEL=100; COST_ORG=500; COST_RED=2000   # cents (API-key users; dimmed on a plan)
GIT_TTL=5                                   # seconds between git refreshes
GIT_SLOW_MS=150                             # slower than this → skip untracked files (-uno)
GIT_SLOW_TTL=15                             # refresh interval once a repo is marked slow
GIT_SLOW_RECHECK=300                        # seconds before a slow repo is re-measured in full
GIT_NOREPO_TTL=30                           # seconds between checks of a directory that is not a repo
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
  read -r H5;      read -r H5R;      read -r H5T
  read -r D7;      read -r D7R;      read -r D7T
  read -r SPL;     read -r SPLR;     read -r SPLT
  read -r PC_ON;   read -r PC_WARM;  read -r PC_TTL; read -r PC_EXP; read -r PC_HIT
  read -r PC_MISS; read -r PC_RECOLD
  read -r SID;     read -r PRNUM;    read -r PRSTATE; read -r PRKIND; read -r TRANSCRIPT
} < <(jq -r '
  def s: if . == null then "" else tostring
    | gsub("\u001b\\[[0-9;?]*[ -/]*[@-~]"; "")                  # CSI, e.g. colour codes
    | gsub("\u001b\\][^\u0007\u001b]*(\u0007|\u001b\\\\)?"; "")  # OSC, e.g. window title
    | gsub("[\u0000-\u001f\u007f-\u009f]"; " ") end;
  def i($d): if type == "number" then floor else $d end;
  # local reset time, formatted here so the shell needs no `date` fork
  def at($f): if type == "number" and . > 0 then (strflocaltime($f) | gsub(" +"; " ") | ltrimstr(" ")) else "" end;
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
    (.cost.total_cost_usd // 0), ((.cost.total_cost_usd // 0) * 100 + 0.5 | floor | if . > 999999999999 then 999999999999 else . end),
    (.cost.total_duration_ms | i(0)), (.cost.total_api_duration_ms | i(0)),
    (.cost.total_lines_added | i(0)), (.cost.total_lines_removed | i(0)),
    (.rate_limits.five_hour.used_percentage   | i(-1)), (.rate_limits.five_hour.resets_at   | i(0)),
    (.rate_limits.five_hour.resets_at   | at("%l:%M %p")),
    (.rate_limits.seven_day.used_percentage   | i(-1)), (.rate_limits.seven_day.resets_at   | i(0)),
    (.rate_limits.seven_day.resets_at   | at("%a %l:%M %p")),
    (.rate_limits.spend_limit.used_percentage | i(-1)), (.rate_limits.spend_limit.resets_at | i(0)),
    (.rate_limits.spend_limit.resets_at | at("%b %e")),
    (if .prompt_cache.caching_observed == true then 1 else 0 end),
    (if .prompt_cache.warm == true then 1 else 0 end),
    (.prompt_cache.ttl // ""), (.prompt_cache.expires_at | i(0)),
    (if (.prompt_cache.hit_ratio | type) == "number" then (.prompt_cache.hit_ratio * 100 + 0.5 | floor) else -1 end),
    (.prompt_cache.misses | i(0)), (.prompt_cache.recache_tokens_if_cold | i(0)),
    (.session_id // "nosession"), (.pr.number // ""), (.pr.review_state // ""), (.pr.kind // ""),
    (.transcript_path // "")
  ] | .[] | s' <<< "$input" 2>/dev/null)

# Bad or missing input must never break the layout
int() { [[ ${!1} =~ ^-?[0-9]+$ ]] || printf -v "$1" '%s' "$2"; }
for v in ADDED TOK DUR_MS API_MS ADD DEL H5R D7R SPLR PC_ON PC_WARM PC_EXP \
         PC_MISS PC_RECOLD CENTS; do int "$v" 0; done
for v in PCT H5 D7 SPL PC_HIT; do int "$v" -1; done
int CTXMAX 200000; [ "$CTXMAX" -gt 0 ] || CTXMAX=200000
[ "${#CENTS}" -le 12 ] || CENTS=999999999999   # absurd cost: keep [ ] arithmetic valid
[[ $NOW =~ ^[0-9]+$ ]] || NOW=$(date +%s)
[[ $COST =~ ^[0-9.eE+-]+$ ]] || COST=0
[ -n "$MODEL" ] || MODEL="?"
[ -n "$CWD" ]   || CWD="."
SID=${SID//[^A-Za-z0-9_-]/}; [ -n "$SID" ] || SID=nosession

TMP="${TMPDIR:-/tmp}"; TMP="${TMP%/}"
# Private cache dir, shared with subagent-statusline.sh: mode 0700 and owned by
# us, so on a shared /tmp nobody else can pre-create or symlink our cache files.
CDIR="${XDG_RUNTIME_DIR:-$TMP}/cc-sl-$UID"
[ -d "$CDIR" ] || mkdir -m 700 "$CDIR" 2>/dev/null
if [ -L "$CDIR" ] || [ ! -O "$CDIR" ]; then
  CDIR="$HOME/.cache/cc-statusline"; [ -d "$CDIR" ] || mkdir -p -m 700 "$CDIR" 2>/dev/null
fi
# Claude Code sets COLUMNS; 80 is the safe fallback when it is missing or nonsense
COLS=${COLUMNS:-0}; int COLS 0; [ "$COLS" -ge 20 ] || COLS=80
MAXW=$(( COLS - PAD ))

# ---------------- palette (256-colour) ----------------
E=$'\033['
DIM="${E}38;5;245m"; FG="${E}38;5;252m"; GRN="${E}38;5;114m"; YEL="${E}38;5;221m"
ORG="${E}38;5;208m"; RED="${E}38;5;203m"; CYN="${E}38;5;109m"; BLU="${E}38;5;110m"
MAG="${E}38;5;176m"; TAN="${E}38;5;180m"; PUR="${E}38;5;140m"
BOLD="${E}1m"; RST="${E}0m"
SEP=" ${DIM}│${RST} "
TONES=("$GRN" "$YEL" "$ORG" "$RED")   # severity 0..3

# ---------------- helpers (results in globals) ----------------
# level VALUE YEL ORG RED → LV (severity 0..3)
level() {
  if   [ "$1" -ge "$4" ]; then LV=3
  elif [ "$1" -ge "$3" ]; then LV=2
  elif [ "$1" -ge "$2" ]; then LV=1
  else                         LV=0; fi
}

# tone PCT → TN, LV   (higher is worse)
tone() { level "$1" "$TONE_YEL" "$TONE_ORG" "$TONE_RED"; TN=${TONES[LV]}; }

# tone_up PCT → TU   (higher is better: cache hit ratio)
tone_up() {
  if   [ "$1" -ge 80 ]; then TU=$GRN
  elif [ "$1" -ge 50 ]; then TU=$YEL
  else                       TU=$ORG; fi
}

# bar PCT WIDTH [TICK_PCT] → BAR, coloured with $TN; an optional tick in the
# foreground colour marks how much of a time window has elapsed
bar() {
  local p=$1 w=$2 tk=${3:--1} f i c out=""
  [ "$p" -lt 0 ] && p=0
  f=$(( p * w / 100 )); [ "$f" -gt "$w" ] && f=$w
  if [ "$tk" -ge 0 ]; then tk=$(( tk * w / 100 )); [ "$tk" -ge "$w" ] && tk=$(( w - 1 )); fi
  for (( i = 0; i < w; i++ )); do
    if [ "$i" -lt "$f" ]; then c="█"; else c="░"; fi
    if [ "$i" -eq "$tk" ]; then out+="${FG}┃${TN}"; else out+=$c; fi
  done
  BAR="${TN}${out}"
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
# add LINE PRIO TEXT [SHORT] — lower PRIO is more important and survives longer;
# SHORT is tried before the segment is dropped
add() { eval "L$1T+=(\"\$3\"); L$1P+=(\"\$2\"); L$1S+=(\"\${4-}\")"; }

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
  # East Asian Wide characters (CJK, Hangul, fullwidth forms, emoji, ⚡) take two
  # columns; the bar, box and clock glyphs used here are narrow
  if [[ $out == *[!\ -~]* ]]; then s=${out//$WIDE/}; VL=$(( VL + VL - ${#s} )); fi
}

WIDE="[ᄀ-ᅟ⺀-〾ぁ-ㇿ㐀-䶿一-鿿ꀀ-꓏가-힣豈-﫿︐-︙︰-﹯＀-｠￠-￦🌀-🙏🚀-🛿🤀-🫿⚡]"

# vtrunc TEXT N → TR   (cut to N visible columns, colour codes kept, "…" at the end)
vtrunc() {
  local s=$1 n=$2 c=0 seq ch
  TR=""
  while [ -n "$s" ] && [ "$c" -lt $(( n - 1 )) ]; do
    if [[ $s == $'\033['* ]]; then
      [[ $s == *m* ]] || break          # unterminated escape: stop, don't spin
      seq=${s%%m*}m; TR+=$seq; s=${s#"$seq"}
    else
      ch=${s:0:1}; s=${s:1}
      # wide characters take two columns; stop rather than split one at the edge
      if [[ $ch == $WIDE ]]; then
        [ $(( c + 2 )) -gt $(( n - 1 )) ] && break
        c=$(( c + 2 ))
      else
        c=$(( c + 1 ))
      fi
      TR+=$ch
    fi
  done
  TR+="…${RST}"
}

# print line N: shrink, then drop, its least important segments until it fits
render() {
  local -a T P S
  eval "T=(\"\${L$1T[@]}\"); P=(\"\${L$1P[@]}\"); S=(\"\${L$1S[@]}\")"
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
    [ "$total" -le "$MAXW" ] && break
    if [ "$cnt" -le 1 ]; then
      # one segment left and still too wide: cut it rather than overflow
      for (( i = 0; i < n; i++ )); do
        [ -n "${T[i]}" ] || continue
        if [ -n "${S[i]}" ]; then T[i]=${S[i]}; S[i]=""; continue 2; fi
        vtrunc "${T[i]}" "$MAXW"; T[i]=$TR
      done
      break
    fi
    worst=-1; wi=-1
    for (( i = 0; i < n; i++ )); do
      [ -n "${T[i]}" ] && [ "${P[i]}" -ge "$worst" ] && { worst=${P[i]}; wi=$i; }
    done
    if [ -n "${S[wi]}" ]; then T[wi]=${S[wi]}; S[wi]=""; else T[wi]=""; fi
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

# ---------------- git: one lock-free call, cached per directory ----------------
# Keyed by directory, so sessions in the same repo share one git call. A repo
# whose status takes longer than GIT_SLOW_MS is marked slow: from then on
# untracked files are skipped (-uno, the expensive part in big repos) and it
# refreshes less often.
# cache: refreshed-at, slow-since (0 = fast), dir, branch, oid, staged, modified,
#        untracked, conflicts, stash, ahead, behind
# The key escapes "_" first, so /a/b and /a_b stay distinct; the full dir is
# stored and checked too, in case a long path's key was cut.
GKEY=${CWD//_/__}; GKEY=${GKEY//[^A-Za-z0-9._-]/_}; [ "${#GKEY}" -gt 120 ] && GKEY=${GKEY: -120}
GCACHE="$CDIR/git-$GKEY"
GAT=0 SLOW=0 GDIR="" BR="" OID="" ST=0 MD=0 UN=0 CF=0 SH=0 AH=0 BH=0
[ -f "$GCACHE" ] && { read -r GAT; read -r SLOW; read -r GDIR; read -r BR; read -r OID; read -r ST
                      read -r MD;  read -r UN;   read -r CF;   read -r SH; read -r AH;  read -r BH; } < "$GCACHE"
int GAT 0; int SLOW 0
[ "$GDIR" = "$CWD" ] || { GAT=0; SLOW=0; }
# A slow repo skips untracked files (-uno) and refreshes less often, but every
# GIT_SLOW_RECHECK seconds it is measured again in full, so one slow run (a
# cold disk after boot) can't leave it in -uno mode, hiding new files, forever.
UFLAG=-unormal; TTL=$GIT_TTL
if [ "$SLOW" -gt 0 ] && [ $(( NOW - SLOW )) -lt "$GIT_SLOW_RECHECK" ]; then
  UFLAG=-uno; TTL=$GIT_SLOW_TTL
fi
# not a repo at the last check: look again less often
[ "$GAT" -gt 0 ] && [ -z "$BR" ] && TTL=$GIT_NOREPO_TTL
# refresh when stale, or when the clock went backwards (NOW - GAT < 0 would stall)
if [ $(( NOW - GAT )) -ge "$TTL" ] || [ "$NOW" -lt "$GAT" ]; then
  BR="" OID="" ST=0 MD=0 UN=0 CF=0 SH=0 AH=0 BH=0
  GOUT="$GCACHE.out.$$"; GTIME="$GCACHE.time.$$"
  trap 'rm -f "$GOUT" "$GTIME" "$GCACHE.$$"' EXIT   # Claude Code may kill a slow run
  TIMEFORMAT=%3R
  { time git --no-optional-locks -C "$CWD" status --porcelain=v2 --branch --show-stash "$UFLAG" \
      > "$GOUT" 2>/dev/null; } 2> "$GTIME"
  read -r GT < "$GTIME"; GT=${GT//[^0-9]/}; GT=$(( 10#${GT:-0} ))
  if [ "$UFLAG" = -unormal ]; then
    if [ "$GT" -gt "$GIT_SLOW_MS" ]; then SLOW=$NOW; else SLOW=0; fi
  fi
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
  done < "$GOUT"
  [ "$BR" = "(detached)" ] && BR="@${OID}"
  printf '%s\n' "$NOW" "$SLOW" "$CWD" "$BR" "$OID" "$ST" "$MD" "$UN" "$CF" "$SH" "$AH" "$BH" \
    > "$GCACHE.$$" 2>/dev/null && mv -f "$GCACHE.$$" "$GCACHE" 2>/dev/null
  rm -f "$GOUT" "$GTIME"; trap - EXIT
fi
for v in ST MD UN CF SH AH BH; do int "$v" 0; done

# clean VAR — strip control characters from text that didn't come through jq
# (git output, cache files): BEL, non-colour escapes such as OSC window titles,
# other C0 controls and UTF-8 C1 controls. Colour codes (ESC[…m) are kept.
clean() {
  local v=${!1} loc=$LC_ALL
  LC_ALL=C
  v=${v//$'\a'/}; v=${v//$'\e'[!\[]/}
  v=${v//[$'\x01'-$'\x1a'$'\x1c'-$'\x1f'$'\x7f']/ }
  v=${v//$'\xc2'[$'\x80'-$'\x9f']/ }
  LC_ALL=$loc
  printf -v "$1" '%s' "$v"
}
clean BR; BR=${BR//$'\e'/ }            # a branch name has no business carrying escapes

# ---------------- compactions: incremental transcript scan ----------------
# Reads only the bytes appended since the last scan, and advances the offset
# only past complete lines, so the cost stays flat however long the session.
# cache: byte offset, count, transcript path
CMP=0
if [ -f "$TRANSCRIPT" ]; then
  CCACHE="$CDIR/cmp-$SID"
  OFF=0 CPATH=""
  [ -f "$CCACHE" ] && read -r OFF CMP CPATH < "$CCACHE"
  int OFF 0; int CMP 0
  [ "$CPATH" = "$TRANSCRIPT" ] || { OFF=0; CMP=0; CPATH=""; }
  # mtimes compare to the second: rescan unless the cache is strictly newer,
  # so an append in the same second as the last scan isn't missed
  if [ -z "$CPATH" ] || [ ! "$CCACHE" -nt "$TRANSCRIPT" ]; then
    read -r NOFF NEW RESET < <(perl -e '
      my ($f, $o) = @ARGV; my ($n, $reset) = (0, 0);
      open(my $h, "<", $f) or do { print "$o 0 0\n"; exit };
      if ($o > -s $h) { $o = 0; $reset = 1 }
      seek($h, $o, 0);
      while (my $l = <$h>) {
        last unless $l =~ /\n\z/;
        $o += length $l;
        $n++ if index($l, q{"subtype":"compact_boundary"}) >= 0;
      }
      print "$o $n $reset\n";' "$TRANSCRIPT" "$OFF" 2>/dev/null)
    int NOFF "$OFF"; int NEW 0; int RESET 0
    [ "$RESET" -eq 1 ] && CMP=0
    CMP=$(( CMP + NEW ))
    printf '%s %s %s\n' "$NOFF" "$CMP" "$TRANSCRIPT" > "$CCACHE.$$" 2>/dev/null && mv -f "$CCACHE.$$" "$CCACHE" 2>/dev/null
  fi
fi

# subscription users (rate limits present) pay a plan, not this list-price estimate
SUB=0
if [ "$H5" -ge 0 ] || [ "$D7" -ge 0 ] || [ "$SPL" -ge 0 ]; then SUB=1; fi

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

# directory: home-relative path, so a folder named "Claude" can't read as the app;
# short form is project-relative (or just the folder name)
D=$CWD
case "$D" in "$HOME") D="~" ;; "$HOME"/*) D="~/${D#"$HOME"/}" ;; esac
[ "${#D}" -gt 40 ] && D="…${D: -39}"
DS=${CWD##*/}
if [ -n "$PROJ" ] && [ "$CWD" != "$PROJ" ]; then
  case "$CWD" in "$PROJ"/*) DS="${PROJ##*/}/${CWD#"$PROJ"/}" ;; esac
fi
[ "${#DS}" -gt 24 ] && DS="…${DS: -23}"
DX=""; [ "$ADDED" -gt 0 ] && DX=" ${DIM}+${ADDED}dir${RST}"
add 1 3 "${TAN}${D}${RST}${DX}" "${TAN}${DS}${RST}${DX}"

if [ -n "$BR" ]; then
  [ "${#BR}" -gt 28 ] && BR="${BR:0:27}…"
  # "*" marks a dirty tree without relying on colour
  if [ $(( ST + MD + UN + CF )) -eq 0 ]; then G="${GRN}⎇ ${BR}${RST}"; else G="${PUR}⎇ ${BR}*${RST}"; fi
  [ "$CF" -gt 0 ] && G="${G} ${RED}⚔${CF}${RST}"
  [ "$ST" -gt 0 ] && G="${G} ${GRN}+${ST}${RST}"
  [ "$MD" -gt 0 ] && G="${G} ${ORG}~${MD}${RST}"
  [ "$UN" -gt 0 ] && G="${G} ${DIM}?${UN}${RST}"
  [ "$SH" -gt 0 ] && G="${G} ${DIM}≡${SH}${RST}"
  [ "$AH" -gt 0 ] && G="${G} ${CYN}↑${AH}${RST}"
  [ "$BH" -gt 0 ] && G="${G} ${RED}↓${BH}${RST}"
  add 1 1 "$G"
fi

[ -n "$WT" ] && add 1 5 "${DIM}wt:${RST}${CYN}${WT}${RST}"

if [ -n "$PRNUM" ]; then
  if [ "$PRKIND" = "mr" ]; then PRL="!${PRNUM}"; else PRL="#${PRNUM}"; fi
  case "$PRSTATE" in
    approved)          P="${GRN}${PRL} ✓${RST}" ;;
    changes_requested) P="${RED}${PRL} ✗${RST}" ;;
    draft)             P="${DIM}${PRL} draft${RST}" ;;
    pending)           P="${YEL}${PRL} ◷${RST}" ;;
    *)                 P="${YEL}${PRL}${RST}" ;;
  esac
  add 1 4 "$P"
fi

[ -n "$VIM" ]   && add 1 2 "${BOLD}${VIM}${RST}"
[ -n "$AGENT" ] && add 1 6 "${YEL}@${AGENT}${RST}"
if [ -n "$SNAME" ]; then
  SN=$SNAME;  [ "${#SN}" -gt 60 ] && SN="${SN:0:59}…"
  SNS=$SNAME; [ "${#SNS}" -gt 24 ] && SNS="${SNS:0:23}…"
  add 1 8 "${DIM}“${SN}”${RST}" "${DIM}“${SNS}”${RST}"
fi
[ -n "$STYLE" ] && [ "$STYLE" != "default" ] && add 1 9 "${DIM}style:${STYLE}${RST}"

# ═════════════ LINE 2 — context, cache, cost, time ═════════════
# context: the bar and % follow % of the window; the token count is coloured by
# absolute size, because a 1M window at 34% is still a 340k-token prompt on
# every turn. Warnings use the worse of the two.
kfmt "$CTXMAX"; KMAX=$K
if [ "$PCT" -ge 0 ]; then
  level "$TOK" "$CTX_YEL" "$CTX_ORG" "$CTX_RED"; L_TOK=$LV
  if [ "$L_TOK" -gt 0 ]; then KC=${TONES[L_TOK]}; else KC=$DIM; fi
  tone "$PCT"; L_PCT=$LV
  CTX_LV=$L_PCT; [ "$L_TOK" -gt "$CTX_LV" ] && CTX_LV=$L_TOK
  bar "$PCT" "$BW"; kfmt "$TOK"
  add 2 0 "${DIM}ctx  ${RST} ${BAR} ${PCT}%${RST} ${KC}${K}${DIM}/${KMAX}${RST}"
else
  CTX_LV=0; TN=$DIM; bar 0 "$BW"
  add 2 0 "${DIM}ctx   ${BAR} — 0/${KMAX}${RST}"
fi

if [ "$PC_ON" -eq 1 ]; then
  if [ "$PC_WARM" -eq 1 ]; then CS="${GRN}●${RST}"; else CS="${DIM}○${RST}"; fi
  CS="${CS} ${DIM}cache${RST}"
  [ "$PC_HIT" -ge 0 ] && { tone_up "$PC_HIT"; CS="${CS} ${TU}${PC_HIT}%${RST} ${DIM}hit${RST}"; }
  if [ "$PC_WARM" -eq 1 ] && [ "$PC_EXP" -gt 0 ]; then
    LEFT=$(( PC_EXP - NOW )); span "$LEFT"
    if   [ "$LEFT" -lt 300 ]; then CT=$ORG
    elif [ "$LEFT" -lt 600 ]; then CT=$YEL
    else                           CT=$GRN; fi
    CS="${CS} ${DIM}· cold in${RST} ${CT}${SP}${RST}"
  elif [ "$PC_WARM" -eq 0 ]; then
    CS="${CS} ${DIM}·${RST} ${ORG}cold${RST}"
    [ "$PC_RECOLD" -gt 0 ] && { kfmt "$PC_RECOLD"; CS="${CS} ${DIM}(${K} to rebuild)${RST}"; }
  fi
  [ "$PC_MISS" -gt 0 ] && { plural "$PC_MISS" miss es; CS="${CS} ${DIM}· ${PL}${RST}"; }
  add 2 1 "$CS"
fi

# session cost: always "~" (Claude Code's list-price estimate); dimmed on a plan,
# where the usage limits are the real constraint
if [ "${#CENTS}" -gt 7 ]; then COSTS='~$99k+'   # over $99,999: don't print 30 digits
else printf -v COSTS '~$%.2f' "$COST" 2>/dev/null || COSTS='~$?'; fi
if [ "$SUB" -eq 1 ]; then CC=$DIM
elif [ "$CENTS" -ge "$COST_RED" ]; then CC=$RED
elif [ "$CENTS" -ge "$COST_ORG" ]; then CC=$ORG
elif [ "$CENTS" -ge "$COST_YEL" ]; then CC=$YEL
else                                    CC=$GRN; fi
add 2 2 "${CC}${COSTS}${RST}"

# active time: time Claude was working, not time the window was open
if [ "$API_MS" -ge 1000 ]; then
  span $(( API_MS / 1000 ))
  add 2 6 "${DIM}⏱ ${SP} active${RST}"
fi

if [ "$ADD" -gt 0 ] || [ "$DEL" -gt 0 ]; then
  add 2 4 "${GRN}+${ADD}${RST}${DIM}/${RST}${RED}-${DEL}${RST}"
fi
[ "$CMP" -gt 0 ] && add 2 5 "${DIM}⟳${CMP}${RST}"

# ═════════════ LINE 3 — usage limits ═════════════
# pace USED_PCT WINDOW_SECS RESETS_AT →
#   EP    elapsed % of the window (-1 if unknown)
#   RT    used% ÷ elapsed% ×100 (-1 until PACE_MIN into the window, when a few
#         minutes of heavy use would extrapolate to nonsense)
#   PACE  seconds until 100% at this rate, set only when that lands before the reset
pace() {
  local u=$1 w=$2 r=$3 left el ttf
  EP=-1; RT=-1; PACE=""
  [ "$w" -gt 0 ] && [ "$r" -gt 0 ] || return
  left=$(( r - NOW )); [ "$left" -lt 0 ] && left=0
  el=$(( w - left ));  [ "$el" -lt 0 ] && el=0
  EP=$(( el * 100 / w ))
  # early in a window a short burst extrapolates to nonsense (10% used 19 minutes
  # into 5h reads as "out in 2h50m"), so pace waits for enough of the window
  [ "$el" -ge "$PACE_MIN" ] && [ "$EP" -ge "$PACE_MIN_PCT" ] || return
  RT=$(( u * w / el ))
  [ "$u" -gt 0 ] && [ "$u" -lt 100 ] && [ "$left" -gt 0 ] || return
  ttf=$(( (100 - u) * el / u ))
  [ "$ttf" -lt "$left" ] && PACE=$ttf
}

# limit PRIO LABEL PCT RESETS_AT WINDOW_SECS RESET_TIME
# Colour follows pace, not the raw %: 51% used two-thirds through the week is
# fine. At TONE_RED and above it is red whatever the pace, since the cap is near.
WORST=0
limit() {
  local S L
  printf -v L '%-5s' "$2"   # same width as "ctx" and "spend", so bars start in one column
  # past its reset: the numbers are the old window's until the next API response
  if [ "$4" -gt 0 ] && [ "$4" -le "$NOW" ]; then
    TN=$DIM; bar 0 "$LW"
    add 3 "$1" "${DIM}${L} ${BAR} reset · new window${RST}"
    return
  fi
  pace "$3" "$5" "$4"
  if   [ "$3" -ge "$TONE_RED" ]; then LV=3
  elif [ "$RT" -ge 0 ];          then
    level "$RT" "$PACE_YEL" "$PACE_ORG" "$PACE_RED"
    # with little used there is nothing to alarm about yet: pace can only say "near pace"
    [ "$3" -lt "$PACE_ALARM" ] && [ "$LV" -gt 1 ] && LV=1
  else                                tone "$3"; fi
  # projected to run out before the reset: at least orange, like ⇡out and its warning,
  # but only once enough is used for the projection to matter
  [ "$3" -lt "$PACE_ALARM" ] && PACE=""
  [ -n "$PACE" ] && [ "$LV" -lt 2 ] && LV=2
  TN=${TONES[LV]}
  [ "$LV" -gt "$WORST" ] && WORST=$LV
  bar "$3" "$LW" "$EP"
  S="${DIM}${L}${RST} ${BAR} $3% used${RST}"
  if [ -n "$6" ]; then
    S="${S} ${DIM}⏲ $6"
    # 5h only: in a short window the time left matters more than the clock time
    [ "$5" -eq 18000 ] && [ "$4" -gt "$NOW" ] && { span $(( $4 - NOW )); S="${S} (${SP})"; }
    S="${S}${RST}"
  fi
  [ -n "$PACE" ] && { span "$PACE"; S="${S} ${ORG}⇡out in ${SP}${RST}"; }
  add 3 "$1" "$S"
}
[ "$H5"  -ge 0 ] && limit 0 5h    "$H5"  "$H5R"  18000  "$H5T"
[ "$D7"  -ge 0 ] && limit 1 7d    "$D7"  "$D7R"  604800 "$D7T"
[ "$SPL" -ge 0 ] && limit 2 spend "$SPL" "$SPLR" 0      "$SPLT"
# one verdict, like Claude's usage page; orange and red explain themselves (⇡out, ≥90%)
if [ "$SUB" -eq 1 ]; then
  if   [ "$WORST" -eq 0 ]; then add 3 3 "${GRN}✓ on track${RST}"
  elif [ "$WORST" -eq 1 ]; then add 3 3 "${YEL}≈ near pace${RST}"; fi
fi

# ═════════════ LINE 4 — live subagents ═════════════
# cache: written-at, running count, segment, short segment
ACACHE="$CDIR/agents-$SID"
if [ -f "$ACACHE" ]; then
  ASHORT=""
  { read -r AAT; read -r ACOUNT; read -r ASEG; read -r ASHORT; } < "$ACACHE"
  int AAT 0; int ACOUNT 0; clean ASEG; clean ASHORT
  [ $(( NOW - AAT )) -le 20 ] && [ "$ACOUNT" -gt 0 ] && [ -n "$ASEG" ] && add 4 0 "$ASEG" "$ASHORT"
fi

# ═════════════ LINE 5 — warnings ═════════════
W() { add 5 "$1" "${2}▲ $3${RST}"; }

# only at red, or from 75% of the window: an always-on row gets ignored
if   [ "$CTX_LV" -ge 3 ];          then kfmt "$TOK"; W 0 "$RED" "context ${PCT}% (${K}) — /compact now"
elif [ "$PCT" -ge "$TONE_ORG" ];    then kfmt "$TOK"; W 1 "$ORG" "context ${PCT}% (${K}) — /compact soon"
fi

[ "$CF" -gt 0 ] && { plural "$CF" "merge conflict" s; W 0 "$RED" "$PL"; }

# warn_limit LABEL PCT RESETS_AT WINDOW_SECS RESET_TIME
warn_limit() {
  local r=""
  [ "$3" -gt 0 ] && [ "$3" -le "$NOW" ] && return   # already reset
  [ -n "$5" ] && r=" · resets $5"
  if   [ "$2" -ge 100 ];         then W 0 "$RED" "$1 limit reached${r}"
  elif [ "$2" -ge "$TONE_RED" ]; then W 0 "$RED" "$1 limit $2%${r}"
  else
    pace "$2" "$4" "$3"
    [ "$2" -lt "$PACE_ALARM" ] && PACE=""
    [ -n "$PACE" ] && { span "$PACE"; W 2 "$ORG" "$1 on pace to run out in ${SP}${r}"; }
  fi
}
[ "$H5"  -ge 0 ] && warn_limit 5h    "$H5"  "$H5R"  18000  "$H5T"
[ "$D7"  -ge 0 ] && warn_limit 7d    "$D7"  "$D7R"  604800 "$D7T"
[ "$SPL" -ge 0 ] && warn_limit spend "$SPL" "$SPLR" 0      "$SPLT"

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

# ---------------- housekeeping ----------------
# once a day, in the background, remove cache files untouched for a week
# (the last run time is stored inside the marker file, so the check needs no fork)
TIDY="$CDIR/tidy"; TAT=0
[ -f "$TIDY" ] && read -r TAT < "$TIDY"; int TAT 0
if [ $(( NOW - TAT )) -ge 86400 ]; then
  printf '%s\n' "$NOW" > "$TIDY" 2>/dev/null
  ( find "$CDIR" -maxdepth 1 -type f ! -name tidy -mtime +7 -exec rm -f {} + >/dev/null 2>&1 & )
fi

# ---------------- emit ----------------
render 1
render 2
render 3
render 4
render 5
exit 0
