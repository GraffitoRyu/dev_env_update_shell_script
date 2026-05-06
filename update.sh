#!/usr/bin/env zsh

IS_SOURCED=0
if [[ "${ZSH_EVAL_CONTEXT:-}" == *:file ]]; then
  IS_SOURCED=1
fi

main() {
  emulate -L zsh -o pipefail -o err_return -o no_unset
  setopt localoptions localtraps
  local UPDATE_DIR="${HOME}/projects/shell-update"

  export NVM_DIR="$HOME/.nvm"
  [ -s "/opt/homebrew/opt/nvm/nvm.sh" ] && \. "/opt/homebrew/opt/nvm/nvm.sh"
  [ -s "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm" ] && \. "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm"

  local script_path
  if (( IS_SOURCED )); then
    script_path="$UPDATE_DIR/update.sh"
  else
    script_path="${(%):-%N}"
  fi
  local script_dir="${script_path:A:h}"
  local log_dir="$script_dir/logs"
  local lock_dir="$log_dir/.update.lock"
  local current_pid
  local lock_busy_exit_code=75
  mkdir -p "$log_dir"

  if zmodload zsh/system 2>/dev/null; then
    current_pid="$sysparams[pid]"
  else
    current_pid="$$"
  fi

  cleanup_lock() {
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

  acquire_lock
  local lock_exit_code=$?
  if (( lock_exit_code != 0 )); then
    return "$lock_exit_code"
  fi
  trap 'cleanup_lock' EXIT INT TERM HUP

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
  local RUN_MODE="${1:-manual}"
  local IS_AUTO_RUN=0

  if [[ "$RUN_MODE" == "--auto" || "${SHELL_UPDATE_AUTO:-0}" == "1" ]]; then
    IS_AUTO_RUN=1
  fi

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
    local failed_command=${2:-unknown}

    echo ""
    echo "${BOLD}${RED}[ERROR]${RESET} 업데이트 루틴이 실패했습니다."
    echo "- exit code: $exit_code"
    echo "- line: $line_no"
    echo "- command: $failed_command"
    echo "- log file: $log_file"

    keep_shell_open
    return "$exit_code"
  }

  on_success() {
    echo ""
    echo "- log file: $log_file"
    keep_shell_open
  }

  trap 'on_error ${LINENO} "${funcstack[1]:-main}"' ERR

  {
    echo ""
    echo "┎⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯┒"
    echo "┃        ✨ ${BOLD}${YELLOW}업데이트 루틴을 실행합니다!${RESET}        ┃"
    echo "┃   log: $log_file"
    echo "┖⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯┚"
    echo ""

    echo " ${BLUE}↺${RESET} ${YELLOW}[1/5] Homebrew 업데이트 실행중...${RESET}"
    brew update-reset "$(brew --repository)"
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

    local latest_node_version
    local current_node_version
    latest_node_version="$(nvm ls-remote | grep -o "v$NODE_LTS_VERSION\.[0-9]*\.[0-9]*" | tail -n 1)"
    current_node_version="$(node -v)"

    echo ""
    echo "${BOLD}${RED}- Latest:${RESET} $latest_node_version"
    echo "${BOLD}${RED}- Current:${RESET} $current_node_version"
    echo ""

    if [[ "$latest_node_version" != "$current_node_version" ]]; then
      echo "${BOLD}${RED}Node.js가 최신 버전이 아닙니다. 업데이트를 진행합니다...${RESET}"
      echo ""
      echo "- (1/6) Node.js $latest_node_version 설치중..."
      nvm install "$latest_node_version"
      echo ""
      echo "- (2/6) Node.js $latest_node_version 활성화중..."
      nvm use "$latest_node_version"
      rehash
      echo ""
      echo "- (3/6) Node.js $latest_node_version 버전을 기본 버전으로 설정중..."
      nvm alias default "$latest_node_version"
      current_node_version="$(node -v)"
      echo ""
      echo "${BOLD}${RED}Node.js가 업데이트되었습니다:${RESET} ${BOLD}${YELLOW}$(node -v)${RESET}"
      echo ""
      echo "- (4/6) vite 글로벌 패키지 설치중..."
      npm i -g vite@latest
      echo ""
      echo "- (5/6) pnpm 글로벌 패키지 설치중..."
      npm i -g pnpm@latest
      echo ""
      echo "- (6/6) http-server 글로벌 패키지 설치중..."
      npm i -g http-server@latest
    else
      echo "${BOLD}${RED}Node.js가 이미 최신 버전입니다.${RESET}"
    fi

    echo ""
    echo " ${GREEN}✓${RESET} ${YELLOW}[3/5]${RESET} ${YELLOW}Node.js 업데이트 루틴 완료!${RESET}"

    echo ""
    echo "------------------------------------------------"
    echo ""

    echo " ${BLUE}↺${RESET} ${YELLOW}[4/5] npm 상태 점검중...${RESET}"

    local npm_path
    local npm_version

    npm_path="$(command -v npm || true)"
    npm_version="$(npm -v 2>/dev/null || true)"

    echo "- node path: $(command -v node || echo 'not found')"
    echo "- npm path: ${npm_path:-not found}"
    echo "- node version: $(node -v 2>/dev/null || echo 'unavailable')"
    echo "- npm version: ${npm_version:-unavailable}"

    if [[ -z "$npm_path" ]]; then
      echo "${BOLD}${RED}[ERROR]${RESET} 현재 활성 Node.js 설치에서 npm을 찾을 수 없습니다."
      echo "- 자동 복구는 중단합니다. 손상된 nvm 설치를 스크립트에서 계속 건드리면 문제가 커질 수 있습니다."
      echo "- 아래 명령을 터미널에서 1회 수동 실행한 뒤 다시 update.sh를 실행하세요."
      echo ""
      echo "  nvm deactivate"
      echo "  nvm uninstall $current_node_version"
      echo "  nvm cache clear"
      echo "  nvm install $current_node_version"
      echo "  nvm use $current_node_version"
      echo "  nvm alias default $current_node_version"
      echo ""
      echo "- log file: $log_file"
      keep_shell_open
      return 1
    fi

    echo "- npm 상태가 정상입니다. 별도 npm self-update 단계는 건너뜁니다."
    echo ""
    echo " ${GREEN}✓${RESET} ${YELLOW}[4/5]${RESET} ${YELLOW}npm 상태 점검 루틴 완료!${RESET}"

    echo ""
    echo "------------------------------------------------"
    echo ""

    echo " ${BLUE}↺${RESET} ${YELLOW}[5/5] npm-check-updates 업데이트 실행중...${RESET}"
    npm i -g npm-check-updates@latest
    echo ""
    echo " ${GREEN}✓${RESET} ${YELLOW}[5/5]${RESET} ${YELLOW}npm-check-updates 업데이트 루틴 완료!${RESET}"

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
