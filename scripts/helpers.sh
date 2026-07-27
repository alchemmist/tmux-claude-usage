#!/usr/bin/env bash
# Shared helpers for the tmux segment. Sourced, not executed.

# Path to the cache file the statusLine harvester writes and the segment reads.
# Pinned under $HOME — not TMPDIR or XDG_CACHE_HOME — because the harvester runs
# in Claude Code's process and the segment runs in tmux's, and those two
# environments can differ. $HOME is the one variable they always agree on, so a
# fixed $HOME path guarantees both sides resolve the same file. Must match the
# path hardcoded in scripts/statusline.sh.
usage_cache_file() {
	printf '%s/.cache/claude-usage/usage' "$HOME"
}

# Path to the Codex cache. Lives beside the Claude one and is written by
# scripts/codex.sh, which scrapes usage out of Codex's own session rollout logs.
# Codex has no statusLine hook, so nothing pushes data at us the way Claude's
# harvester does — we poll instead, which is why that cache carries a TTL.
codex_cache_file() {
	printf '%s/.cache/claude-usage/codex' "$HOME"
}

# Read a tmux user option, falling back to a default when unset/empty.
get_tmux_option() {
	local option="$1" default="$2" value
	value="$(tmux show-option -gqv "$option" 2>/dev/null)"
	if [ -n "$value" ]; then
		printf '%s' "$value"
	else
		printf '%s' "$default"
	fi
}

# Render a text progress bar. Args: percent width full_char empty_char.
render_bar() {
	local pct="$1" width="$2" full="$3" empty="$4" filled i out=""
	filled=$(((pct * width + 50) / 100)) # rounded to nearest cell
	((filled < 0)) && filled=0
	((filled > width)) && filled=width
	for ((i = 0; i < filled; i++)); do out+="$full"; done
	for ((i = filled; i < width; i++)); do out+="$empty"; done
	printf '%s' "$out"
}

# Render the whole bar as one Nerd Font pie glyph (nf-md-circle_slice_1..8),
# for status lines where a multi-cell bar is too wide. Args: percent.
#
# Eight slices is the full resolution the glyph set offers, so the percent
# figure alongside carries the precision and the pie carries the at-a-glance
# read. Two edge cases are nudged away from plain rounding: any usage at all
# shows at least one slice (a non-empty budget must not look untouched), and the
# full circle is reserved for >=99% (so "nearly out" stays visually distinct
# from "out").
render_gauge() {
	local pct="$1" step
	local slices=('󰪞' '󰪟' '󰪠' '󰪡' '󰪢' '󰪣' '󰪤' '󰪥')
	((pct < 0)) && pct=0
	((pct > 100)) && pct=100
	step=$(((pct * 8 + 50) / 100))
	((step == 0 && pct > 0)) && step=1
	((step == 8 && pct < 99)) && step=7
	if ((step == 0)); then
		get_tmux_option @claude_usage_gauge_empty '󰝦'
	else
		printf '%s' "${slices[$((step - 1))]}"
	fi
}

# Format seconds-until-reset as browser-style text: "4 hr 50 min", "2 days 3 hr".
human_reset() {
	local s="$1" d h m
	((s < 0)) && s=0
	d=$((s / 86400))
	h=$(((s % 86400) / 3600))
	m=$(((s % 3600) / 60))
	if ((d > 0)); then
		if ((h > 0)); then
			printf '%d day%s %d hr' "$d" "$([ "$d" -ne 1 ] && printf s)" "$h"
		else
			printf '%d day%s' "$d" "$([ "$d" -ne 1 ] && printf s)"
		fi
	elif ((h > 0)); then
		if ((m > 0)); then printf '%d hr %d min' "$h" "$m"; else printf '%d hr' "$h"; fi
	else
		printf '%d min' "$m"
	fi
}

# Pick a color for a usage percentage based on the configured thresholds.
# Prints empty string when the relevant color option is unset (theme-agnostic).
pick_color() {
	local pct="$1" warn crit
	warn="$(get_tmux_option @claude_usage_warning_threshold 70)"
	crit="$(get_tmux_option @claude_usage_critical_threshold 90)"
	if ((pct >= crit)); then
		get_tmux_option @claude_usage_color_critical '#f7768e'
	elif ((pct >= warn)); then
		get_tmux_option @claude_usage_color_warning '#e0af68'
	else
		get_tmux_option @claude_usage_color_normal ''
	fi
}
