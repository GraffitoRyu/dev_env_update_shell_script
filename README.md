# 개발환경 자동화 스크립트

매일 iTerm 첫 실행 시 동작하도록 구성된 셸 스크립트

- MacOS 환경 기준
- 개발도구의 최신화 유지 목적
- Homebrew 및 zsh 환경에서 실행되도록 구성

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

## 3. 파일 생성

- 개발환경 첫 셋업 시, `homebrew`로 설치되는 루트 폴더에 `.nvm` 폴더 생성할 것.
- 프로젝트 폴더에 아래의 파일 생성할 것.

```plaintext
.date-cache
.latest-date
```

## 4. .zshrc

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
UPDATE_DIR="$HOME/{프로젝트 폴더 경로}"
# 플래그 파일 경로 설정
UPDATE_FLAG="$UPDATE_DIR/.date-cache"
LAST_UPDATE="$UPDATE_DIR/.latest-date"

# 매일 자정 플래그 파일 초기화
if [[ $(date +%F) != $(cat $LAST_UPDATE 2>/dev/null) ]]; then
  rm -f "$UPDATE_FLAG"  # 플래그 파일 제거
  date +%F > $LAST_UPDATE  # 마지막 실행 날짜 업데이트
fi

# 플래그 파일이 없을 경우에만 업데이트 스크립트를 실행
if [ ! -f "$UPDATE_FLAG" ]; then
  echo "[업데이트 루틴 실행]"
  source $UPDATE_DIR/update.sh  # 스크립트를 첫 실행에만 실행하도록 설정
  touch "$UPDATE_FLAG"  # 플래그 파일 생성
fi

```

## 5. 오류발생 대처

### npm 인식 오류

- 루틴 진행 이후, npm 인식이 되지 않는 경우, nvm 에서 해당 버전을 재설치한다.
- update.sh로 설치하는 이유는, 글로벌 패키지까지 한번에 설치하고 루틴 정상화 테크역할까지 겸할 수 있기 때문.
- npm 글로벌 업데이트 시, `nvm install-latest-npm`를 실행하여 처리한다.

```bash
nvm uninstall XX.XX.XX
source ~/{경로}/update.sh
```
