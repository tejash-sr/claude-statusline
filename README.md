# claude-statusline

A fast, information-dense status line for [Claude Code](https://code.claude.com), plus a
custom row renderer for the subagent panel.

```
Opus 5.5:medium │ ~/Documents/project │ ⎇ main +1 ~2 ?1 ↑1 │ #1234 ✓ │ "refactor auth middleware"
ctx ████░░░░░░░░░░░░░░░░ 24% 243k/1M │ ● cache 96% cold in 57m 3 misses │ ~$7.43 │ ⏱ 28m active │ +412/-87
5h  ███░░░░░░░░░░░░░░░░░ 18% ⏲ 3h34m │ 7d  ██████████░░░░░░░░░░ 50% ⏲ 2d9h
agents 2 ✔1 │ ▶ code-reviewer █░░░ 41% 82k 1m36s +1 │ 131k tok
▲ context 78% — /compact soon │ ▲ 7d limit 91% · resets 3d5h
```

## What it shows

| Line | Contents |
|---|---|
| 1 · identity | model and effort, fast mode, home-relative directory, git (branch, staged, modified, untracked, stash, ahead/behind, conflicts), worktree, PR status, agent, vim mode, session name |
| 2 · session | context bar, prompt cache (hit rate, time until it goes cold, misses), estimated cost, active time, lines changed, compactions |
| 3 · limits | 5-hour, 7-day and spend limits with bars, reset countdown, and a pace projection (`⇡out 2h02m`) when you'll run out before the reset |
| 4 · agents | running subagents, largest first, with context use, tokens and age |
| 5 · warnings | only when needed: context at 75/90%, limits high or on pace to run out, cache about to go cold, merge conflicts, branch behind upstream |

Bars and percentages turn yellow at 50%, orange at 75% and red at 90%. Each line is fitted
to the terminal width by dropping its least important segments, so nothing wraps.

## Design notes

- **Fast.** About 12 ms per redraw: one `jq` pass, git cached for 3 s, and helpers that
  return through variables instead of `$(...)` subshells.
- **Local only.** Data comes from Claude Code's stdin JSON, one lock-free
  `git status --porcelain=v2` call (`--no-optional-locks`), and the session transcript.
  No network calls.
- **Robust.** Missing, `null` or malformed input never breaks the layout.
- **Portable.** Bash 3.2 (stock macOS) and 256 colours; no Nerd Font required.

## Install

Requires `jq` and `git`.

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
TONE_YEL=50; TONE_ORG=75; TONE_RED=90       # % thresholds for context and limits
COST_YEL=100; COST_ORG=500; COST_RED=2000   # cents (API-key users; dimmed on a plan)
GIT_TTL=3                                   # seconds between git refreshes
RECACHE_WARN=20000                          # tokens; warn when a cold cache costs more
```
