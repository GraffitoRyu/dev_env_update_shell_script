#!/usr/bin/env zsh
set -eu
unsetopt bgnice

repo_dir="${0:A:h:h}"
test_dir="$(mktemp -d)"
updater_pid=''
cleanup() {
  touch "$test_dir/release"
  if [[ -n "$updater_pid" ]]; then
    kill -TERM "$updater_pid" 2>/dev/null || true
    wait "$updater_pid" 2>/dev/null || true
  fi
  rm -rf "$test_dir"
}
trap cleanup EXIT
mkdir -p "$test_dir/bin" "$test_dir/nvm" "$test_dir/home"
cp "$repo_dir/update.sh" "$test_dir/update.sh"
export PATH="$test_dir/bin:/usr/bin:/bin"
export HOME="$test_dir/home" TEST_DIR="$test_dir"

cat > "$test_dir/bin/brew" <<'MOCK'
#!/usr/bin/env zsh
if [[ "$1" == update ]]; then
  print started > "$TEST_DIR/started"
  if [[ "${HOLD_BREW:-0}" == 1 ]]; then
    while [[ ! -f "$TEST_DIR/release" ]]; do sleep 0.01; done
  fi
  print finished > "$TEST_DIR/finished"
  exit "${BREW_STATUS:-0}"
elif [[ "$1" == --prefix ]]; then
  print "$TEST_DIR/nvm"
fi
MOCK
cat > "$test_dir/bin/node" <<'MOCK'
#!/usr/bin/env zsh
if [[ "${HOLD_NVM:-0}" == 1 && ! -f "$TEST_DIR/node-ready" ]]; then
  print v23.0.0
else
  print v24.21.0
fi
MOCK
cat > "$test_dir/bin/npm" <<'MOCK'
#!/usr/bin/env zsh
if [[ "$1" == -v ]]; then print 11.0.0; else print "$*" >> "$TEST_DIR/npm-calls"; fi
MOCK
cat > "$test_dir/nvm/nvm.sh" <<'MOCK'
nvm_helper() {
  print started > "$TEST_DIR/nvm-started"
  sleep 0.2
}
nvm() {
  case "$1" in
    ls-remote) print v24.21.0 ;;
    which)
      [[ "${HOLD_NVM:-0}" != 1 || -f "$TEST_DIR/node-ready" ]] || return 3
      print "$HOME/.nvm/versions/node/v24.21.0/bin/node"
      ;;
    install) nvm_helper; print ready > "$TEST_DIR/node-ready" ;;
    use) export PATH="$HOME/.nvm/versions/node/v24.21.0/bin:$PATH" ;;
  esac
}
MOCK
chmod +x "$test_dir/bin/"*
mkdir -p "$HOME/.nvm/versions/node/v24.21.0/bin"
cp "$test_dir/bin/"{node,npm} "$HOME/.nvm/versions/node/v24.21.0/bin/"

await_start() {
  local attempt
  local marker="${1:-$test_dir/started}"
  for attempt in {1..300}; do
    [[ -f "$marker" ]] && return 0
    sleep 0.01
  done
  print -u2 'mock brew did not start'
  return 1
}

expect_busy() {
  local result=0
  zsh "$test_dir/update.sh" --auto > "$test_dir/contender.log" 2>&1 || result=$?
  [[ $result == 75 ]]
}

# A signal waits for the current command and keeps competitors out until it finishes.
for signal_code in TERM:143 HUP:129 INT:130; do
  signal_name="${signal_code%:*}"
  expected_code="${signal_code#*:}"
  rm -f "$test_dir/"{started,release,finished,npm-calls}
  HOLD_BREW=1 zsh "$test_dir/update.sh" --auto > "$test_dir/signal.log" 2>&1 &
  updater_pid=$!
  await_start
  kill -"$signal_name" "$updater_pid"
  expect_busy
  [[ ! -f "$test_dir/finished" ]]
  touch "$test_dir/release"
  result=0
  wait "$updater_pid" || result=$?
  [[ $result == "$expected_code" ]]
  [[ -f "$test_dir/finished" && ! -f "$test_dir/npm-calls" ]]
  zsh "$test_dir/update.sh" --auto > /dev/null
  [[ -s "$test_dir/npm-calls" ]]
done

# A nested nvm helper can absorb a trap's return; the wrapper must retain the signal.
rm -f "$test_dir/npm-calls"
HOLD_NVM=1 zsh "$test_dir/update.sh" --auto > "$test_dir/nvm-signal.log" 2>&1 &
updater_pid=$!
await_start "$test_dir/nvm-started"
kill -TERM "$updater_pid"
result=0
wait "$updater_pid" || result=$?
[[ $result == 143 && ! -f "$test_dir/npm-calls" ]]

# Ordinary command failure preserves its status, skips installs, and releases the lock.
rm -f "$test_dir/npm-calls"
result=0
BREW_STATUS=23 zsh "$test_dir/update.sh" --auto > "$test_dir/failure.log" 2>&1 || result=$?
[[ $result == 23 && ! -f "$test_dir/npm-calls" ]]
zsh "$test_dir/update.sh" --auto > /dev/null

# Sourcing must return to the caller and restore its shell options and traps.
cat > "$test_dir/source-runner.zsh" <<'RUNNER'
setopt no_unset
trap ':' TERM
trap ':' INT
trap ':' HUP
trap ':' ZERR
saved_options="$(setopt)"
saved_traps="$(trap)"
source "$TEST_DIR/update.sh" --auto
result=$?
[[ $result == 143 ]] || exit 1
[[ "$(setopt)" == "$saved_options" ]] || exit 2
[[ "$(trap)" == "$saved_traps" ]] || exit 3
print alive > "$TEST_DIR/caller-alive"
RUNNER
rm -f "$test_dir/"{started,release,finished,npm-calls}
HOLD_BREW=1 zsh "$test_dir/source-runner.zsh" > "$test_dir/source.log" 2>&1 &
updater_pid=$!
await_start
kill -TERM "$updater_pid"
expect_busy
touch "$test_dir/release"
wait "$updater_pid"
[[ -f "$test_dir/caller-alive" && ! -f "$test_dir/npm-calls" ]]
zsh "$test_dir/update.sh" --auto > /dev/null

print 'signals, concurrent ownership, failure status, and sourced shell preservation pass'
