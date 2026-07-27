#!/usr/bin/env bash
#
# tmux segment — reads the harvested usage caches and renders the status bar
# text for Claude and (optionally) Codex. Pure bash, no network, no jq; runs on
# every status-line redraw.
#
# Two render styles: the original multi-cell `bar`, and `gauge`, which collapses
# the whole bar into a single Nerd Font pie glyph so several assistants fit in a
# status line without crowding out the window list.

set -uo pipefail

# Parse numbers in the C locale regardless of the tmux server's environment.
# used_percentage is a dot-decimal float (e.g. 57.999…); under a comma-radix
# locale (de_DE, fr_FR, pt_BR, …) the printf '%.0f' below fails to parse it,
# drops the window, and leaves a silent empty bar. Set as a variable (not a
# command prefix) so bash 3.2 — macOS's /usr/bin/env bash — re-runs setlocale;
# the prefix form does nothing there. The segment emits only ASCII, raw UTF-8
# glyph bytes and tmux style escapes, so forcing C has no other effect.
export LC_ALL=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$DIR/helpers.sh"

# Options
show="$(get_tmux_option @claude_usage_show session)" # session | weekly | all
style="$(get_tmux_option @claude_usage_style bar)"   # bar | gauge
bar_width="$(get_tmux_option @claude_usage_bar_width 10)"
bar_full="$(get_tmux_option @claude_usage_bar_full '█')"
bar_empty="$(get_tmux_option @claude_usage_bar_empty '░')"
show_bar="$(get_tmux_option @claude_usage_show_bar on)"
show_reset="$(get_tmux_option @claude_usage_show_reset on)"
show_label="$(get_tmux_option @claude_usage_show_label off)"
session_label="$(get_tmux_option @claude_usage_session_label 'Session')"
weekly_label="$(get_tmux_option @claude_usage_weekly_label 'Week')"
prefix="$(get_tmux_option @claude_usage_prefix '')"
separator="$(get_tmux_option @claude_usage_separator '  ')"
stale_after="$(get_tmux_option @claude_usage_stale_after '')"
stale_label="$(get_tmux_option @claude_usage_stale_label 'stale')"
icon="$(get_tmux_option @claude_usage_icon '')"
# Labels hold steady while the reading changes colour. Defaults to the normal
# (below-threshold) colour, so out of the box a label looks like an unremarkable
# reading rather than an alarming one. Set it to "none" to leave labels unstyled
# and inherit the status line — an empty value can't say that, since tmux gives
# an option set to "" and an option never set the same way.
label_color="$(get_tmux_option @claude_usage_label_color "$(get_tmux_option @claude_usage_color_normal '')")"
[ "$label_color" = none ] && label_color=""
codex="$(get_tmux_option @claude_usage_codex off)" # off | on — show Codex weekly
codex_icon="$(get_tmux_option @claude_usage_codex_icon '')"

now="$(date +%s)"

# Kick off a Codex refresh before rendering. Backgrounded and detached: the
# scrape walks session logs off disk, and the status line must not wait on it.
# This render uses whatever is already cached; the next one picks up the result.
if [ "$codex" = on ] && [ -x "$DIR/codex.sh" ]; then
	("$DIR/codex.sh" >/dev/null 2>&1 &) 2>/dev/null
fi

# Load harvested values without sourcing (no code execution from cache files).
five_pct="" five_reset="" seven_pct="" seven_reset="" updated_at=""
codex_pct="" codex_reset=""

read_cache() {
	local file="$1" key val
	[ -f "$file" ] || return 0
	while IFS='=' read -r key val; do
		case "$key" in
		FIVE_HOUR_PCT) five_pct="$val" ;;
		FIVE_HOUR_RESET) five_reset="$val" ;;
		SEVEN_DAY_PCT) seven_pct="$val" ;;
		SEVEN_DAY_RESET) seven_reset="$val" ;;
		CODEX_WEEK_PCT) codex_pct="$val" ;;
		CODEX_WEEK_RESET) codex_reset="$val" ;;
		UPDATED_AT) updated_at="$val" ;;
		esac
	done <"$file"
}

# Claude first, so its UPDATED_AT is the one the staleness marker reports —
# that marker documents the harvester, which only Claude has.
read_cache "$(usage_cache_file)"
claude_updated_at="$updated_at"
[ "$codex" = on ] && read_cache "$(codex_cache_file)"
updated_at="$claude_updated_at"

# Build one window's text. Args: percent reset_epoch label icon.
window_segment() {
	local pct_raw="$1" reset_epoch="$2" label="$3" seg_icon="${4:-}"
	[ -n "$pct_raw" ] || return 1

	local pct
	printf -v pct '%.0f' "$pct_raw" 2>/dev/null || return 1

	# Only trust reset_epoch if it's a plain epoch integer (guards against a
	# future payload handing us an ISO string, which would break the maths).
	local have_reset=0
	[[ "$reset_epoch" =~ ^[0-9]+$ ]] && have_reset=1

	# Self-expiring cache: once the window's reset time has passed, it has
	# provably rolled over to a fresh window. The harvester only refreshes while
	# Claude renders, so an idle cache would otherwise show stale numbers — but
	# we know the truth locally: usage is back to 0% and there's no active
	# window to count down to. No probing or timer needed.
	if [ "$have_reset" = 1 ] && [ "$now" -ge "$reset_epoch" ]; then
		pct=0
		have_reset=0
	fi

	# Split into two runs so they can be coloured independently: the name tags
	# (which assistant, which window) versus the reading itself. The threshold
	# colour is a signal about how much budget is left, so letting it bleed into
	# a static label makes the whole segment flash red and buries the one part
	# that actually changed.
	local names=() parts=()
	[ -n "$seg_icon" ] && names+=("$seg_icon")

	if [ "$style" = gauge ]; then
		# Compact form: label, pie, percent. The window name is dropped unless
		# asked for explicitly — spelling out "Session" defeats the style.
		[ "$show_label" = on ] && [ -n "$label" ] && names+=("$label")
		parts+=("$(render_gauge "$pct")")
		parts+=("${pct}%")
		[ "$show_reset" = on ] && [ "$have_reset" = 1 ] &&
			parts+=("$(human_reset $((reset_epoch - now)))")
	else
		{ [ "$show_label" = on ] || [ "$show" = all ]; } && [ -n "$label" ] && names+=("$label")
		[ "$show_bar" = on ] && parts+=("$(render_bar "$pct" "$bar_width" "$bar_full" "$bar_empty")")
		parts+=("${pct}% used")
		[ "$show_reset" = on ] && [ "$have_reset" = 1 ] &&
			parts+=("· resets in $(human_reset $((reset_epoch - now)))")
	fi

	# Emit the label run first, always in its own steady colour. An unset
	# label colour means "inherit the status line", so nothing is printed and
	# tmux keeps whatever style is already in effect.
	if ((${#names[@]})); then
		if [ -n "$label_color" ]; then
			printf '#[fg=%s]%s#[default] ' "$label_color" "${names[*]}"
		else
			printf '%s ' "${names[*]}"
		fi
	fi

	local text="${parts[*]}" color
	color="$(pick_color "$pct")"
	if [ -n "$color" ]; then
		printf '#[fg=%s]%s#[default]' "$color" "$text"
	else
		printf '%s' "$text"
	fi
}

segments=()
case "$show" in
weekly)
	s="$(window_segment "$seven_pct" "$seven_reset" "$weekly_label" "$icon")" && segments+=("$s")
	;;
all)
	s="$(window_segment "$five_pct" "$five_reset" "$session_label" "$icon")" && segments+=("$s")
	s="$(window_segment "$seven_pct" "$seven_reset" "$weekly_label" "$icon")" && segments+=("$s")
	;;
*)
	s="$(window_segment "$five_pct" "$five_reset" "$session_label" "$icon")" && segments+=("$s")
	;;
esac

# Codex reports only a weekly budget on the plans that expose rate_limits at
# all, so there is no window to choose between here.
if [ "$codex" = on ]; then
	s="$(window_segment "$codex_pct" "$codex_reset" "$weekly_label" "$codex_icon")" && segments+=("$s")
fi

((${#segments[@]})) || exit 0

out=""
for i in "${!segments[@]}"; do
	((i > 0)) && out+="$separator"
	out+="${segments[$i]}"
done

# Staleness marker. The numbers only refresh while Claude Code renders; usage
# incurred elsewhere (browser, another machine) won't show up until then. When
# the cache is older than @claude_usage_stale_after seconds, flag it so the
# figure isn't mistaken for live. Off unless the option is set to a positive
# integer.
if [[ "$stale_after" =~ ^[0-9]+$ ]] && [ "$stale_after" -gt 0 ] &&
	[[ "$updated_at" =~ ^[0-9]+$ ]] && [ $((now - updated_at)) -ge "$stale_after" ]; then
	out+=" ($stale_label $(human_reset $((now - updated_at))))"
fi

printf '%s%s' "$prefix" "$out"
