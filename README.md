# claude-statusline

A fast, information-dense status line for [Claude Code](https://code.claude.com), plus a
custom row renderer for the subagent panel.

```
Opus 5.5:medium │ ~/Documents/project │ ⎇ main* +1 ~2 ?1 ↑1 │ #1234 ✓ │ "refactor auth middleware"
ctx   ██████░░░░░░░░░░░░░░ 34% 344k/1M │ ● cache 96% hit · cold in 57m · 3 misses │ ~$7.43 │ ⏱ 28m active │ +412/-87
5h    ██████░░░░░░░┃░░░░░░ 30% ⏲ 7:10 PM (1h23m) ✓ on track │ 7d    ██████████┃░░░░░░░░░ 50% ⏲ Mon 1:30 AM ✓ on track
agents 2 ✔1 │ ▶ code-reviewer █░░░ 41% 82k 1m36s │ ▶ Explore █░░░ 18% 36k 40s │ 118k tok
```

A fifth line of `▲` warnings appears only when something needs attention.

## What it shows

| Line | Contents |
|---|---|
| 1 · identity | model and effort, fast mode, home-relative directory, git (branch with a `*` when dirty; staged, modified, untracked, stash, ahead/behind, conflicts), worktree, PR status, agent, vim mode, session name |
| 2 · session | context bar, prompt cache (hit rate, time until it goes cold, session misses), estimated cost, active time, lines changed, compactions |
| 3 · limits | 5-hour, 7-day and spend limits, like Claude's usage page: % used, reset time, an elapsed-time tick on the bar, and a verdict for each limit (`✓ on track`, `≈ near pace`, or `⇡out in 2h02m` when you'll run out well before the reset). A window whose reset has passed shows `reset · new window` until fresh numbers arrive |
| 4 · agents | running subagents, largest first, with context use, tokens and age. Agents with Claude Code's generic name (`local_agent`) are labelled by their type (`code-reviewer`) |
| 5 · warnings | only when needed: context getting large, limits near the cap or on pace to run out, cache about to go cold, merge conflicts, branch behind upstream |

**Colours mean something.**

- **Limits** are coloured by pace: the projected usage at the reset at the current rate
  (used% ÷ elapsed% of the window). Under 100% is green `✓ on track`; 100% or more is yellow
  `≈ near pace`; running out at least 10% of the window before the reset (30 min of 5h) is
  orange or red with `⇡out in …` and a warning, so a near tie doesn't flicker into an alarm.
  At 90% used a limit is red regardless. Pace waits until 20% of the window has passed and
  20% is used; before that plain % decides.
- **Context**: the bar follows % of the window (50/75/90%); the token count is coloured by
  absolute size (300k/500k/750k), so a 1M window at 34% still shows a 344k-token prompt.
  The `/compact` warning appears only at 75% of the window or a red size.

Each line is fitted to the terminal width: segments first shrink (session title, then the
path to a project-relative name), then the least important drop. The branch is never dropped.

## Design notes

- **Fast.** About 12 ms per redraw: one `jq` pass (reset times are formatted there too),
  and helpers that return through variables instead of `$(...)` subshells.
- **Scales.** Git runs once per 5 s per directory, shared by every session in that repo,
  lock-free (`--no-optional-locks`). A repo whose `git status` takes over 150 ms is marked
  slow and switches to `-uno` (skipping untracked files) with a 15 s refresh, and is
  re-measured in full every 5 minutes so a one-off slow run doesn't stick. The transcript
  is scanned incrementally from the last byte offset, so a 4-hour session costs the same
  as a 4-minute one.
- **Local only.** Data comes from Claude Code's stdin JSON, git, and the session
  transcript. No network calls.
- **Robust.** Missing, `null` or malformed input never breaks the layout. Text from git, names
  and cache files is stripped of escape and control sequences before it reaches the terminal.
- **Private caches.** Cache files live in a `0700` directory owned by you
  (`$XDG_RUNTIME_DIR` or `$TMPDIR`, then `/cc-sl-$UID`, falling back to
  `~/.cache/cc-statusline`), so a shared `/tmp` can't be used to tamper with them.
  Files untouched for a week are removed once a day.
- **Locale-safe.** The script picks the first UTF-8 locale available, so character widths
  stay right on systems without `en_US.UTF-8`.
- **Portable.** Bash 3.2 (stock macOS) and 256 colours; no Nerd Font required.

## Install

Requires `jq` 1.6 or later built with Oniguruma regex support (Homebrew and most distro
packages are), `git`, and `perl` (preinstalled on macOS and most Linux).

```sh
cp statusline.sh subagent-statusline.sh ~/.claude/
chmod +x ~/.claude/statusline.sh ~/.claude/subagent-statusline.sh
```

Add to `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "~/.claude/statusline.sh",
  "padding": 0,
  "refreshInterval": 3
},
"subagentStatusLine": {
  "type": "command",
  "command": "~/.claude/subagent-statusline.sh"
}
```

`refreshInterval` keeps countdowns and the agents line live while the session is idle.

## Configuration

Thresholds live at the top of `statusline.sh`:

```sh
TONE_YEL=50; TONE_ORG=75; TONE_RED=90       # % thresholds (context; limits with no window)
CTX_YEL=300000; CTX_ORG=500000; CTX_RED=750000   # absolute context size, tokens (matters on 1M windows)
PACE_RED=130                                # projected % at reset at which a run-out turns red
PACE_MARGIN_PCT=10                          # run-out counts only this % of the window before the reset
PACE_MIN=900                                # seconds into a window before pace counts
PACE_MIN_PCT=20                             # …and % of the window (1h of 5h, ~34h of 7d)
PACE_ALARM=20                               # % used before pace counts at all (colour, verdict, ⇡out, warning)
COST_YEL=100; COST_ORG=500; COST_RED=2000   # cents (API-key users; dimmed on a plan)
GIT_TTL=5                                   # seconds between git refreshes
GIT_SLOW_MS=150                             # slower than this → skip untracked files (-uno)
GIT_SLOW_TTL=15                             # refresh interval once a repo is marked slow
GIT_SLOW_RECHECK=300                        # seconds before a slow repo is re-measured in full
RECACHE_WARN=20000                          # tokens; warn when a cold cache costs more
```

## Tests

```sh
tests/run.sh                                                          # the scripts in this repo
SL=~/.claude/statusline.sh SA=~/.claude/subagent-statusline.sh tests/run.sh   # the installed ones
```

Covers bad input, width fitting from 20 to 200 columns (with wide characters), context and
limit colouring, resets, sanitising and the subagent rows. Runs in a throwaway `TMPDIR`, and
runs `shellcheck` too when it is installed.
