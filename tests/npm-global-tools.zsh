#!/usr/bin/env zsh

set -eu

repo_dir="${0:A:h:h}"
test_dir="$(mktemp -d)"
fake_bin="$test_dir/bin"
fake_nvm="$test_dir/nvm"
npm_calls="$test_dir/npm-calls"

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT

mkdir -p "$fake_bin" "$fake_nvm" "$test_dir/home/.nvm/versions/node/v24.21.0/bin"
cp "$repo_dir/update.sh" "$test_dir/update.sh"

cat > "$fake_bin/brew" <<'EOF'
#!/usr/bin/env zsh
if [[ "$1" == "--prefix" && "$2" == "nvm" ]]; then
  print -r -- "$FAKE_NVM_PREFIX"
fi
EOF

cat > "$fake_bin/node" <<'EOF'
#!/usr/bin/env zsh
print 'v24.21.0'
EOF

cat > "$fake_bin/npm" <<'EOF'
#!/usr/bin/env zsh
if [[ "$1" == "-v" ]]; then
  print '11.19.0'
else
  print -r -- "$*" >> "$NPM_CALLS"
fi
EOF

cat > "$fake_nvm/nvm.sh" <<'EOF'
nvm() {
  case "$1" in
    ls-remote) print 'v24.21.0' ;;
    which) print -r -- "$NVM_DIR/versions/node/v24.21.0/bin/node" ;;
    use) export PATH="$NVM_DIR/versions/node/v24.21.0/bin:$PATH" ;;
  esac
}
EOF

chmod +x "$fake_bin/brew" "$fake_bin/node" "$fake_bin/npm"
cp "$fake_bin/node" "$fake_bin/npm" "$test_dir/home/.nvm/versions/node/v24.21.0/bin/"

PATH="$fake_bin:/usr/bin:/bin" \
HOME="$test_dir/home" \
FAKE_NVM_PREFIX="$fake_nvm" \
NPM_CALLS="$npm_calls" \
  zsh "$test_dir/update.sh" --auto >/dev/null

expected=$'i -g vite@latest\ni -g http-server@latest\ni -g npm-check-updates@latest'
[[ "$(<"$npm_calls")" == "$expected" ]]

print 'npm global updates exclude Homebrew-managed pnpm'
