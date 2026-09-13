#!/usr/bin/env zsh
emulate -R zsh
set -euo pipefail

script_dir="${0:A:h}"
source "$script_dir/pnpm-policy.zsh"
mode="${1:-diagnose}"
if (( $# > 1 )) || [[ "$mode" != diagnose && "$mode" != --apply && "$mode" != --help ]]; then
  print -u2 '사용법: zsh migrate-pnpm.zsh [--apply|--help]'
  exit 2
fi
if [[ "$mode" == --help ]]; then
  print '인수 없음: 기존 pnpm을 실행하지 않고 링크·PATH·nvm 충돌을 진단합니다.'
  print '--apply: 승인 formula 설치·검증 → Homebrew 링크 전환 → 이전 자체 셸 블록 제거'
  exit 0
fi
[[ "$PNPM_MAJOR" == <-> ]] && (( PNPM_MAJOR > 0 )) || { print -u2 '잘못된 PNPM_MAJOR'; exit 2; }
formula="pnpm@$PNPM_MAJOR"
rc_path="${ZDOTDIR:-$HOME}/.zshrc"
rc_target="${rc_path:A}"
marker_start='# >>> shell-update pnpm >>>'
marker_end='# <<< shell-update pnpm <<<'
backup=''
staged=''
version_dir=''
old_formula=''
old_unlinked=0
link_attempted=0
rc_replaced=0
completed=0
lock_fd=-1

cleanup() {
  local result=$?
  local rollback_failed=0
  trap - EXIT
  trap '' INT TERM HUP
  set +e
  if (( ! completed )); then
    if (( rc_replaced )); then
      cp -p "$backup" "$rc_target" || rollback_failed=1
    fi
    if (( link_attempted )); then
      brew unlink "$formula" || rollback_failed=1
    fi
    if (( old_unlinked )); then
      brew link --force "$old_formula" || rollback_failed=1
    fi
    if (( rollback_failed )); then
      print -u2 '복구가 완료되지 않았습니다. 부분 적용 상태이며 다음 링크와 백업을 확인하세요.'
      ls -ld "$native_bin/pnpm" "$native_bin/pnpx" >&2
      print -u2 "이전 formula: ${old_formula:-없음}; 설정 백업: ${backup:-없음}"
      result=1
    fi
  fi
  [[ -z "$staged" ]] || rm -f "$staged"
  [[ -z "$version_dir" ]] || rm -rf "$version_dir"
  (( lock_fd < 0 )) || zsystem flock -u "$lock_fd"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Retained only to recognize and remove an unchanged block from the previous tool.
managed_block() {
  local bin_path="$1"
  local quoted_bin="${(q)bin_path}"
  cat <<BLOCK
$marker_start
# bin: $bin_path
if (( \${+aliases[pnpm]} || \${+aliases[pnpx]} )) ||
   { (( \${+functions[pnpm]} )) && [[ "\${functions[pnpm]}" != "\${_shell_update_pnpm_function-}" ]]; } ||
   { (( \${+functions[pnpx]} )) && [[ "\${functions[pnpx]}" != "\${_shell_update_pnpx_function-}" ]]; }; then
  print -u2 '[shell-update] 기존 pnpm/pnpx alias 또는 함수가 있어 전환을 건너뜁니다.'
else
  export PATH=$quoted_bin:"\$PATH"
  function pnpm { PATH=$quoted_bin:"\$PATH" command $quoted_bin/pnpm "\$@"; }
  function pnpx { PATH=$quoted_bin:"\$PATH" command $quoted_bin/pnpx "\$@"; }
  typeset -g _shell_update_pnpm_function="\${functions[pnpm]}"
  typeset -g _shell_update_pnpx_function="\${functions[pnpx]}"
fi
$marker_end
BLOCK
}

print "승인 formula: $formula"
print "기존 셸 블록 검사: $rc_path → $rc_target"
print '기존 pnpm은 실행하지 않습니다. 사용자 초기화 파일도 source하지 않습니다.'
if ! (( $+commands[brew] )); then
  print -u2 'Homebrew가 없습니다. 설치 후 다시 실행하세요.'
  [[ "$mode" != --apply ]] && exit 0
  exit 127
fi
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_INSTALL_CLEANUP=1
if [[ "$mode" == --apply ]]; then
  zmodload zsh/system
  legacy_pid="$(cat "$script_dir/logs/.update.lock/pid" 2>/dev/null || true)"
  if [[ "$legacy_pid" == <-> ]] && kill -0 "$legacy_pid" 2>/dev/null; then
    print -u2 '기존 업데이트 실행이 진행 중입니다.'
    exit 75
  fi
  mkdir -p "$script_dir/logs"
  : >> "$script_dir/logs/.update.flock"
  if zsystem flock -t 0.001 -f lock_fd "$script_dir/logs/.update.flock"; then
    :
  else
    lock_status=$?
    (( lock_status != 2 )) || lock_status=75
    print -u2 '업데이트/전환 잠금을 얻지 못했습니다.'
    exit "$lock_status"
  fi
fi
brew_prefix="$(brew --prefix)"
native_bin="$brew_prefix/bin"
pnpm_bin="$brew_prefix/opt/$formula/bin"
formula_root="${pnpm_bin:h:A}"
installed_formulae="$(brew list --versions | awk '$1 == "pnpm" || $1 ~ /^pnpm@[0-9]+$/ { print $1 }')"
print "일반 실행 경로: $native_bin/pnpm, $native_bin/pnpx"
print "설치된 pnpm formula: ${installed_formulae:-없음}"
print 'pin 상태:'
brew list --pinned | awk '$0 == "pnpm" || $0 ~ /^pnpm@[0-9]+$/ { print }'
print '기존 패키지는 제거하지 않습니다. Homebrew 링크 전환과 이전 자체 셸 블록 제거만 수행합니다.'
print '실패 시 링크와 셸 설정을 복구합니다. 설치 단계에서 추가된 패키지는 자동으로 제거하지 않습니다.'

if [[ -L "$rc_path" && ! -e "$rc_path" ]] || [[ -e "$rc_target" && ! -f "$rc_target" ]]; then
  print -u2 '셸 설정이 끊어진 링크 또는 일반 파일이 아닙니다. 변경하지 않습니다.'
  exit 1
fi

old_block=''
if [[ -f "$rc_target" ]]; then
  start_count="$(grep -Fxc "$marker_start" "$rc_target" || true)"
  end_count="$(grep -Fxc "$marker_end" "$rc_target" || true)"
  if [[ "$start_count:$end_count" == 1:1 ]]; then
    old_block="$(awk -v start="$marker_start" -v end="$marker_end" '$0 == start { inside=1 } inside { print } $0 == end { inside=0 }' "$rc_target")"
    old_bin="$(print -r -- "$old_block" | sed -n '2s/^# bin: //p')"
    if [[ -z "$old_bin" || "$old_block" != "$(managed_block "$old_bin")" ]]; then
      print -u2 '관리 블록이 수정되었거나 손상되었습니다. 기존 내용을 덮어쓰지 않습니다.'
      exit 1
    fi
  elif [[ "$start_count:$end_count" != 0:0 ]]; then
    print -u2 '관리 블록의 개수나 경계가 잘못되었습니다. 기존 내용을 덮어쓰지 않습니다.'
    exit 1
  fi
  conflicts="$(awk -v start="$marker_start" -v end="$marker_end" '$0 == start { inside=1; next } $0 == end { inside=0; next } !inside && $0 !~ /^[[:space:]]*#/' "$rc_target" | grep -En '(^|[[:space:];])(function[[:space:]]+)?(pnpm|pnpx)[[:space:]]*\(\)|(^|[[:space:];])function[[:space:]]+(pnpm|pnpx)([[:space:]{]|$)|(^|[[:space:];])alias[[:space:]]+.*(pnpm|pnpx)=' || true)"
  if [[ -n "$conflicts" ]]; then
    print -u2 "기존 pnpm/pnpx 정의가 있습니다. 자동으로 덮어쓰지 않습니다:\n$conflicts"
    exit 1
  fi
fi

# Both native entrypoints must belong to the same installed pnpm formula, or be absent.
owner_of() {
  local executable="$1" candidate candidate_root expected
  [[ -L "$executable" && -e "$executable" ]] || return 1
  for candidate in "${(@f)installed_formulae}"; do
    candidate_root="$(brew --prefix --installed "$candidate" 2>/dev/null)" || continue
    [[ "${executable:A}" == "${candidate_root:A}"/* ]] || continue
    expected="$candidate_root/bin/${executable:t}"
    [[ "${executable:A}" == "${expected:A}" ]] || continue
    print -r -- "$candidate"
    return 0
  done
  return 1
}
owner=''
for name in pnpm pnpx; do
  executable="$native_bin/$name"
  candidate_owner='absent'
  if [[ -e "$executable" || -L "$executable" ]]; then
    candidate_owner="$(owner_of "$executable")" || { print -u2 "소유 불명 Homebrew 경로: $executable"; exit 1; }
  fi
  print "$executable: $candidate_owner"
  if [[ -n "$owner" && "$owner" != "$candidate_owner" ]]; then
    print -u2 'pnpm/pnpx 링크가 혼합되었거나 일부만 있습니다. 소유권을 확인한 뒤 복구하세요.'
    exit 1
  fi
  owner="$candidate_owner"
done
[[ "$owner" == absent || "$owner" == "$formula" ]] || old_formula="$owner"

shadow=0
nvm_root="${NVM_DIR:-$HOME/.nvm}"
for directory in "$nvm_root"/versions/node/*/bin(N/); do
  for name in pnpm pnpx; do
    executable="$directory/$name"
    expected="$pnpm_bin/$name"
    [[ -e "$executable" || -L "$executable" ]] || continue
    [[ -x "$executable" && "${expected:A}" == "$formula_root"/* && "${executable:A}" == "${expected:A}" ]] && continue
    print -u2 "nvm 충돌: $executable → ${executable:A}"
    shadow=1
  done
done
native_in_path=0
for directory in "$path[@]"; do
  if [[ "${directory:A}" == "${native_bin:A}" ]]; then
    native_in_path=1
    break
  fi
  for name in pnpm pnpx; do
    executable="$directory/$name"
    expected="$pnpm_bin/$name"
    [[ -x "$executable" || -L "$executable" ]] || continue
    [[ -x "$executable" && "${expected:A}" == "$formula_root"/* && "${executable:A}" == "${expected:A}" ]] && continue
    print -u2 "PATH 우선 충돌: $executable → ${executable:A}"
    shadow=1
  done
done
if (( ! native_in_path )); then
  print -u2 "현재 PATH에 $native_bin 이 없습니다. Homebrew 환경 설정을 먼저 확인하세요."
  shadow=1
fi
if (( shadow )); then
  print -u2 'npm/Corepack 등의 소유권을 확인해 docs/pnpm-migration.md 절차로 별도 정리하세요. 자동 삭제하지 않습니다.'
  exit 1
fi
if [[ "$mode" != --apply ]]; then
  print '진단 완료. --apply는 검증한 이전 formula의 링크를 전환하고, 자체 관리 블록만 제거합니다.'
  exit 0
fi
if ! (( $+commands[node] )); then
  print -u2 'node가 없습니다. 먼저 update.sh로 Node.js를 준비하세요.'
  exit 127
fi
if ! installed_prefix="$(brew --prefix --installed "$formula" 2>/dev/null)"; then
  brew install --skip-link "$formula"
  installed_prefix="$(brew --prefix --installed "$formula")"
fi
formula_root="${pnpm_bin:h:A}"
[[ "${installed_prefix:A}" == "$formula_root" ]] || { print -u2 '설치 메타데이터와 대상 경로가 다릅니다.'; exit 1; }
for executable in "$pnpm_bin/pnpm" "$pnpm_bin/pnpx"; do
  [[ -x "$executable" && "${executable:A}" == "$formula_root"/* ]] || { print -u2 "목표 실행 파일이 없거나 formula 외부를 가리킵니다: $executable"; exit 1; }
done
version_dir="$(mktemp -d)"
pnpm_version="$(cd "$version_dir"; "$pnpm_bin/pnpm" --version)"
[[ "$pnpm_version" == "$PNPM_MAJOR".<->.<-> ]] || { print -u2 "목표 major와 다른 pnpm입니다: $pnpm_version"; exit 1; }
print "검증된 pnpm: $pnpm_version"

if [[ -n "$old_block" ]]; then
  backup="$(mktemp "${rc_target}.shell-update-pnpm.XXXXXX")"
  cp -p "$rc_target" "$backup"
  print "설정 백업: $backup"
  staged="$(mktemp "${rc_target}.shell-update-pnpm-stage.XXXXXX")"
  cp -p "$backup" "$staged"
  awk -v start="$marker_start" -v end="$marker_end" '$0 == start { inside=1; next } $0 == end { inside=0; next } !inside { print }' "$backup" > "$staged"
fi
if [[ "$owner" != "$formula" ]]; then
  brew link --force --dry-run "$formula"
  if [[ -n "$old_formula" ]]; then
    old_unlinked=1
    brew unlink "$old_formula"
  fi
  link_attempted=1
  brew link --force "$formula"
fi
rehash
for name in pnpm pnpx; do
  executable="$native_bin/$name"
  expected="$pnpm_bin/$name"
  [[ -L "$executable" && -x "$executable" && "${executable:A}" == "${expected:A}" ]] || { print -u2 "Homebrew 링크 검증 실패: $executable"; exit 1; }
  executable="$(whence -p "$name")"
  [[ "${executable:A}" == "${expected:A}" ]] || { print -u2 "일반 PATH 검증 실패: $executable"; exit 1; }
done
if [[ -n "$staged" ]]; then
  cmp -s "$rc_target" "$backup" || { print -u2 '적용 중 설정이 바뀌었습니다. 교체하지 않습니다.'; exit 1; }
  rc_replaced=1
  mv "$staged" "$rc_target"
  staged=''
fi
completed=1
print '전환 완료: Homebrew 일반 링크가 승인 formula를 가리킵니다. 새 셸 블록은 만들지 않았습니다.'
print '새 zsh와 실제 Codex 환경에서 command pnpm 및 nvm 전환 후 경로를 확인하세요.'
[[ -z "$old_formula" ]] || print "이전 formula는 설치 상태로 보존했습니다: $old_formula"
[[ -z "$backup" ]] || print "이전 설정 복구 자료: $backup (native 링크 복구와 함께 사용)"
