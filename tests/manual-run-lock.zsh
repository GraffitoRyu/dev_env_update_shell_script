#!/usr/bin/env zsh

set -eu

repo_dir="${0:A:h:h}"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/logs"
cp "$repo_dir/update.sh" "$repo_dir/pnpm-policy.zsh" "$test_dir/"
lock_file="$test_dir/logs/.update.flock"
: > "$lock_file"
zmodload zsh/system
zsystem flock -f lock_fd "$lock_file"

result=0
output="$(PATH=/usr/bin:/bin zsh "$test_dir/update.sh" manual 2>&1)" || result=$?
[[ $result == 127 && "$output" != *"already running"* ]]

# A manual run and unsuccessful contenders must leave the owner's lock intact.
for attempt in 1 2; do
  result=0
  output="$(PATH=/usr/bin:/bin zsh "$test_dir/update.sh" --auto 2>&1)" || result=$?
  [[ $result == 75 && "$output" == *"already running"* ]]
done
zsystem flock -u "$lock_fd"
result=0
output="$(PATH=/usr/bin:/bin zsh "$test_dir/update.sh" --auto 2>&1)" || result=$?
[[ $result == 127 ]]
[[ -f "$lock_file" ]]

# Preserve compatibility with an active updater using the old directory lock.
mkdir "$test_dir/logs/.update.lock"
print "$sysparams[pid]" > "$test_dir/logs/.update.lock/pid"
result=0
output="$(PATH=/usr/bin:/bin zsh "$test_dir/update.sh" --auto 2>&1)" || result=$?
[[ $result == 75 ]]
[[ "$(< "$test_dir/logs/.update.lock/pid")" == "$sysparams[pid]" ]]

print 'manual bypass, native lock ownership, and active legacy lock compatibility pass'
