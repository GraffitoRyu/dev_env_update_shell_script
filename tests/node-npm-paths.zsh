#!/usr/bin/env zsh
set -eu

repo_dir="${0:A:h:h}"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/bin" "$test_dir/nvm" "$test_dir/home/.nvm/versions/node/v24.21.0/bin"
cp "$repo_dir/update.sh" "$test_dir/update.sh"
export FAKE_NVM_PREFIX="$test_dir/nvm"
export HOME="$test_dir/home"
export MANAGED_BIN="$HOME/.nvm/versions/node/v24.21.0/bin"
export NVM_CALLS="$test_dir/nvm-calls"
export NPM_CALLS="$test_dir/npm-calls"

cat > "$test_dir/bin/brew" <<'MOCK'
#!/bin/zsh
if [[ "$1" == --prefix ]]; then
  print -r -- "$FAKE_NVM_PREFIX"
fi
exit 0
MOCK
cat > "$test_dir/bin/node" <<'MOCK'
#!/bin/zsh
print v24.21.0
MOCK
cat > "$test_dir/bin/npm" <<'MOCK'
#!/bin/zsh
if [[ "$1" == -v ]]; then
  print 11.19.0
  [[ "$SCENARIO" != npm-failure ]]
else
  print -r -- "$0 $*" >> "$NPM_CALLS"
fi
MOCK
cat > "$test_dir/nvm/nvm.sh" <<'MOCK'
nvm() {
  print -r -- "$*" >> "$NVM_CALLS"
  case "$1" in
    ls-remote) print v24.21.0 ;;
    which)
      [[ "$SCENARIO" != install-failure && "$SCENARIO" != not-installed ]] || return 3
      print -r -- "$MANAGED_BIN/node"
      ;;
    install) [[ "$SCENARIO" != install-failure ]] || return 31 ;;
    use)
      [[ "$SCENARIO" != use-failure ]] || return 32
      [[ "$SCENARIO" == external-node ]] || export PATH="$MANAGED_BIN:$PATH"
      ;;
    alias) ;;
    *) return 99 ;;
  esac
}
MOCK
chmod +x "$test_dir/bin/"*
cp "$test_dir/bin/node" "$MANAGED_BIN/node"

for SCENARIO in external-same internal-same not-installed npm-symlink install-failure use-failure npm-failure external-npm external-node external-npm-symlink; do
  export SCENARIO
  : > "$NVM_CALLS"
  : > "$NPM_CALLS"
  rm -f "$MANAGED_BIN/npm"
  cp "$test_dir/bin/npm" "$MANAGED_BIN/npm"
  if [[ "$SCENARIO" == npm-symlink ]]; then
    mkdir -p "$MANAGED_BIN/../lib/node_modules/npm/bin"
    mv "$MANAGED_BIN/npm" "$MANAGED_BIN/../lib/node_modules/npm/bin/npm-cli.js"
    ln -s ../lib/node_modules/npm/bin/npm-cli.js "$MANAGED_BIN/npm"
  elif [[ "$SCENARIO" == external-npm-symlink ]]; then
    rm "$MANAGED_BIN/npm"
    ln -s "$test_dir/bin/npm" "$MANAGED_BIN/npm"
  fi
  [[ "$SCENARIO" != external-npm ]] || rm "$MANAGED_BIN/npm"
  test_path="$test_dir/bin:/usr/bin:/bin"
  [[ "$SCENARIO" != internal-same ]] || test_path="$MANAGED_BIN:$test_path"
  actual_exit=0
  PATH="$test_path" /bin/zsh "$test_dir/update.sh" --auto </dev/null >"$test_dir/output" 2>&1 || actual_exit=$?
  case "$SCENARIO" in
    external-same|internal-same|not-installed|npm-symlink)
      [[ $actual_exit -eq 0 ]] || { cat "$test_dir/output"; exit 1; }
      for package in vite http-server npm-check-updates; do
        grep -Fxq "$MANAGED_BIN/npm i -g $package@latest" "$NPM_CALLS"
      done
      while IFS= read -r call; do
        [[ "$call" == "$MANAGED_BIN/npm "* ]]
      done < "$NPM_CALLS"
      grep -Fxq 'use v24.21.0' "$NVM_CALLS"
      if [[ "$SCENARIO" == not-installed ]]; then
        grep -Fxq 'install v24.21.0' "$NVM_CALLS"
      else
        ! grep -Fxq 'install v24.21.0' "$NVM_CALLS"
      fi
      ;;
    install-failure) [[ $actual_exit -eq 31 && ! -s "$NPM_CALLS" ]] ;;
    use-failure) [[ $actual_exit -eq 32 && ! -s "$NPM_CALLS" ]] ;;
    *) [[ $actual_exit -ne 0 && ! -s "$NPM_CALLS" ]] ;;
  esac
  print "PASS: $SCENARIO"
done
