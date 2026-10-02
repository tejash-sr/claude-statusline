#!/bin/bash
# ~/.claude/subagent-statusline.sh
# 1. Renders each subagent row in the agent panel (stdout, one JSON object per row).
# 2. Writes an aggregate segment that ~/.claude/statusline.sh shows as its agents line
#    (cache file lines: written-at epoch, running count, segment, short segment).
# Deps: jq.

input=$(cat)
SID=$(printf '%s' "$input" | jq -r '.session_id // "nosession"' 2>/dev/null)
SID=${SID//[^A-Za-z0-9_-]/}; [ -n "$SID" ] || SID=nosession
TMP="${TMPDIR:-/tmp}"; TMP="${TMP%/}"
CACHE="$TMP/cc-agents-$SID"

JQ_LIB='
def C($n): "\u001b[38;5;\($n)m";
def RS: "\u001b[0m";
def rep($s; $n): if $n > 0 then ($s * $n) else "" end;
def clamp($v; $lo; $hi): if $v < $lo then $lo elif $v > $hi then $hi else $v end;
def tone($p):
  if   $p >= 90 then C(203)
  elif $p >= 75 then C(208)
  elif $p >= 50 then C(221)
  else               C(114) end;
def bar($p; $w):
  clamp(($p * $w / 100 | floor); 0; $w) as $f
  | rep("█"; $f) + rep("░"; $w - $f);
def kfmt($n):
  ($n | floor) as $n
  | if   $n >= 1000000 then "\(($n/1000000)|floor).\((($n%1000000)/100000)|floor)M"
    elif $n >= 10000   then "\(($n/1000)|floor)k"
    elif $n >= 1000    then "\(($n/1000)|floor).\((($n%1000)/100)|floor)k"
    else "\($n)" end;
def secs($t):
  if   ($t|type) == "number" then (if $t > 100000000000 then $t/1000 else $t end)
  elif ($t|type) == "string" then
        ( (try ($t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null)
       // (try ($t | tonumber | if . > 100000000000 then ./1000 else . end) catch null) )
  else null end;
def el($t):
  secs($t) as $s
  | if $s == null then "" else ((now - $s) | floor) as $d
    | if   $d < 0     then "0s"
      elif $d >= 3600 then "\(($d/3600)|floor)h\((($d%3600)/60)|floor)m"
      elif $d >= 60   then "\(($d/60)|floor)m\(($d%60)|floor)s"
      else "\($d)s" end end;
def glyph($s):
  if   $s == "running"   then "▶"
  elif $s == "completed" then "✔"
  elif $s == "failed"    then "✖"
  elif $s == "stopped"   then "■"
  elif $s == "pending"   then "…"
  else "·" end;
def scol($s):
  if   $s == "running"   then C(109)
  elif $s == "completed" then C(114)
  elif $s == "failed"    then C(203)
  else C(245) end;
def shortmodel: (. // "") | tostring | sub("^claude-"; "") | sub("-[0-9]{8}$"; "") | sub("-latest$"; "");
# effort is a level string or a numeric token budget
def effort: if . == null then "" elif type == "number" then kfmt(.) else tostring end;
def pct($t): (($t.contextWindowSize // 0) as $cw | ($t.tokenCount // 0) as $tk
              | if $cw > 0 then clamp(($tk * 100 / $cw | floor); 0; 999) else -1 end);
def clean: tostring | gsub("[\u0000-\u001f\u007f-\u009f]"; " ") | gsub("\\s+"; " ");
def clip($n): if length > $n then .[0:$n-1] + "…" else . end;
'

# ---------- 1. per-row output ----------
printf '%s' "$input" | jq -c "$JQ_LIB"'
(.columns // 100) as $cols
| (.tasks // [])[]
| . as $t
| ($t.status // "")                        as $st
| (($t.name // $t.type // "agent") | clean | clip(28)) as $nm
| ($t.tokenCount // 0)                     as $tok
| pct($t)                                  as $p
| ($t.model | shortmodel)                  as $md
| ($t.effort | effort)                     as $ef
| (if ($md|length) > 0 then $md + (if ($ef|length) > 0 then ":" + $ef else "" end) else "" end) as $mdl
| el($t.startTime)                         as $age
| (if $p >= 0 then bar($p; 6) + " " + ($p|tostring) + "%" else "" end) as $bar
| ([ glyph($st), $nm, $mdl, $bar, (if $tok > 0 then kfmt($tok) else "" end), $age ]
   | map(select(length > 0)) | join("  ")) as $plain
| ([ scol($st) + glyph($st) + RS,
     C(110) + $nm + RS,
     (if ($mdl|length) > 0 then C(245) + $mdl + RS else "" end),
     (if $p >= 0 then tone($p) + bar($p; 6) + " " + ($p|tostring) + "%" + RS else "" end),
     (if $tok > 0 then C(180) + kfmt($tok) + RS else "" end),
     (if ($age|length) > 0 then C(245) + $age + RS else "" end)
   ] | map(select(length > 0)) | join("  ")) as $rich
| (($t.description // $t.label // "") | clean) as $desc
| ($cols - ($plain|length) - 4) as $room
| (if ($desc|length) > 0 and $room > 10
   then "  " + C(245) + "· " + (if ($desc|length) > $room then ($desc[0:$room-1] + "…") else $desc end) + RS
   else "" end) as $tail
| { id: $t.id, content: ($rich + $tail) }
' 2>/dev/null

# ---------- 2. aggregate segment for the main status line ----------
printf '%s' "$input" | jq -r "$JQ_LIB"'
(.columns // 100) as $cols
| (if $cols >= 150 then 3 elif $cols >= 115 then 2 else 1 end)  as $show
| (.tasks // [])                                                as $all
| ($all | map(select((.status // "") == "running")))            as $run
| ($all | map(select((.status // "") == "completed")) | length) as $done
| ($all | map(select((.status // "") == "failed"))    | length) as $fail
| ($all | map(.tokenCount // 0) | add // 0)                     as $tot
| ($run | length)                                               as $n
| ($run | sort_by(-(.tokenCount // 0))[0:$show] | map(
      ((.name // .type // "agent") | clean | if length > 18 then .[0:17] + "…" else . end) as $nm
      | pct(.) as $p
      | C(109) + "▶" + RS + " " + C(110) + $nm + RS
        + (if $p >= 0 then " " + tone($p) + bar($p; 4) + " " + ($p|tostring) + "%" + RS else "" end)
        + (if (.tokenCount // 0) > 0 then " " + C(245) + kfmt(.tokenCount) + RS else "" end)
        + (if (el(.startTime)|length) > 0 then " " + C(245) + el(.startTime) + RS else "" end)
   ) | join(" " + C(245) + "│" + RS + " ")) as $rows
| (now | floor | tostring),
  ($n | tostring),
  ( if $n == 0 then ""
    else C(245) + "agents" + RS + " " + C(109) + ($n|tostring) + RS
         + (if $done > 0 then " " + C(114) + "✔" + ($done|tostring) + RS else "" end)
         + (if $fail > 0 then " " + C(203) + "✖" + ($fail|tostring) + RS else "" end)
         + " " + C(245) + "│" + RS + " " + $rows
         + (if $n > $show then " " + C(245) + "+" + (($n - $show)|tostring) + RS else "" end)
         + " " + C(245) + "│" + RS + " " + C(245) + kfmt($tot) + " tok" + RS
    end ),
  # short form for narrow terminals: count and the largest agent only
  ( if $n == 0 then ""
    else ($run | sort_by(-(.tokenCount // 0))[0]) as $top
      | pct($top) as $p
      | C(245) + "agents" + RS + " " + C(109) + ($n|tostring) + RS + " "
        + C(109) + "▶" + RS + " " + C(110) + (($top.name // $top.type // "agent") | clean | clip(14)) + RS
        + (if $p >= 0 then " " + tone($p) + ($p|tostring) + "%" + RS else "" end)
        + (if $n > 1 then " " + C(245) + "+" + (($n - 1)|tostring) + RS else "" end)
    end )
' > "$CACHE.$$" 2>/dev/null && mv -f "$CACHE.$$" "$CACHE" 2>/dev/null
rm -f "$CACHE.$$" 2>/dev/null

exit 0
