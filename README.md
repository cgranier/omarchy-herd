# Herd

Live state of every [herdr](https://herdr.dev) coding agent — on this machine and on your saved remote
machines — in the Omarchy bar.

`omarchy.agents` tells you how much of your subscription you've burned. Herd tells you **which agent needs
you right now**, wherever it's running.

## Features

- Bar label shows only what matters: blocked, working, and done counts (just the icon when all is quiet).
  Turns the bar's urgent color while any agent is blocked.
- Panel lifts every agent that needs you (blocked first, then done) into a **NEEDS YOU** section on top, then
  groups the rest by machine with status, time in state, and working directory. Idle agents fold into one
  expandable row per machine, so a big quiet fleet stays a short list.
- Toast when an agent becomes **blocked** or **done**. Click it to jump straight to that agent. Optionally let
  blocked toasts break through Do Not Disturb.
- Jumping focuses the agent's pane inside herdr, then raises the terminal window attached to that herdr
  session — or opens one (`herdr --remote <host>` for remote machines) when none is attached.
- Remote machines come from `herdr machine list`. Each is polled independently with a timeout and
  exponential backoff, so an offline box never stalls the rest.
- Clear error states: herdr missing, client older than server (`protocol_mismatch`), server not running,
  machine unreachable.

## Interactions

| Where | Input | Action |
|---|---|---|
| Bar | left click | open panel |
| Bar | right click | jump to the first blocked (else done) agent |
| Bar | middle click | refresh now |
| Panel | `j` / `k` / arrows | move cursor |
| Panel | `enter` / click | jump to agent, or fold/unfold an idle group |
| Panel | `b` | jump to the next agent that needs you |
| Panel | `r` | refresh |
| Panel | `esc` | close |

## Install

```bash
omarchy plugin add <this-repo-url> --enable
```

Requires `herdr` (shipped in the Omarchy repo), `jq`, and `hyprctl`.

## Settings

Edit from the bar's widget settings, or inline on the `cgranier.herd` entry in `~/.config/omarchy/shell.json`.

| Key | Default | Meaning |
|---|---|---|
| `herdrPath` | `""` | herdr binary. Empty = `~/.local/bin/herdr` if present, else `herdr` on PATH. |
| `includeLocal` | `true` | Include this machine's herdr server. |
| `machines` | `""` | Comma-separated machine labels. Empty = every enabled machine; `none` = local only. |
| `refreshIntervalSec` | `20` | Remote poll interval. Local changes arrive instantly over the herdr event socket (with a 30 s safety poll; 5 s if the socket is unavailable). |
| `notifyBlocked` | `true` | Toast when an agent starts waiting on you. |
| `notifyDone` | `true` | Toast when an agent finishes. |
| `blockedBypassesDnd` | `false` | Send blocked toasts as critical alerts that show even under Do Not Disturb. |
| `collapseIdle` | `true` | Fold each machine's idle agents into one expandable row. |
| `hideWhenEmpty` | `false` | Hide the bar widget while no agents are running. |

**Why `herdrPath` prefers `~/.local/bin`:** `herdr update` installs there, so it is often newer than the
packaged `/usr/bin/herdr`. The shell's PATH may resolve the packaged one, and an older client is refused by a
newer server with `protocol_mismatch`.

## IPC

```bash
omarchy-shell shell toggle cgranier.herd '{}'   # open/close the panel (bind this to a key)
omarchy-shell cgranier.herd status              # "1 blocked · 2 working · 3 machines"
omarchy-shell cgranier.herd counts              # JSON counts, handy for scripts
omarchy-shell cgranier.herd refresh
omarchy-shell cgranier.herd testToast           # send a sample "needs you" toast through the real path
omarchy-shell cgranier.herd debug               # baselined / notifier / herdrPath / lastAnnounced
```

No toast? Check Do Not Disturb first (`omarchy-shell notifications isDnd`). Herd respects it by default; silenced
toasts still land in notification history, and the bar's urgent color keeps working. With `blockedBypassesDnd` on,
blocked toasts use the one path Omarchy lets through DND (critical urgency under the `notify-send` identity), which
also means they stay on screen until dismissed and are not kept in history.

## Development

```
manifest.json       plugin declaration + settings schema
Panel.qml           bar button + popup (entry point)
Service.qml         discovery, aggregation, notifications
MachinePoller.qml   one `herdr agent list` poller per machine
EventStream.qml     local herdr socket subscription; nudges the local poll on every event
Model.js            pure parsing/shaping logic (no QML imports)
bin/herd-focus      jump-to-agent helper (HERD_FOCUS_DRY=1 to dry-run)
tests/              node tests + synthetic fixtures
```

```bash
node tests/model.test.js
omarchy plugin validate .
```

QML files hot-reload on save. Newly added IPC functions and **`Model.js` do not** — the QML engine caches JS imports, so run
`omarchy restart shell` after changing it.

## License

MIT
