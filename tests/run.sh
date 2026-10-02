#!/bin/bash
# tests/run.sh — regression tests for statusline.sh and subagent-statusline.sh
#
#   tests/run.sh                 test the scripts in this repo
#   SL=~/.claude/statusline.sh SA=~/.claude/subagent-statusline.sh tests/run.sh
#
# Fixtures are built with jq relative to the current time, so countdowns and
# pace are deterministic. Runs in a throwaway TMPDIR; never touches live caches.
# Also runs shellcheck when it is installed.

cd "$(dirname "$0")/.." || exit 1
SL=${SL:-./statusline.sh}
SA=${SA:-./subagent-statusline.sh}
export TMPDIR; TMPDIR=$(mktemp -d) || exit 1
unset XDG_RUNTIME_DIR
trap 'rm -rf "$TMPDIR"' EXIT
NOW=$(date +%s)
PASS=0 FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n%s\n' "$1" "${2:+       $2}"; }
plain() { sed 's/\x1b\[[0-9;]*m//g'; }
# widest line in display columns (East Asian wide characters count as 2)
maxw() {
  perl -CS -ne 's/\e\[[0-9;]*m//g; chomp; my $w = 0;
    for (split //) { $w += /[\x{1100}-\x{115F}\x{2E80}-\x{303E}\x{3041}-\x{A4CF}\x{AC00}-\x{D7A3}\x{F900}-\x{FAFF}\x{FE10}-\x{FE19}\x{FE30}-\x{FE6F}\x{FF00}-\x{FF60}\x{FFE0}-\x{FFE6}\x{1F300}-\x{1F64F}\x{1F680}-\x{1F6FF}\x{1F900}-\x{1FAFF}\x{26A1}]/ ? 2 : 1 }
    $m = $w if $w > $m; END { print $m + 0 }'
}
run() { COLUMNS=${2:-200} "$SL" <<< "$1" 2>"$TMPDIR/stderr"; }
expect() {   # expect NAME OUTPUT PATTERN
  if printf '%s' "$2" | plain | grep -q -- "$3"; then ok "$1"; else bad "$1" "expected /$3/ in: $(printf '%s' "$2" | plain | tr '\n' '|')"; fi
}
reject() {   # reject NAME OUTPUT PATTERN
  if printf '%s' "$2" | plain | grep -q -- "$3"; then bad "$1" "unexpected /$3/ in: $(printf '%s' "$2" | plain | tr '\n' '|')"; else ok "$1"; fi
}
limits() {   # limits USED_PCT SECONDS_LEFT — a 5h window
  jq -n --argjson n "$NOW" --argjson u "$1" --argjson l "$2" \
    '{rate_limits:{five_hour:{used_percentage:$u,resets_at:($n+$l)}}}'
}

echo "Input robustness"
for input in '' '{}' 'null' 'garbage{' '[1,2]' '"str"' '{"model":"x","rate_limits":"a"}' \
             '{"cost":{"total_cost_usd":1e30}}' '{"context_window":{"context_window_size":0,"used_percentage":5}}'; do
  out=$(printf '%s' "$input" | COLUMNS=100 "$SL" 2>"$TMPDIR/stderr"); rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$TMPDIR/stderr" ] && [ -n "$out" ]; then ok "renders: ${input:-<empty>}"
  else bad "renders: ${input:-<empty>}" "rc=$rc stderr=$(cat "$TMPDIR/stderr")"; fi
done

echo "Width fitting (busy session, 20-200 columns)"
mkdir -p "$TMPDIR/repo" && git -C "$TMPDIR/repo" init -q -b main && echo x > "$TMPDIR/repo/f"
BUSY=$(jq -n --argjson n "$NOW" --arg d "$TMPDIR/repo" '{
  session_id:"t-busy", model:{display_name:"Opus 5.5"}, effort:{level:"xhigh"}, fast_mode:true,
  workspace:{current_dir:$d, project_dir:$d}, worktree:{name:"feat-x"},
  pr:{number:1234, review_state:"approved"}, vim:{mode:"NORMAL"}, agent:{name:"reviewer"},
  session_name:"日本語 and a long English session title here",
  context_window:{used_percentage:78, total_input_tokens:780000, context_window_size:1000000},
  cost:{total_cost_usd:21.3, total_api_duration_ms:2100000, total_lines_added:1205, total_lines_removed:255},
  prompt_cache:{caching_observed:true, warm:true, expires_at:($n+200), hit_ratio:0.97, misses:4, recache_tokens_if_cold:400000},
  rate_limits:{five_hour:{used_percentage:60, resets_at:($n+9000)}, seven_day:{used_percentage:53, resets_at:($n+290000)},
               spend_limit:{used_percentage:40, resets_at:($n+900000)}}}')
jq -n --argjson n "$NOW" '{session_id:"t-busy", columns:150, tasks:[range(3) | {id:"t\(.)", name:"local_agent",
  type:"ecc:code-reviewer", status:"running", tokenCount:90000, contextWindowSize:200000, startTime:($n-200)}]}' | "$SA" >/dev/null
over=""
for c in 20 24 30 40 50 60 70 80 90 100 120 140 160 200; do
  w=$(run "$BUSY" "$c" | maxw); [ "$w" -le $((c - 4)) ] || over="$over $c:$w"
done
if [ -z "$over" ]; then ok "no line wider than COLUMNS-4"; else bad "overflow" "$over"; fi

echo "Context"
expect "hit rate is rounded"            "$(run '{"prompt_cache":{"caching_observed":true,"warm":false,"hit_ratio":0.57}}')" "57% hit"
out=$(run '{"context_window":{"used_percentage":42,"total_input_tokens":421000,"context_window_size":1000000}}')
reject "no warning at 42% of 1M"        "$out" "compact"
expect "size shown"                     "$out" "421k/1M"
expect "warning from 75% of the window" "$(run '{"context_window":{"used_percentage":80,"total_input_tokens":160000,"context_window_size":200000}}')" "compact soon"
expect "red size says now"              "$(run '{"context_window":{"used_percentage":78,"total_input_tokens":780000,"context_window_size":1000000}}')" "compact now"

echo "Limits (pace = projected % used at the reset)"
out=$(run "$(limits 10 16860)")
expect "early burst stays on track"     "$out" "on track"
reject "early burst has no projection"  "$out" "out in"
expect "under 20% used: pace ignored"   "$(run "$(limits 15 12600)")" "on track"   # 15% at 30% elapsed
expect "projected 97%: on track"        "$(run "$(limits 21 14100)")" "on track"
out=$(run "$(limits 26 13380)")                                                     # your case: 26% at 25.7%, ~101%
expect "projected ~101%: near pace"     "$out" "near pace"
reject "a near tie is not a run-out"    "$out" "out in"
reject "and raises no warning"          "$out" "▲"
expect "52% halfway: near pace"         "$(run "$(limits 52 9000)")" "near pace"  # 104%, run-out 12 min early
out=$(run "$(limits 60 9000)")                                                      # 120%, 50 min early
expect "meaningfully early: run-out"    "$out" "out in 1h40m"
expect "and warns"                      "$out" "5h on pace to run out"
expect "≥90% warns regardless"          "$(run "$(limits 92 1800)")" "5h limit 92%"
expect "past reset shows new window"    "$(run "$(limits 80 -100)")" "reset · new window"
expect "5h shows a countdown"           "$(run "$(limits 30 5010)")" "(1h23m)"   # 1h23m30s: margin for the clock ticking
reject "no 'used' after the %"          "$(run "$(limits 30 5010)")" "% used"
out=$(jq -n --argjson n "$NOW" '{rate_limits:{five_hour:{used_percentage:26,resets_at:($n+13380)},seven_day:{used_percentage:30,resets_at:($n+300000)}}}' | COLUMNS=200 "$SL")
expect "each limit has its own verdict" "$out" "near pace.*7d.*on track"

echo "Sanitising"
reject "escape codes leave no residue"  "$(run '{"session_name":"a\u001b[31mred\u001b[0m b"}')" '\[31m'
printf '%s\n3\n%s\n\n' "$NOW" "$(printf 'agents \033[38;5 %0300d' 0)" > "$TMPDIR/cc-sl-$UID/agents-t-hang"
if perl -e 'alarm 5; exec @ARGV' "$SL" <<< '{"session_id":"t-hang"}' >/dev/null 2>&1; then ok "unterminated escape does not hang"
else bad "unterminated escape does not hang" "timed out or failed"; fi

echo "Subagents"
rows=$(jq -n --argjson n "$NOW" '{session_id:"t-sa", columns:120, tasks:[
  {id:"a", name:"local_agent", type:"ecc:code-reviewer", status:"running", startTime:($n-95), model:"claude-sonnet-5-5", effort:8000, contextWindowSize:200000, tokenCount:45000},
  {id:"b", name:"日本語エージェント", status:"completed", startTime:($n-900), description:"日本語の説明がとても長い説明文です、もっと長く長く長く長く長く長く長く長く"},
  {id:"c", status:"failed"}]}' | "$SA")
if printf '%s\n' "$rows" | jq -e . >/dev/null 2>&1 && [ "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" -eq 3 ]; then ok "one valid JSON row per agent"
else bad "one valid JSON row per agent" "$rows"; fi
expect "generic name → agent type"      "$(printf '%s\n' "$rows" | jq -r .content)" "code-reviewer"
expect "friendly model name"            "$(printf '%s\n' "$rows" | jq -r .content)" "sonnet 5.5:8.0k"
reject "finished agents stop counting"  "$(printf '%s\n' "$rows" | jq -r 'select(.id=="b") | .content')" "15m"
w=$(printf '%s\n' "$rows" | jq -r .content | maxw)
if [ "$w" -le 120 ]; then ok "rows fit the panel width ($w/120)"; else bad "rows fit the panel width" "$w/120"; fi
expect "agents line on the status line" "$(run '{"session_id":"t-sa"}')" "agents 1"

if command -v shellcheck >/dev/null; then
  echo "shellcheck"
  if shellcheck -S warning "$SL" "$SA"; then ok "shellcheck clean"; else bad "shellcheck"; fi
else
  echo "shellcheck: not installed, skipped (brew install shellcheck)"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
