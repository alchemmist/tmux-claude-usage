![demo](https://github.com/docker-run/tmux-claude-usage/releases/download/media/demo.gif)

[![Download](https://img.shields.io/badge/Download-v1.1.0-2ea44f)](https://github.com/docker-run/tmux-claude-usage/releases/latest)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Build](https://github.com/alchemmist/tmux-claude-usage/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/alchemmist/tmux-claude-usage/actions/workflows/shellcheck.yml)

Your Claude usage — progress bar, percent, and reset time — right in the tmux status bar. It uses the official usage data Claude Code already receives — no API calls, no tokens, no rate limits — and updates live as you work.

> **This is a fork** of [docker-run/tmux-claude-usage](https://github.com/docker-run/tmux-claude-usage)
> that adds two things:
>
> - **Codex weekly usage** alongside Claude, read straight out of Codex CLI's own
>   session logs — see [Codex](#codex).
> - **A `gauge` render style** that collapses the bar into a single Nerd Font pie
>   glyph, so two assistants fit in a status line without crowding out the window
>   list — see [Render styles](#render-styles).
>
> Everything upstream does still works unchanged; both additions are off by
> default.

## Contents

- [How it works](#how-it-works)
- [Render styles](#render-styles)
- [Codex](#codex)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Update frequency](#update-frequency)
- [Contribution](#contribution)
- [License](#license)

## How it works

Two small pieces:

1. **Harvester** — a Claude Code [status line](https://code.claude.com/docs/en/statusline)
   command. Claude hands it official session data (including `rate_limits`) on
   every render; it writes your usage to a cache file and **prints nothing**, so
   no line appears inside the pane.
2. **Segment** — a tiny script your tmux status line calls. It reads that cache
   and renders the bar. Pure bash, no network.

Because the data comes from Claude itself, it's free and accurate, and refreshes
whenever Claude renders — continuously while you work.

Codex works the other way round — see [Codex](#codex).

## Render styles

`@claude_usage_style` picks how a window is drawn:

| Style | Looks like | Width |
| --- | --- | --- |
| `bar` (default) | `██████░░░░ 62% used · resets in 4 hr` | ~36 cells |
| `gauge` | `󰪢 62%` | ~7 cells |

`gauge` replaces the multi-cell bar with one `nf-md-circle_slice` glyph, so it
needs a [Nerd Font](https://www.nerdfonts.com/) v3+. Eight slices is all the
glyph set offers, so the pie carries the at-a-glance read and the percent beside
it carries the precision. Two cases are nudged away from plain rounding: any
usage at all shows at least one slice, and the full circle is reserved for
`>= 99%`, keeping "nearly out" visually distinct from "out".

Tag each window so you can tell them apart — `@claude_usage_icon` and
`@claude_usage_codex_icon` take any string, an icon or a plain word:

```tmux
set -g @claude_usage_style       gauge
set -g @claude_usage_icon        claude
set -g @claude_usage_codex_icon  codex
```

```
claude 󰪞 6%  codex 󰪤 91%
```

Labels keep a steady colour while the reading alone tracks the thresholds —
otherwise a segment goes fully red and buries the part that actually changed.
Tune it with `@claude_usage_label_color`, or set it to `none` to leave labels
unstyled and inherit the status line.

Add the time until reset with `@claude_usage_show_reset on`. In `gauge` style
it's rendered compactly — `1d 3h 38m`, `3h 20m`, `5m` — keeping every non-zero
unit down to minutes:

```
claude 󰪢 66% 32m  codex 󰪤 91% 4d 21h 2m
```

## Codex

Codex CLI has no status line hook, so nothing can push usage at us the way
Claude's harvester does. What it does have is a rollout log per session under
`$CODEX_HOME/sessions`, where every `token_count` event carries the server's
`rate_limits` block — so this plugin polls that instead.

Turn it on with:

```tmux
set -g @claude_usage_codex on
```

Only the **weekly** window is shown. Codex splits usage across `primary` and
`secondary`, and which one is the weekly budget depends on the plan — on Plus it
arrives as `primary` with no secondary at all. So the window is picked by length
(anything at least a day long) rather than by field name. If a plan only reports
a short window, nothing is drawn rather than a 5-hour figure mislabelled as
weekly.

Reading the logs is deliberately cheap: they're read from the end so a
multi-megabyte rollout isn't streamed front to back, only the five most recently
modified sessions are consulted, results are cached for 60s, and the scrape runs
in the background so a slow disk never stalls a redraw.

## Requirements

- `tmux` 3.0+
- `jq`
- Claude Code, signed in with a **Claude Pro or Max** subscription. The usage
  data (`rate_limits`) is sent only to Pro/Max sessions.
- For `@claude_usage_codex on`: Codex CLI on a plan whose responses include
  `rate_limits`.
- For `@claude_usage_style gauge`: a Nerd Font v3+.

## Installation

**1. Add the plugin** via [TPM](https://github.com/tmux-plugins/tpm):

```tmux
set -g @plugin 'alchemmist/tmux-claude-usage'
```

**2. Place the segment** in your status line:

```tmux
set -g status-right '#{claude_usage}  %Y-%m-%d %H:%M'
```

**3. Fetch and wire it up** — press `prefix + I` (TPM clones the plugin), then
run the installer once (from inside tmux, so it can locate the clone):

```sh
bash "$(tmux show-environment -g TMUX_PLUGIN_MANAGER_PATH | cut -d= -f2-)tmux-claude-usage/scripts/init.sh"
```

`init.sh` adds the status line command to Claude Code's `settings.json` (under
`~/.claude`, or `$CLAUDE_CONFIG_DIR` if you've set one), backing it up first.
Use Claude Code normally and the bar fills in.

> Already have a Claude status line? `init.sh` keeps it: it chains your line and
> the harvester through the single slot, so both run and your line still shows.
> Use `--force` to install only the harvester instead, or `--uninstall` to
> restore your original line.
>
> **Ordering matters.** Claude Code has only **one** status-line slot. If you set
> up another status-line tool (e.g.
> [ccstatusline](https://github.com/sirmalloc/ccstatusline)) _after_ this — or
> re-run its configurator later — it overwrites the slot and the usage bar
> silently stops updating. Just re-run `init.sh` to re-chain (it picks the other
> tool back up), or run `init.sh --check` to diagnose.

### Without TPM

Clone it anywhere and source the entry point from your `tmux.conf`:

```sh
git clone https://github.com/alchemmist/tmux-claude-usage \
  ~/.tmux/plugins/tmux-claude-usage
```

```tmux
run-shell ~/.tmux/plugins/tmux-claude-usage/claude-usage.tmux
```

Then place `#{claude_usage}` in your status line (step 2) and run that clone's
`scripts/init.sh` (step 3).

### Uninstall

```sh
bash "$(tmux show-environment -g TMUX_PLUGIN_MANAGER_PATH | cut -d= -f2-)tmux-claude-usage/scripts/init.sh" --uninstall
```

Restores any status line it chained, removes the harvester from Claude's
`settings.json`, and deletes the usage cache. To remove the plugin entirely,
also drop the `@plugin` line and `#{claude_usage}` from your tmux config and run
TPM clean (`prefix + alt + u`).

## Configuration

Out of the box the segment shows the 5-hour
session window, inherits your theme's color normally, and turns **amber** then
**red** as you approach your limit. Everything below is tunable — for example,
override the colors to match your theme (hex values or tmux color names both work).

| Option | Default | Description |
| --- | --- | --- |
| `@claude_usage_show` | `session` | `session`, `weekly`, or `all` |
| `@claude_usage_style` | `bar` | `bar` or `gauge` — see [Render styles](#render-styles) |
| `@claude_usage_icon` | _(empty)_ | Label before the Claude reading |
| `@claude_usage_codex` | `off` | Append Codex weekly usage — see [Codex](#codex) |
| `@claude_usage_codex_icon` | _(empty)_ | Label before the Codex reading |
| `@claude_usage_label_color` | _(`color_normal`)_ | Colour for labels; `none` inherits the status line |
| `@claude_usage_gauge_empty` | `󰝦` | Glyph for 0% in `gauge` style |
| `@claude_usage_show_bar` | `on` | Show the progress bar (`bar` style only) |
| `@claude_usage_bar_width` | `10` | Bar width in cells |
| `@claude_usage_bar_full` | `█` | Filled bar character |
| `@claude_usage_bar_empty` | `░` | Empty bar character |
| `@claude_usage_show_reset` | `on` | Show "resets in …" |
| `@claude_usage_show_label` | `off` | Prefix "Session"/"Week" (auto-on for `all`) |
| `@claude_usage_session_label` | `Session` | Label for the 5-hour window |
| `@claude_usage_weekly_label` | `Week` | Label for the 7-day window |
| `@claude_usage_prefix` | _(empty)_ | Text/icon before the segment |
| `@claude_usage_separator` | `  ` | Between windows in `all` mode |
| `@claude_usage_stale_after` | _(off)_ | Seconds; flag the bar stale once the cache is older than this |
| `@claude_usage_stale_label` | `stale` | Word used in the stale marker |
| `@claude_usage_warning_threshold` | `70` | % for the `warning` color |
| `@claude_usage_critical_threshold` | `90` | % for the `critical` color |
| `@claude_usage_color_normal` | _(theme)_ | Color below the warning threshold |
| `@claude_usage_color_warning` | `#e0af68` | Color at/above warning |
| `@claude_usage_color_critical` | `#f7768e` | Color at/above critical |

### Match the demo

The powerline look in the demo above is a full Tokyo Night Storm status-bar
theme, **not** part of the plugin — the plugin only contributes the
`#{claude_usage}` segment. For that exact look, check out
[`examples/tokyo-night-storm.conf`](examples/tokyo-night-storm.conf).

## Update frequency

The bar repaints every `status-interval` seconds (standard tmux setting, default
15). Lower it for a snappier bar — it just re-reads a local file, so it's free:

```tmux
set -g status-interval 5
```

Repainting isn't the same as refreshing, though: the underlying numbers only
update when **Claude Code** renders and hands the harvester fresh data. Usage you
rack up elsewhere — the browser, another machine — won't appear until a local
Claude Code session renders again, so a number can sit unchanged while the real
figure climbs. There's no token-free way to fetch it on demand. To avoid mistaking
a stale figure for a live one, set `@claude_usage_stale_after` and the bar appends
e.g. `(stale 2 hr)` once the cache passes that age:

```tmux
set -g @claude_usage_stale_after 1800  # mark stale after 30 min
```

Codex doesn't have that problem in the same way: because it's polled rather than
pushed, the numbers come from whatever the last Codex turn recorded, and a
re-scrape happens at most once a minute. The staleness marker tracks the Claude
cache only.

## Contribution

See the [CONTRIBUTION.md](CONTRIBUTION.md) file.

## License

[MIT](LICENSE)
