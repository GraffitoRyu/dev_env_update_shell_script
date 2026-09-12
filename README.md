# macOS 개발환경 업데이트 스크립트

Homebrew, Node.js LTS와 npm 글로벌 개발 도구를 한 번에 점검·업데이트하는 zsh 스크립트다.

## 관리 대상

- Homebrew와 설치된 formula/cask
- Homebrew로 설치한 nvm
- Node.js 24 LTS
- npm, pnpm, vite, http-server, npm-check-updates

## 실행 조건

- macOS
- zsh
- Homebrew
- Homebrew로 설치한 nvm
- 쓰기 가능한 `$HOME/.nvm`

수동 실행에서는 `brew upgrade` 중 macOS 관리자 비밀번호가 필요할 수 있다.

```zsh
zsh /absolute/path/to/shell-update/update.sh
```

자동 실행이나 비대화형 실행에서는 비밀번호 프롬프트를 피하기 위해 `brew upgrade`만 건너뛴다. 나머지 단계는 실행한다.

```zsh
zsh /absolute/path/to/shell-update/update.sh --auto
```

## 처리 순서

1. Homebrew 저장소 갱신
2. Homebrew 패키지 업그레이드(수동 대화형 실행만)
3. Node.js 24 LTS 설치·활성화 및 nvm 기본 버전 설정
4. 활성 Node.js의 npm 실행 상태 확인
5. vite, pnpm, http-server, npm-check-updates 글로벌 업데이트

Node.js가 현재 셸에서 비활성이거나 nvm 기본 alias가 깨진 경우에도 최신 LTS를 설치·활성화한 뒤 기본 버전을 복구한다. 다른 경로의 Node.js가 같은 버전이어도 nvm 관리 경로로 활성화하고, node와 npm이 해당 설치에 속하는지 확인한다. 기존 Node.js 설치를 삭제하거나 글로벌 패키지를 이관하지 않는다. NVM은 스크립트의 엄격한 zsh 오류 옵션과 분리해서 실행한다.

## 매일 한 번 자동 실행

아래 예시는 첫 프롬프트에서 백그라운드로 실행하고, 전체 루틴이 성공한 경우에만 `.date-cache`를 생성한다.

```zsh
UPDATE_DIR="$HOME/projects/mac-env/shell-update"
UPDATE_FLAG="$UPDATE_DIR/.date-cache"
LAST_UPDATE="$UPDATE_DIR/.latest-date"

_run_daily_update_once() {
  add-zsh-hook -d precmd _run_daily_update_once

  if [[ $(date +%F) != $(cat "$LAST_UPDATE" 2>/dev/null) ]]; then
    rm -f "$UPDATE_FLAG"
    date +%F > "$LAST_UPDATE"
  fi

  if [[ -f "$UPDATE_FLAG" ]]; then
    return 0
  fi

  (
    SHELL_UPDATE_AUTO=1 zsh "$UPDATE_DIR/update.sh" --auto
    update_exit_code=$?

    if [[ $update_exit_code -eq 0 ]]; then
      touch "$UPDATE_FLAG"
    elif [[ $update_exit_code -eq 75 ]]; then
      : # 다른 자동 실행이 진행 중이므로 성공 표시는 해당 실행에 맡긴다.
    else
      print -u2 "[업데이트 루틴 실패] $UPDATE_DIR/logs 의 최신 로그를 확인하세요."
    fi
  ) &!
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _run_daily_update_once
```

## 로그와 자동 실행 중복 방지

- 로그: `logs/update-YYYY-MM-DD_HH-MM-SS.log`
- 자동 실행 락: `logs/.update.flock`에 대한 zsh 내장 파일 잠금
- 자동 실행 중인 프로세스가 있으면 새 자동 실행은 exit code `75`로 종료한다.
- 수동 실행은 자동 실행 락의 제한을 받지 않는다.
- 잠금 파일은 실행 후에도 남는다. 파일 존재 자체는 실행 중이라는 뜻이 아니며, 프로세스 종료 시 운영체제가 잠금을 해제한다. 실행 중 파일을 삭제하면 중복 실행 방지가 깨질 수 있다.
- 이전 버전의 `logs/.update.lock/pid`가 살아 있는 프로세스를 가리키면 자동 실행을 건너뛴다. 이전 버전의 잠금 디렉터리는 삭제하지 않는다.
- `INT`, `TERM`, `HUP`을 받으면 실행 중인 명령이 끝난 뒤 후속 단계를 중단하고 실패 코드를 반환한다. 그때까지 잠금을 유지하며, 패키지 명령을 강제 종료하거나 완료된 업데이트를 되돌리지는 않는다.

```zsh
ls -la "$UPDATE_DIR/logs"
```

## npm 상태 오류

Node.js 활성화 후에도 npm을 실행할 수 없으면 글로벌 패키지를 설치하지 않고 중단한다. 로그에 출력된 현재 Node.js 버전을 사용해 nvm 설치를 수동 복구한 뒤 다시 실행한다.

```zsh
nvm deactivate
nvm uninstall v24.x.x
nvm cache clear
nvm install v24.x.x
nvm use v24.x.x
nvm alias default v24.x.x
```

## Homebrew cask 감사 도구

`check-available-migration-cask.sh`는 `/Applications`의 앱과 Homebrew cask 관리 상태를 비교하는 별도 감사 스크립트다. 업데이트 루틴에서는 자동 실행하지 않는다.

존재하는 `/Applications`와 `~/Applications`를 검색한다. 결과는 실행 디렉터리의 `brew-app-audit/`에 저장하며, 앱 수집·설치 목록 및 정보 조회·후보 검색에 실패하면 이전 보고서를 보존하고 실패 상태를 반환한다. CSV 열은 `app_name,normalized_name,is_brew_managed,cask_candidates`이다.

## 검증

아래 테스트는 임시 디렉터리의 모의 명령을 사용하며 실제 Homebrew·Node.js·npm 설치를 변경하지 않는다.

```zsh
zsh tests/manual-run-lock.zsh
zsh tests/update-lifecycle.zsh
zsh tests/node-npm-paths.zsh
python3 tests/cask-audit.py
```

종료·동시 실행, 관리 경로·실패 전파, 감사 실패 시 보고서 보존과 CSV 문자열 보존을 확인한다. 실제 업데이트 실행과는 별도의 검증이다.
