#!/usr/bin/env bash
#
# Codex usage harvester.
#
# Codex CLI has no statusLine hook, so unlike Claude nothing pushes usage at us.
# What it does have is a rollout log per session under $CODEX_HOME/sessions,
# where every `token_count` event carries the server's `rate_limits` block. We
# read the newest of those and cache the weekly window for the tmux segment.
#
# Prints nothing. Cheap enough to call on redraw thanks to the TTL below, but
# segment.sh still backgrounds it so a slow disk never stalls the status line.

set -uo pipefail
export LC_ALL=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$DIR/helpers.sh"

CACHE_FILE="$(codex_cache_file)"
LOCK_DIR="$(dirname "$CACHE_FILE")/codex.lock"
SESSIONS="${CODEX_HOME:-$HOME/.codex}/sessions"

# How long a scrape stays fresh, and how far back to look for session logs.
# Codex reports usage per turn, so a minute-old reading is never more than one
# turn behind; scanning three days of logs covers a weekend gap without walking
# the whole archive.
TTL=60
LOOKBACK_DAYS=3
MAX_FILES=5

[ -d "$SESSIONS" ] || exit 0

now="$(date +%s)"

# Serve from cache while it's fresh. Read the timestamp without sourcing the
# file, matching how segment.sh treats the Claude cache.
if [ -f "$CACHE_FILE" ]; then
	cached_at="$(sed -n 's/^UPDATED_AT=//p' "$CACHE_FILE" 2>/dev/null)"
	if [[ "$cached_at" =~ ^[0-9]+$ ]] && ((now - cached_at < TTL)); then
		exit 0
	fi
fi

# Single-writer lock. The status line redraws in every attached client at once,
# so without this a stale cache would kick off one scrape per client. mkdir is
# the atomic primitive available to plain bash; a lock older than the TTL is
# treated as abandoned so a killed scrape can't wedge the segment forever.
if ! mkdir -p "$(dirname "$CACHE_FILE")" 2>/dev/null; then exit 0; fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
	lock_at="$(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null)"
	if [[ "$lock_at" =~ ^[0-9]+$ ]] && ((now - lock_at < TTL)); then exit 0; fi
	rmdir "$LOCK_DIR" 2>/dev/null
	mkdir "$LOCK_DIR" 2>/dev/null || exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

# jq resolution mirrors statusline.sh: tmux may have been started from a GUI
# session whose PATH lacks Homebrew.
JQ="$(command -v jq 2>/dev/null || true)"
if [ -z "$JQ" ]; then
	for d in /opt/homebrew/bin /usr/local/bin /usr/bin /bin /home/linuxbrew/.linuxbrew/bin; do
		if [ -x "$d/jq" ]; then JQ="$d/jq"; break; fi
	done
fi
[ -n "$JQ" ] || exit 0

# Reverse-read a file, so grep -m1 finds the *last* rate_limits line and stops
# without streaming a multi-megabyte rollout front to back.
reverse_cat() {
	if command -v tail >/dev/null 2>&1 && tail -r /dev/null >/dev/null 2>&1; then
		tail -r "$1"
	elif command -v tac >/dev/null 2>&1; then
		tac "$1"
	else
		cat "$1"
	fi
}

# Newest sessions first, by mtime rather than by the timestamp in the filename:
# a long-running session started yesterday holds fresher numbers than one opened
# and abandoned an hour ago.
files="$(
	find "$SESSIONS" -name 'rollout-*.jsonl' -mtime -"$LOOKBACK_DAYS" 2>/dev/null |
		while IFS= read -r p; do
			m="$(stat -f %m "$p" 2>/dev/null || stat -c %Y "$p" 2>/dev/null)"
			[ -n "$m" ] && printf '%s\t%s\n' "$m" "$p"
		done | sort -rn | head -n "$MAX_FILES" | cut -f2-
)"

[ -n "$files" ] || exit 0

best_pct="" best_reset=-1

while IFS= read -r f; do
	[ -n "$f" ] || continue
	# No `|| continue` on the assignment: grep -m1 exits as soon as it matches,
	# which SIGPIPEs the reverse reader and — under `pipefail` — fails the whole
	# pipeline on the very success case we want. Judge by the output instead.
	line="$(reverse_cat "$f" 2>/dev/null | grep -m1 '"rate_limits"')"
	[ -n "$line" ] || continue

	# Codex splits usage across `primary` and `secondary` windows, and which one
	# is the weekly budget depends on the plan — on Plus the weekly window shows
	# up as `primary` with no secondary at all. So select by window length
	# instead of by field name: anything a day or longer is the weekly budget.
	# If a plan only reports a short window, we emit nothing rather than
	# mislabelling a 5-hour figure as weekly.
	vals="$(printf '%s' "$line" | "$JQ" -r '
		.payload.rate_limits as $r
		| [$r.primary, $r.secondary]
		| map(select(. != null and .window_minutes != null and .window_minutes >= 1440))
		| (max_by(.window_minutes) // empty)
		| "\(.used_percent // "")|\(.resets_at // "")"
	' 2>/dev/null)" || continue

	pct="${vals%%|*}"
	reset="${vals##*|}"
	[ -n "$pct" ] || continue
	[[ "$reset" =~ ^[0-9]+$ ]] || reset=0

	# Same freshness rule as the Claude harvester: a later window always wins,
	# and within one window the higher percentage is the more recent reading,
	# since usage only climbs until the window resets.
	if ((reset > best_reset)); then
		best_reset="$reset"
		best_pct="$pct"
	elif ((reset == best_reset)) && [ -n "$best_pct" ] &&
		awk -v a="$pct" -v b="$best_pct" 'BEGIN { exit !(a + 0 > b + 0) }'; then
		best_pct="$pct"
	fi
done <<EOF
$files
EOF

[ -n "$best_pct" ] || exit 0

{
	printf 'CODEX_WEEK_PCT=%s\n' "$best_pct"
	printf 'CODEX_WEEK_RESET=%s\n' "$best_reset"
	printf 'UPDATED_AT=%s\n' "$now"
} >"$CACHE_FILE.tmp.$$" 2>/dev/null && mv "$CACHE_FILE.tmp.$$" "$CACHE_FILE" 2>/dev/null

exit 0
