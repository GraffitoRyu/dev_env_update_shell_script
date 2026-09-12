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
  print '인수 없음: 설치 경로와 전환 계획만 진단합니다. pnpm을 실행하지 않습니다.'
  print '--apply: pnpm@승인major 설치·검증 후 zsh 관리 블록을 적용합니다.'
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
cleanup() {
  [[ -z "$staged" ]] || rm -f "$staged"
  [[ -z "$version_dir" ]] || rm -rf "$version_dir"
}
trap cleanup EXIT

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

print "승인 formula: $formula (major 변경은 pnpm-policy.zsh에서 수동으로 수행)"
print "셸 설정: $rc_path"
print "실제 변경 대상: $rc_target"
pnpm_path="$(whence -p pnpm || true)"
print "현재 PATH의 pnpm: ${pnpm_path:-없음}"
[[ -z "$pnpm_path" ]] || print "실제 실행 파일: ${pnpm_path:A}"
pnpx_path="$(whence -p pnpx || true)"
print "현재 PATH의 pnpx: ${pnpx_path:-없음}"
[[ -z "$pnpx_path" ]] || print "실제 실행 파일: ${pnpx_path:A}"
print "현재 PATH의 node: $(whence -p node || true)"
print '현재 pnpm은 실행하지 않습니다. 호출자 셸의 동적 alias/함수는 이 진단에 상속되지 않습니다.'

if ! (( $+commands[brew] )); then
  print -u2 'Homebrew가 없습니다. 설치 후 다시 실행하세요.'
  [[ "$mode" != --apply ]] && exit 0
  exit 127
fi
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1
brew_prefix="$(brew --prefix)"
pnpm_bin="$brew_prefix/opt/$formula/bin"
[[ "$pnpm_bin" != *$'\n'* ]] || { print -u2 '줄바꿈이 있는 설치 경로는 지원하지 않습니다.'; exit 1; }
print "전환 대상: $pnpm_bin/pnpm"
print 'Homebrew 설치 목록:'
brew list --versions | awk '$1 == "pnpm" || $1 ~ /^pnpm@[0-9]+$/ { print }'
print 'Homebrew pin 목록:'
brew list --pinned | awk '$0 == "pnpm" || $0 ~ /^pnpm@[0-9]+$/ { print }'
print '변경 계획: 대상이 없으면 설치 → major 검증 → 기존 설정 백업 → 관리 블록 적용'
print '기존 pnpm, Corepack, npm, Yarn 및 링크는 삭제하거나 변경하지 않습니다.'
print '복구 계획: 출력된 백업을 실제 설정 대상에 복사하고 새 zsh를 엽니다. 새 설정 파일에는 별도 제거 안내를 제공합니다.'

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

new_block="$(managed_block "$pnpm_bin")"
if [[ "$mode" != --apply ]]; then
  [[ "$old_block" != "$new_block" ]] || print '현재 관리 블록은 이미 목표와 같습니다.'
  print '진단만 완료했습니다. 적용하려면 같은 명령에 --apply를 추가하세요.'
  exit 0
fi

if ! (( $+commands[node] )); then
  print -u2 'node가 없습니다. 먼저 update.sh로 Node.js를 준비한 뒤 다시 실행하세요.'
  exit 127
fi
if ! installed_prefix="$(brew --prefix --installed "$formula" 2>/dev/null)"; then
  brew install "$formula"
  installed_prefix="$(brew --prefix --installed "$formula")"
fi
[[ -x "$pnpm_bin/pnpm" && -x "$pnpm_bin/pnpx" ]] || { print -u2 '설치 후 pnpm/pnpx 실행 파일을 찾지 못했습니다.'; exit 1; }
formula_root="${pnpm_bin:h:A}"
[[ "${installed_prefix:A}" == "$formula_root" ]] || { print -u2 '설치 메타데이터와 대상 경로가 다릅니다.'; exit 1; }
for executable in "$pnpm_bin/pnpm" "$pnpm_bin/pnpx"; do
  [[ "${executable:A}" == "$formula_root"/* ]] || { print -u2 "대상 실행 파일이 formula 외부를 가리킵니다: $executable"; exit 1; }
done
version_dir="$(mktemp -d)"
pnpm_version="$(cd "$version_dir"; PATH="$pnpm_bin:$PATH" "$pnpm_bin/pnpm" --version)"
[[ "$pnpm_version" == "$PNPM_MAJOR".<->.<-> ]] || { print -u2 "목표 major와 다른 pnpm입니다: $pnpm_version"; exit 1; }
print "검증된 pnpm: $pnpm_version"
if [[ "$old_block" == "$new_block" ]]; then
  print '관리 블록이 이미 적용되어 있습니다. 설정과 백업을 추가로 만들지 않았습니다.'
  exit 0
fi

mkdir -p "${rc_target:h}"
staged="$(mktemp "${rc_target}.shell-update-pnpm-stage.XXXXXX")"
if [[ -f "$rc_target" ]]; then
  backup="$(mktemp "${rc_target}.shell-update-pnpm.XXXXXX")"
  cp -p "$rc_target" "$backup"
  print "백업: $backup"
  print "복구: cp -p ${(q)backup} ${(q)rc_target}"
  cp -p "$backup" "$staged"
  if [[ -n "$old_block" ]]; then
    awk -v start="$marker_start" '$0 == start { exit } { print }' "$backup" > "$staged"
    print -r -- "$new_block" >> "$staged"
    awk -v end="$marker_end" 'after { print } $0 == end { after=1 }' "$backup" >> "$staged"
  else
    printf '\n%s\n' "$new_block" >> "$staged"
  fi
  cmp -s "$rc_target" "$backup" || { print -u2 '적용 중 설정 파일이 바뀌었습니다. 교체하지 않습니다.'; exit 1; }
else
  print -r -- "$new_block" > "$staged"
fi
mv "$staged" "$rc_target"
staged=''
print "적용 완료: $rc_target"
if [[ -z "$backup" ]]; then
  print "복구: 추가 편집이 없다면 새 설정 파일을 제거하세요: rm ${(q)rc_target}"
fi
print '새 zsh를 열고 whence -v pnpm, pnpm --version을 확인하세요. 기존 셸은 자동 변경하지 않습니다.'
print 'nvm use 이후에도 pnpm/pnpx 함수가 대상 경로를 사용합니다. command pnpm 등 함수 우회는 보장 대상이 아닙니다.'
