#!/usr/bin/env bash

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
RESURRECT_DIR="$TEST_DIR/resurrect"
TMUX_SOCKET="$TEST_DIR/tmux.sock"
export TMUX_SOCKET
mkdir -p "$RESURRECT_DIR" "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "${TMUX_EMPTY_CAPTURE:-}" == "1" && ( "$1" == "list-panes" || "$1" == "list-windows" ) ]]; then
	exit 0
fi
if [[ "$1" == "-S" ]]; then
	socket="$2"
	shift 2
	exec /usr/bin/tmux -f /dev/null -S "$socket" "$@"
fi
exec /usr/bin/tmux -f /dev/null -S "$TMUX_SOCKET" "$@"
EOF
cat > "$TEST_DIR/bin/date" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "+%Y%m%dT%H%M%S" ]]; then
	echo "20990101T000000"
else
	exec /usr/bin/date "$@"
fi
EOF
chmod +x "$TEST_DIR/bin/tmux"
chmod +x "$TEST_DIR/bin/date"
export PATH="$TEST_DIR/bin:$PATH"

cleanup() {
	tmux kill-server >/dev/null 2>&1 || true
	rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

start_server() {
	tmux new-session -d -s 0
	local server_pid
	server_pid="$(tmux display-message -p '#{pid}')"
	export TMUX="$TMUX_SOCKET,$server_pid,0"
	tmux set-option -g @resurrect-dir "$RESURRECT_DIR"
}

assert_session_exists() {
	tmux has-session -t "$1" >/dev/null 2>&1
}

start_server
"$PLUGIN_DIR/scripts/save.sh" quiet || fail "normal save failed"
[[ -L "$RESURRECT_DIR/last" ]] || fail "normal save did not publish last symlink"
saved_target="$(readlink "$RESURRECT_DIR/last")"
saved_contents="$(cat "$RESURRECT_DIR/last")"
awk -F '\t' '$1 == "pane" { found = 1 } END { exit !found }' "$RESURRECT_DIR/last" || fail "normal save has no pane records"
awk -F '\t' '$1 == "window" { found = 1 } END { exit !found }' "$RESURRECT_DIR/last" || fail "normal save has no window records"
echo "PASS: normal save publishes pane and window records"

"$PLUGIN_DIR/scripts/save.sh" quiet || fail "same-second save failed"
second_saved_target="$(readlink "$RESURRECT_DIR/last")"
[[ -f "$RESURRECT_DIR/last" ]] || fail "same-second save left last dangling"
awk -F '\t' '$1 == "pane" { found = 1 } END { exit !found }' "$RESURRECT_DIR/last" || fail "same-second save has no pane records"
awk -F '\t' '$1 == "window" { found = 1 } END { exit !found }' "$RESURRECT_DIR/last" || fail "same-second save has no window records"
saved_target="$second_saved_target"
saved_contents="$(cat "$RESURRECT_DIR/last")"
echo "PASS: same-second save preserves a valid snapshot"

if TMUX_EMPTY_CAPTURE=1 "$PLUGIN_DIR/scripts/save.sh" quiet >"$TEST_DIR/empty-save.log" 2>&1; then
	fail "save unexpectedly succeeded with empty pane and window captures"
fi
[[ "$(readlink "$RESURRECT_DIR/last")" == "$saved_target" ]] || fail "empty capture replaced last symlink"
[[ "$(cat "$RESURRECT_DIR/last")" == "$saved_contents" ]] || fail "empty capture changed previous snapshot"
if grep -q 'Tmux environment saved!' "$TEST_DIR/empty-save.log"; then
	fail "empty capture reported success"
fi
echo "PASS: empty captures preserve the previous snapshot and report failure"

tmux kill-server
if "$PLUGIN_DIR/scripts/save.sh" quiet >"$TEST_DIR/failed-save.log" 2>&1; then
	fail "save unexpectedly succeeded without a tmux server"
fi
[[ "$(readlink "$RESURRECT_DIR/last")" == "$saved_target" ]] || fail "failed save replaced last symlink"
[[ "$(cat "$RESURRECT_DIR/last")" == "$saved_contents" ]] || fail "failed save changed previous snapshot"
if grep -q 'Tmux environment saved!' "$TEST_DIR/failed-save.log"; then
	fail "failed save reported success"
fi
echo "PASS: failed capture preserves the previous snapshot and reports failure"

start_server
printf 'state\t\t\n' > "$RESURRECT_DIR/empty.txt"
ln -sfn empty.txt "$RESURRECT_DIR/last"
"$PLUGIN_DIR/scripts/restore.sh" >"$TEST_DIR/empty-restore.log" 2>&1 || fail "empty restore returned failure"
assert_session_exists 0 || fail "empty restore killed the initial session"
echo "PASS: empty restore keeps the initial session alive"

printf 'pane\twork\t0\t0\t:*\t0\t:bash\t:/tmp\t1\tbash\t:\n' > "$RESURRECT_DIR/valid.txt"
ln -sfn valid.txt "$RESURRECT_DIR/last"
"$PLUGIN_DIR/scripts/restore.sh" >"$TEST_DIR/valid-restore.log" 2>&1 || fail "valid restore returned failure"
assert_session_exists work || fail "valid restore did not create the saved session"
if assert_session_exists 0; then
	fail "valid restore did not clean up the initial session"
fi
echo "PASS: valid restore creates the saved session and removes the initial session"

echo "PASS: 6 focused checks"
