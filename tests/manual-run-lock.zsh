#!/usr/bin/env zsh

set -eu

repo_dir="${0:A:h:h}"
test_dir="${0:A:h}"
log_dir="$test_dir/logs"
lock_dir="$log_dir/.update.lock"

cleanup() {
  command rm -f "$lock_dir/pid" "$lock_dir/started_at" "$log_dir"/update-*.log(N) 2>/dev/null || true
  rmdir "$lock_dir" "$log_dir" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$lock_dir"
zmodload zsh/system
echo "$sysparams[pid]" > "$lock_dir/pid"

eval "$(sed '/^main "\$@"/,$d' "$repo_dir/update.sh")"

set +e
output="$(PATH=/usr/bin:/bin main manual 2>&1)"
exit_code=$?
set -e

[[ $exit_code -ne 75 ]]
[[ "$output" != *"already running"* ]]
[[ -d "$lock_dir" ]]

set +e
output="$(PATH=/usr/bin:/bin main --auto 2>&1)"
exit_code=$?
set -e

[[ $exit_code -eq 75 ]]
[[ "$output" == *"already running"* ]]

print 'manual run ignores the lock; automatic run remains blocked'
