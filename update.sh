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
  local current_pid
  local lock_busy_exit_code=75
  local RUN_MODE="${1:-manual}"
  local IS_AUTO_RUN=0
  mkdir -p "$log_dir"

  if [[ "$RUN_MODE" == "--auto" || "${SHELL_UPDATE_AUTO:-0}" == "1" ]]; then
    IS_AUTO_RUN=1
  fi

  if zmodload zsh/system 2>/dev/null; then
    current_pid="$sysparams[pid]"
  else
    current_pid="$$"
  fi

  cleanup_lock() {
    (( IS_AUTO_RUN )) || return 0
    command rm -f "$lock_dir/pid" "$lock_dir/started_at" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true
  }

  acquire_lock() {
    if mkdir "$lock_dir" 2>/dev/null; then
      echo "$current_pid" > "$lock_dir/pid"
      date '+%Y-%m-%d_%H-%M-%S' > "$lock_dir/started_at"
      return 0
    fi

    local lock_pid
    lock_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"

    if [[ -n "$lock_pid" && "$lock_pid" == <-> ]] && kill -0 "$lock_pid" 2>/dev/null; then
      echo "[SKIP] update.sh is already running: $lock_dir (pid: $lock_pid)"
      return "$lock_busy_exit_code"
    fi

    echo "[WARN] stale update lock removed: $lock_dir"
    cleanup_lock

    if mkdir "$lock_dir" 2>/dev/null; then
      echo "$current_pid" > "$lock_dir/pid"
      date '+%Y-%m-%d_%H-%M-%S' > "$lock_dir/started_at"
      return 0
    fi

    echo "[SKIP] update.sh is already running: $lock_dir"
    return "$lock_busy_exit_code"
  }

  if (( IS_AUTO_RUN )); then
    acquire_lock
    local lock_exit_code=$?
    if (( lock_exit_code != 0 )); then
      return "$lock_exit_code"
    fi
    trap 'cleanup_lock' EXIT INT TERM HUP
  fi

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
    if (( IS_SOURCED )) || [[ -o interactive ]]; then
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
  }

  run_nvm() {
    setopt localoptions localtraps
    unsetopt err_return no_unset pipefail
    trap - ERR
    NVM_NO_COLORS=1 nvm "$@"
  }

  trap 'on_error ${LINENO} "${funcstack[1]:-main}"' ERR

  {
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

    echo " ${BLUE}↺${RESET} ${YELLOW}[1/5] Homebrew 업데이트 실행중...${RESET}"
    brew update
    echo " ${GREEN}✓${RESET} ${YELLOW}[1/5]${RESET} ${YELLOW}Homebrew 업데이트 루틴 완료!${RESET}"

    echo ""
    echo "------------------------------------------------"
    echo ""

    echo " ${BLUE}↺${RESET} ${YELLOW}[2/5] Homebrew 패키지 업데이트 실행중...${RESET}"

    if (( IS_AUTO_RUN )); then
      echo "${BOLD}${YELLOW}[SKIP]${RESET} 자동 실행 모드에서는 Password 프롬프트 방지를 위해 brew upgrade를 건너뜁니다."
      echo "- 전체 Homebrew 업그레이드가 필요하면 아래 명령을 터미널에서 직접 실행하세요."
      echo "  zsh $script_path"
    elif [[ ! -t 0 ]]; then
      echo "${BOLD}${YELLOW}[SKIP]${RESET} 비대화형 실행 환경에서는 Password 프롬프트 방지를 위해 brew upgrade를 건너뜁니다."
      echo "- 전체 Homebrew 업그레이드가 필요하면 아래 명령을 터미널에서 직접 실행하세요."
      echo "  zsh $script_path"
    else
      echo "${BOLD}${YELLOW}[INFO]${RESET} Homebrew cask 업데이트 중 macOS 관리자 비밀번호가 필요할 수 있습니다."
      echo "${BOLD}${YELLOW}[INFO]${RESET} Password 요청이 나오면 이 수동 실행 터미널에서 직접 입력하세요."
      brew upgrade
    fi

    echo " ${GREEN}✓${RESET} ${YELLOW}[2/5]${RESET} ${YELLOW}Homebrew 패키지 업데이트 루틴 완료!${RESET}"

    echo ""
    echo "------------------------------------------------"
    echo ""

    echo " ${BLUE}↺${RESET} ${YELLOW}[3/5] Node.js 최신 업데이트 확인중...${RESET}"

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
      return 1
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

    if [[ "$latest_node_version" != "$current_node_version" ]]; then
      echo "${BOLD}${RED}Node.js가 최신 버전이 아닙니다. 업데이트를 진행합니다...${RESET}"
      echo ""
      echo "- (1/2) Node.js $latest_node_version 설치중..."
      if run_nvm install "$latest_node_version"; then
        :
      else
        local nvm_install_exit_code=$?
        echo "${BOLD}${RED}[ERROR]${RESET} Node.js $latest_node_version 설치에 실패했습니다."
        return "$nvm_install_exit_code"
      fi
      echo ""
      echo "- (2/2) Node.js $latest_node_version 활성화중..."
      if run_nvm use "$latest_node_version"; then
        :
      else
        local nvm_use_exit_code=$?
        echo "${BOLD}${RED}[ERROR]${RESET} Node.js $latest_node_version 활성화에 실패했습니다."
        return "$nvm_use_exit_code"
      fi
      rehash
    else
      echo "${BOLD}${RED}Node.js가 이미 최신 버전입니다.${RESET}"
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

    current_node_version="$(node -v)"
    if [[ "$current_node_version" != "$latest_node_version" ]]; then
      echo "${BOLD}${RED}[ERROR]${RESET} 활성 Node.js 버전이 기대한 버전과 다릅니다."
      echo "- expected: $latest_node_version"
      echo "- actual: $current_node_version"
      return 1
    fi

    echo "${BOLD}${GREEN}- Default:${RESET} $latest_node_version"

    echo ""
    echo " ${GREEN}✓${RESET} ${YELLOW}[3/5]${RESET} ${YELLOW}Node.js 업데이트 루틴 완료!${RESET}"

    echo ""
    echo "------------------------------------------------"
    echo ""

    echo " ${BLUE}↺${RESET} ${YELLOW}[4/5] npm 상태 점검중...${RESET}"

    local npm_path
    local npm_version

    npm_path="$(command -v npm 2>/dev/null || true)"
    if [[ -n "$npm_path" ]]; then
      npm_version="$(npm -v 2>/dev/null || true)"
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
    echo " ${GREEN}✓${RESET} ${YELLOW}[4/5]${RESET} ${YELLOW}npm 상태 점검 루틴 완료!${RESET}"

    echo ""
    echo "------------------------------------------------"
    echo ""

    echo " ${BLUE}↺${RESET} ${YELLOW}[5/5] npm 글로벌 패키지 업데이트 실행중...${RESET}"
    echo "- (1/4) vite 업데이트중..."
    npm i -g vite@latest
    echo ""
    echo "- (2/4) pnpm 업데이트중..."
    npm i -g pnpm@latest
    echo ""
    echo "- (3/4) http-server 업데이트중..."
    npm i -g http-server@latest
    echo ""
    echo "- (4/4) npm-check-updates 업데이트중..."
    npm i -g npm-check-updates@latest
    echo ""
    echo " ${GREEN}✓${RESET} ${YELLOW}[5/5]${RESET} ${YELLOW}npm 글로벌 패키지 업데이트 루틴 완료!${RESET}"

    echo ""
    echo "┎⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯┒"
    echo "┃      🎉 ${BOLD}${YELLOW}업데이트 루틴이 완료되었습니다!${RESET}      ┃"
    echo "┖⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯┚"
    echo ""

    on_success
  } always {
    cleanup_lock
    trap - EXIT INT TERM HUP
  } > >(tee -a "$log_file") 2>&1

  return 0
}

main "$@"
main_exit_code=$?

if (( IS_SOURCED )); then
  return "$main_exit_code"
fi

exit "$main_exit_code"
