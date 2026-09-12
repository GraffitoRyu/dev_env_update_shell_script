#!/usr/bin/env zsh

IS_SOURCED=0
if [[ "${ZSH_EVAL_CONTEXT:-}" == *:file ]]; then
  IS_SOURCED=1
fi

main() {
  emulate -L zsh -o pipefail -o err_return -o no_unset
  setopt localoptions localtraps

  local script_path="${${(%):-%x}:A}"
  local script_dir="${script_path:A:h}"
  local log_dir="$script_dir/logs"
  local lock_dir="$log_dir/.update.lock"
  local lock_file="$log_dir/.update.flock"
  local lock_fd=-1
  local interrupted=0
  local pnpm_check_dir=""
  local lock_busy_exit_code=75
  local RUN_MODE="${1:-manual}"
  local IS_AUTO_RUN=0
  mkdir -p "$log_dir"

  if [[ "$RUN_MODE" == "--auto" || "${SHELL_UPDATE_AUTO:-0}" == "1" ]]; then
    IS_AUTO_RUN=1
  fi

  cleanup_lock() {
    if (( lock_fd >= 0 )); then
      zsystem flock -u "$lock_fd"
      lock_fd=-1
    fi
  }

  acquire_lock() {
    if ! zmodload zsh/system 2>/dev/null || ! zsystem supports flock; then
      echo "[ERROR] zsh file locking is unavailable."
      return 1
    fi

    # Respect an updater started with the previous directory-lock implementation.
    local lock_pid
    lock_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
    if [[ -n "$lock_pid" && "$lock_pid" == <-> ]] && kill -0 "$lock_pid" 2>/dev/null; then
      echo "[SKIP] update.sh is already running: $lock_dir (pid: $lock_pid)"
      return "$lock_busy_exit_code"
    fi

    # Keep the inode: deleting the file would let concurrent runs lock different files.
    : >> "$lock_file"
    if zsystem flock -t 0.001 -f lock_fd "$lock_file"; then
      return 0
    else
      local lock_status=$?
      if (( lock_status == 2 )); then
        echo "[SKIP] update.sh is already running: $lock_file"
        return "$lock_busy_exit_code"
      fi
      return "$lock_status"
    fi
  }

  # zsh handles these after the foreground command returns; keep its lock until then.
  trap 'interrupted=130; return "$interrupted"' INT
  trap 'interrupted=143; return "$interrupted"' TERM
  trap 'interrupted=129; return "$interrupted"' HUP

  local run_at
  run_at="$(date '+%Y-%m-%d_%H-%M-%S')"
  local log_file="$log_dir/update-$run_at.log"

  local RED='\033[31m'
  local GREEN='\033[32m'
  local YELLOW='\033[33m'
  local BLUE='\033[34m'
  local BOLD='\033[1m'
  local RESET='\033[0m'
  local NODE_LTS_VERSION='24'
  local error_reported=0

  keep_shell_open() {
    if (( IS_AUTO_RUN || interrupted || IS_SOURCED )) || [[ -o interactive ]]; then
      return 0
    fi

    if [[ -t 0 ]]; then
      echo ""
      echo "Enter를 누르면 interactive zsh로 전환합니다..."
      read "reply?"
      exec zsh -i
    fi
  }

  on_error() {
    local exit_code=$?
    local line_no=${1:-unknown}
    local error_context=${2:-unknown}

    if (( error_reported )); then
      return "$exit_code"
    fi
    error_reported=1

    echo ""
    echo "${BOLD}${RED}[ERROR]${RESET} 업데이트 루틴이 실패했습니다."
    echo "- exit code: $exit_code"
    echo "- line: $line_no"
    echo "- context: $error_context"
    echo "- log file: $log_file"

    keep_shell_open
    return "$exit_code"
  }

  on_success() {
    echo ""
    echo "- log file: $log_file"
    keep_shell_open
  }

  load_nvm() {
    setopt localoptions localtraps
    unsetopt err_return no_unset pipefail
    trap - ERR
    source "$1" --no-use
    local nvm_exit_code=$?
    (( interrupted )) && return "$interrupted"
    return "$nvm_exit_code"
  }

  run_nvm() {
    setopt localoptions localtraps
    unsetopt err_return no_unset pipefail
    trap - ERR
    NVM_NO_COLORS=1 nvm "$@"
    local nvm_exit_code=$?
    (( interrupted )) && return "$interrupted"
    return "$nvm_exit_code"
  }

  trap 'on_error ${LINENO} "${funcstack[1]:-main}"' ERR

  {
    if (( IS_AUTO_RUN )); then
      if acquire_lock; then
        :
      else
        return $?
      fi
    fi

    echo ""
    echo "┎⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯┒"
    echo "┃        ✨ ${BOLD}${YELLOW}업데이트 루틴을 실행합니다!${RESET}        ┃"
    echo "┃   log: $log_file"
    echo "┖⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯┚"
    echo ""

    if (( ! $+commands[brew] )); then
      echo "${BOLD}${RED}[ERROR]${RESET} Homebrew 명령을 찾을 수 없습니다."
      return 127
    fi

    local PNPM_MAJOR
    source "$script_dir/pnpm-policy.zsh"
    if [[ "$PNPM_MAJOR" != <-> ]] || (( PNPM_MAJOR < 1 )); then
      echo "[ERROR] pnpm-policy.zsh의 PNPM_MAJOR는 양의 정수여야 합니다."
      return 1
    fi
    local pnpm_formula="pnpm@$PNPM_MAJOR"
    local formula

    echo " ${BLUE}↺${RESET} ${YELLOW}[1/6] Homebrew 업데이트 실행중...${RESET}"
    brew update
    echo " ${GREEN}✓${RESET} ${YELLOW}[1/6]${RESET} ${YELLOW}Homebrew 업데이트 루틴 완료!${RESET}"

    echo ""
    echo "------------------------------------------------"
    echo ""

    echo " ${BLUE}↺${RESET} ${YELLOW}[2/6] Homebrew 패키지 업데이트 실행중...${RESET}"

    if (( IS_AUTO_RUN )); then
      echo "${BOLD}${YELLOW}[SKIP]${RESET} 자동 실행 모드에서는 Password 프롬프트 방지를 위해 전체 Homebrew 업그레이드를 건너뜁니다."
      echo "- 전체 Homebrew 업그레이드가 필요하면 아래 명령을 터미널에서 직접 실행하세요."
      echo "  zsh $script_path"
    elif [[ ! -t 0 ]]; then
      echo "${BOLD}${YELLOW}[SKIP]${RESET} 비대화형 실행 환경에서는 Password 프롬프트 방지를 위해 전체 Homebrew 업그레이드를 건너뜁니다."
      echo "- 전체 Homebrew 업그레이드가 필요하면 아래 명령을 터미널에서 직접 실행하세요."
      echo "  zsh $script_path"
    else
      echo "${BOLD}${YELLOW}[INFO]${RESET} Homebrew cask 업데이트 중 macOS 관리자 비밀번호가 필요할 수 있습니다."
      echo "${BOLD}${YELLOW}[INFO]${RESET} Password 요청이 나오면 이 수동 실행 터미널에서 직접 입력하세요."
      local outdated_formulae
      local -a upgrade_formulae=()
      outdated_formulae="$(brew outdated --formula --quiet)"
      for formula in ${(f)outdated_formulae}; do
        [[ "${formula:t}" == pnpm || "${formula:t}" == pnpm@* ]] || upgrade_formulae+=("$formula")
      done
      if (( ${#upgrade_formulae} )); then
        brew upgrade --formula "${upgrade_formulae[@]}"
      fi
      brew upgrade --cask
    fi

    echo " ${GREEN}✓${RESET} ${YELLOW}[2/6]${RESET} ${YELLOW}Homebrew 패키지 업데이트 루틴 완료!${RESET}"

    echo ""
    echo "------------------------------------------------"
    echo ""

    echo " ${BLUE}↺${RESET} ${YELLOW}[3/6] Node.js 최신 업데이트 확인중...${RESET}"

    local nvm_prefix
    local nvm_script
    if nvm_prefix="$(brew --prefix nvm 2>/dev/null)"; then
      nvm_script="$nvm_prefix/nvm.sh"
    else
      echo "${BOLD}${RED}[ERROR]${RESET} Homebrew로 설치된 nvm 경로를 찾을 수 없습니다."
      echo "- 확인 명령: brew --prefix nvm"
      return 1
    fi

    if [[ ! -s "$nvm_script" ]]; then
      echo "${BOLD}${RED}[ERROR]${RESET} nvm 초기화 스크립트를 찾을 수 없습니다."
      echo "- expected: $nvm_script"
      return 1
    fi

    export NVM_DIR="$HOME/.nvm"
    if load_nvm "$nvm_script" && (( $+functions[nvm] )); then
      :
    else
      echo "${BOLD}${RED}[ERROR]${RESET} nvm 초기화에 실패했습니다."
      echo "- script: $nvm_script"
      return $(( interrupted ? interrupted : 1 ))
    fi

    local latest_node_version
    local current_node_version
    local remote_node_versions
    if remote_node_versions="$(run_nvm ls-remote)"; then
      latest_node_version="$(
        print -r -- "$remote_node_versions" \
          | grep -o "v$NODE_LTS_VERSION\.[0-9]*\.[0-9]*" \
          | tail -n 1 \
          || true
      )"
    else
      local nvm_remote_exit_code=$?
      echo "${BOLD}${RED}[ERROR]${RESET} 원격 Node.js 버전 목록 조회에 실패했습니다."
      return "$nvm_remote_exit_code"
    fi

    if [[ -z "$latest_node_version" ]]; then
      echo "${BOLD}${RED}[ERROR]${RESET} Node.js v$NODE_LTS_VERSION 최신 버전을 확인할 수 없습니다."
      return 1
    fi

    if (( $+commands[node] )); then
      current_node_version="$(node -v)"
    else
      current_node_version=""
    fi

    echo ""
    echo "${BOLD}${RED}- Latest:${RESET} $latest_node_version"
    echo "${BOLD}${RED}- Current:${RESET} ${current_node_version:-미설치 또는 비활성}"
    echo ""

    if run_nvm which "$latest_node_version" >/dev/null 2>&1; then
      echo "Node.js $latest_node_version 설치를 확인했습니다."
    else
      (( interrupted )) && return "$interrupted"
      echo "Node.js $latest_node_version 설치중..."
      if run_nvm install "$latest_node_version"; then
        :
      else
        local nvm_install_exit_code=$?
        echo "${BOLD}${RED}[ERROR]${RESET} Node.js $latest_node_version 설치에 실패했습니다."
        return "$nvm_install_exit_code"
      fi
    fi

    if run_nvm use "$latest_node_version"; then
      :
    else
      local nvm_use_exit_code=$?
      echo "${BOLD}${RED}[ERROR]${RESET} Node.js $latest_node_version 활성화에 실패했습니다."
      return "$nvm_use_exit_code"
    fi

    if run_nvm alias default "$latest_node_version" >/dev/null; then
      :
    else
      local nvm_alias_exit_code=$?
      echo "${BOLD}${RED}[ERROR]${RESET} Node.js 기본 버전 설정에 실패했습니다."
      return "$nvm_alias_exit_code"
    fi

    rehash
    if (( ! $+commands[node] )); then
      echo "${BOLD}${RED}[ERROR]${RESET} Node.js $latest_node_version 활성화 후에도 node 명령을 찾을 수 없습니다."
      return 1
    fi

    local node_root="$NVM_DIR/versions/node/$latest_node_version"
    node_root="${node_root:A}"
    local node_path="$(command -v node)"
    if [[ "${node_path:A}" != "$node_root"/* ]]; then
      echo "${BOLD}${RED}[ERROR]${RESET} 활성 node가 목표 nvm 설치 경로에 속하지 않습니다."
      echo "- expected root: $node_root"
      echo "- actual: $node_path"
      return 1
    fi

    current_node_version="$(node -v)"
    if [[ "$current_node_version" != "$latest_node_version" ]]; then
      echo "${BOLD}${RED}[ERROR]${RESET} 활성 Node.js 버전이 기대한 버전과 다릅니다."
      echo "- expected: $latest_node_version"
      echo "- actual: $current_node_version"
      return 1
    fi

    echo "${BOLD}${GREEN}- Default:${RESET} $latest_node_version"

    echo ""
    echo " ${GREEN}✓${RESET} ${YELLOW}[3/6]${RESET} ${YELLOW}Node.js 업데이트 루틴 완료!${RESET}"

    echo ""
    echo "------------------------------------------------"
    echo ""

    echo " ${BLUE}↺${RESET} ${YELLOW}[4/6] npm 상태 점검중...${RESET}"

    local npm_path
    local npm_version

    npm_path="$(command -v npm 2>/dev/null || true)"
    if [[ -n "$npm_path" && "${npm_path:A}" != "$node_root"/* ]]; then
      echo "${BOLD}${RED}[ERROR]${RESET} 활성 npm이 목표 nvm 설치 경로에 속하지 않습니다."
      echo "- expected root: $node_root"
      echo "- actual: ${npm_path:-not found}"
      return 1
    fi

    if [[ -n "$npm_path" ]] && npm_version="$(npm -v 2>/dev/null)"; then
      :
    else
      npm_version=""
    fi

    echo "- node path: $(command -v node || echo 'not found')"
    echo "- npm path: ${npm_path:-not found}"
    echo "- node version: $(node -v 2>/dev/null || echo 'unavailable')"
    echo "- npm version: ${npm_version:-unavailable}"

    if [[ -z "$npm_path" || -z "$npm_version" ]]; then
      echo "${BOLD}${RED}[ERROR]${RESET} 현재 활성 Node.js 설치에서 npm을 정상 실행할 수 없습니다."
      echo "- 자동 복구는 중단합니다. 손상된 nvm 설치를 스크립트에서 계속 건드리면 문제가 커질 수 있습니다."
      echo "- 아래 명령을 터미널에서 1회 수동 실행한 뒤 다시 update.sh를 실행하세요."
      echo ""
      echo "  nvm deactivate"
      echo "  nvm uninstall $current_node_version"
      echo "  nvm cache clear"
      echo "  nvm install $current_node_version"
      echo "  nvm use $current_node_version"
      echo "  nvm alias default $current_node_version"
      return 1
    fi

    echo "- npm 상태가 정상입니다. 별도 npm self-update 단계는 건너뜁니다."
    echo ""
    echo " ${GREEN}✓${RESET} ${YELLOW}[4/6]${RESET} ${YELLOW}npm 상태 점검 루틴 완료!${RESET}"

    echo ""
    echo "------------------------------------------------"
    echo ""

    echo " ${BLUE}↺${RESET} ${YELLOW}[5/6] $pnpm_formula 업데이트 실행중...${RESET}"
    local pnpm_prefix pinned_formulae
    if pnpm_prefix="$(brew --prefix --installed "$pnpm_formula" 2>/dev/null)"; then
      :
    else
      echo "[ERROR] $pnpm_formula 설치가 필요합니다. docs/pnpm-migration.md의 전환 절차를 실행하세요."
      return 1
    fi
    pinned_formulae="$(brew list --formula --pinned)"
    for formula in ${(f)pinned_formulae}; do
      if [[ "${formula:t}" == "$pnpm_formula" ]]; then
        echo "[ERROR] $pnpm_formula 버전이 pin되어 최신 업데이트가 차단되었습니다. pin 상태를 직접 확인하세요."
        return 1
      fi
    done
    brew upgrade "$pnpm_formula"

    local pnpm_path="$pnpm_prefix/bin/pnpm"
    if [[ ! -x "$pnpm_path" || "${pnpm_path:A}" != "${pnpm_prefix:A}"/* ]]; then
      echo "[ERROR] pnpm 실행 파일이 $pnpm_formula 설치 경로에 속하지 않습니다: $pnpm_path"
      return 1
    fi
    local pnpm_version
    pnpm_check_dir="$(mktemp -d "${TMPDIR:-/tmp}/pnpm-version.XXXXXX")"
    pnpm_version="$(cd "$pnpm_check_dir" && "$pnpm_path" --version)"
    if [[ "$pnpm_version" != "$PNPM_MAJOR".<->.<-> ]]; then
      echo "[ERROR] pnpm 버전이 승인된 메이저와 다릅니다: $pnpm_version (expected: $PNPM_MAJOR.x.x)"
      return 1
    fi
    command rm -rf "$pnpm_check_dir"
    pnpm_check_dir=""
    echo "- pnpm path: $pnpm_path"
    echo "- pnpm version: $pnpm_version"
    echo " ${GREEN}✓${RESET} ${YELLOW}[5/6]${RESET} pnpm 업데이트 루틴 완료!"
    echo ""

    echo " ${BLUE}↺${RESET} ${YELLOW}[6/6] npm 글로벌 패키지 업데이트 실행중...${RESET}"
    echo "- (1/3) vite 업데이트중..."
    npm i -g vite@latest
    echo ""
    echo "- (2/3) http-server 업데이트중..."
    npm i -g http-server@latest
    echo ""
    echo "- (3/3) npm-check-updates 업데이트중..."
    npm i -g npm-check-updates@latest
    echo ""
    echo " ${GREEN}✓${RESET} ${YELLOW}[6/6]${RESET} ${YELLOW}npm 글로벌 패키지 업데이트 루틴 완료!${RESET}"

    echo ""
    echo "┎⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯┒"
    echo "┃      🎉 ${BOLD}${YELLOW}업데이트 루틴이 완료되었습니다!${RESET}      ┃"
    echo "┖⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯┚"
    echo ""

    on_success
  } always {
    [[ -z "$pnpm_check_dir" ]] || command rm -rf "$pnpm_check_dir"
    cleanup_lock
  } > >(tee -a "$log_file") 2>&1

  return 0
}

main "$@"
main_exit_code=$?

if (( IS_SOURCED )); then
  return "$main_exit_code"
fi

exit "$main_exit_code"
