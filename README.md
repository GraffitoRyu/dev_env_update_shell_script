# 개발환경 자동화 스크립트

매일 iTerm 첫 실행 시 동작하도록 구성된 셸 스크립트

- 개발도구의 최신화 유지 목적
- zsh 환경에서 실행되도록 구성

## 1. 동작환경

- zsh

## 2. 관리 대상

- Homebrew 및 Homebrew 설치 패키지
- nvm
- Node.js
- Python
- npm
- pnpm
- vite
- npm-check-update

## 3. .zshrc

```bash
# ...앞 내용 생략
# 노드/파이썬 실행

# 노드 & 파이썬 실행
export NVM_DIR="$HOME/.nvm"
[ -s "/opt/homebrew/opt/nvm/nvm.sh" ] && \. "/opt/homebrew/opt/nvm/nvm.sh"  # This loads nvm
[ -s "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm" ] && \. "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm"  # This loads nvm bash_completion
export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"

eval "$(pyenv init -)"


# 업데이트 루틴 스크립트 자동 실행 설정
# 플래그 파일 경로 설정
UPDATE_FLAG="$HOME/.update_ran"

# 매일 자정 플래그 파일 초기화
if [[ $(date +%F) != $(cat $HOME/.update_last_run 2>/dev/null) ]]; then
  rm -f "$UPDATE_FLAG"  # 플래그 파일 제거
  date +%F > $HOME/.update_last_run  # 마지막 실행 날짜 업데이트
fi

# 플래그 파일이 없을 경우에만 업데이트 스크립트를 실행
if [ ! -f "$UPDATE_FLAG" ]; then
  echo "[업데이트 루틴 실행]"
  source ~/projects/update_env/update.sh  # 스크립트를 첫 실행에만 실행하도록 설정
  touch "$UPDATE_FLAG"  # 플래그 파일 생성
fi

```

## 4. 오류발생 대처

### npm 인식 오류

- 루틴 진행 이후, npm 인식이 되지 않는 경우, nvm 에서 해당 버전을 재설치한다.
- update.sh로 설치하는 이유는, 글로벌 패키지까지 한번에 설치하고 루틴 정상화 테크역할까지 겸할 수 있기 때문.
- npm 글로벌 업데이트 시, `nvm install-latest-npm`를 실행하여 처리한다.

```bash
nvm uninstall XX.XX.XX
source ~/projects/update_env/update.sh
```
