#!/usr/bin/env zsh
set -euo pipefail
setopt ERR_RETURN

export NVM_DIR="$HOME/.nvm"
[ -s "/opt/homebrew/opt/nvm/nvm.sh" ] && \. "/opt/homebrew/opt/nvm/nvm.sh"
[ -s "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm" ] && \. "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm"

SCRIPT_DIR="${0:A:h}"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
RUN_AT="$(date '+%Y-%m-%d_%H-%M-%S')"
LOG_FILE="$LOG_DIR/update-$RUN_AT.log"

exec > >(tee -a "$LOG_FILE") 2>&1

keep_shell_open() {
  if [[ -o interactive ]]; then
    return
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
  echo "- log file: $LOG_FILE"
  keep_shell_open
  exit $exit_code
}

on_exit() {
  local exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    echo ""
    echo "- log file: $LOG_FILE"
    keep_shell_open
  fi
}

# 색상 코드 설정
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
BOLD='\033[1m'
RESET='\033[0m'  # 리셋 코드

trap 'on_error ${LINENO} "${funcstack[1]:-main}"' ERR
trap 'on_exit' EXIT

# Node.js LTS 기준 버전
NODE_LTS_VERSION='24'

# 업데이트 루틴 인덱스
# 1. Homebrew 업데이트
# 2. Homebrew 업그레이드
# 3. Node.js LTS 버전 업데이트 확인
# 3-1. 신규 버전 업데이트 설치
# 3-2. 신규 버전으로 활성화
# 3-3. 신규 버전을 default로 설정
# 3-4. vite 글로벌 업데이트 설치
# 3-5. pnpm 글로벌 업데이트 설치
# 3-6. http-server 글로벌 설치
# 4. npm 업데이트
# 5. npm-check-updates 업데이트

echo "\n┎⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯┒"
echo "┃        ✨ ${BOLD}${YELLOW}업데이트 루틴을 실행합니다!${RESET}        ┃"
echo "┃   log: $LOG_FILE"
echo "┖⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯┚\n"

# Homebrew 업데이트 및 업그레이드
echo " ${BLUE}↺${RESET} ${YELLOW}[1/5] Homebrew 업데이트 실행중...${RESET}"
# brew update
brew update-reset "$(brew --repository)"
echo " ${GREEN}✓${RESET} ${YELLOW}[1/5]${RESET} ${YELLOW}Homebrew 업데이트 루틴 완료!${RESET}"

echo "\n------------------------------------------------\n"
echo " ${BLUE}↺${RESET} ${YELLOW}[2/5] Homebrew 패키지 업데이트 실행중...${RESET}"
brew upgrade
echo " ${GREEN}✓${RESET} ${YELLOW}[2/5]${RESET} ${YELLOW}Homebrew 패키지 업데이트 루틴 완료!${RESET}"

# Node.js 최신버전 업데이트 확인
echo "\n------------------------------------------------\n"
echo " ${BLUE}↺${RESET} ${YELLOW}[3/5] Node.js 최신 업데이트 확인중...${RESET}"

LATEST_NODE_VERSION=$(nvm ls-remote | grep -o "v$NODE_LTS_VERSION\.[0-9]*\.[0-9]*" | tail -n 1)
CURRENT_NODE_VERSION=$(node -v)
echo ""
echo "${BOLD}${RED}- Latest:${RESET} $LATEST_NODE_VERSION"
echo "${BOLD}${RED}- Current:${RESET} $CURRENT_NODE_VERSION"
echo ""

# Node.js 버전이 최신이 아닐 경우 업데이트 수행
if [ "$LATEST_NODE_VERSION" != "$CURRENT_NODE_VERSION" ]; then
  echo "${BOLD}${RED}Node.js가 최신 버전이 아닙니다. 업데이트를 진행합니다...${RESET}"
  echo "\n- (1/5) Node.js $LATEST_NODE_VERSION 설치중..."
  nvm install $LATEST_NODE_VERSION
  echo "\n- (2/5) Node.js $LATEST_NODE_VERSION 활성화중..."
  nvm use $LATEST_NODE_VERSION
  rehash
  echo "\n- (3/5) Node.js $LATEST_NODE_VERSION 버전을 기본 버전으로 설정중..."
  nvm alias default $LATEST_NODE_VERSION
  echo "\n${BOLD}${RED}Node.js가 업데이트되었습니다:${RESET} ${BOLD}${YELLOW}$(node -v)${RESET}"
  echo "\n- (4/6) vite 글로벌 패키지 설치중..."
  npm i -g vite@latest
  echo "\n- (5/6) pnpm 글로벌 패키지 설치중..."
  npm i -g pnpm@latest
  echo "\n- (6/6) http-server 글로벌 패키지 설치중..."
  npm i -g http-server@latest
else
  echo "${BOLD}${RED}Node.js가 이미 최신 버전입니다.${RESET}"
fi
echo "\n ${GREEN}✓${RESET} ${YELLOW}[3/5]${RESET} ${YELLOW}Node.js 업데이트 루틴 완료!${RESET}"

# npm과 npm-check-updates 최신 버전으로 설치
echo "\n------------------------------------------------\n"
echo " ${BLUE}↺${RESET} ${YELLOW}[4/5] npm 업데이트 실행중...${RESET}"
echo "- node path: $(command -v node || echo 'not found')"
echo "- npm path: $(command -v npm || echo 'not found')"
echo "- nvm path: $(command -v nvm || echo 'not found')"
echo "- node version: $(node -v 2>/dev/null || echo 'unavailable')"
echo "- npm version(before): $(npm -v 2>/dev/null || echo 'unavailable')"
if ! nvm install-latest-npm; then
  echo "${BOLD}${RED}[ERROR]${RESET} npm 업데이트에 실패했습니다."
  echo "- reason: nvm install-latest-npm failed"
  echo "- log file: $LOG_FILE"
  keep_shell_open
  exit 1
fi
rehash
echo "- npm version(after): $(npm -v 2>/dev/null || echo 'unavailable')"
echo "\n ${GREEN}✓${RESET} ${YELLOW}[4/5]${RESET} ${YELLOW}npm 업데이트 루틴 완료!${RESET}"

echo "\n------------------------------------------------\n"
echo " ${BLUE}↺${RESET} ${YELLOW}[5/5] npm-check-updates 업데이트 실행중...${RESET}"
npm i -g npm-check-updates@latest
echo "\n ${GREEN}✓${RESET} ${YELLOW}[5/5]${RESET} ${YELLOW}npm-check-updates 업데이트 루틴 완료!${RESET}"

echo "\n┎⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯┒"
echo "┃      🎉 ${BOLD}${YELLOW}업데이트 루틴이 완료되었습니다!${RESET}      ┃"
echo "┖⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯┚\n"
