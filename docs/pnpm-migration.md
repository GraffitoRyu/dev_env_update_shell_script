# 다른 Mac에 동일한 pnpm 정책 적용하기

전역 기본은 Homebrew의 승인 메이저, 프로젝트에서는 그 프로젝트가 선언한 버전을 사용한다. 현재 전역 정책은 `pnpm-policy.zsh`의 `PNPM_MAJOR=11`, Node.js 정책은 `update.sh`의 `NODE_LTS_VERSION=24`다. 다음 메이저는 협의 후 사람이 값을 수정한다.

## 재분석 결과와 개선 방향

이전 도구는 `.zshrc` 함수로 pnpm 11을 호출했다. nvm이 PATH를 바꾸면 `command pnpm`이나 함수를 읽지 않는 독립 프로세스가 기존 pnpm 12를 실행할 수 있었다. 함수가 PATH를 보정한 자식 프로세스 테스트만으로는 Codex·일반 스크립트까지 검증할 수 없었다.

이를 해결하기 위해 Homebrew의 일반 실행 링크를 승인 formula에 연결한다. 자체 wrapper·alias·새 초기화 파일은 추가하지 않는다. 기존 도구의 변경되지 않은 관리 블록만 백업 후 제거한다. nvm의 각 Node 설치나 별도 PNPM_HOME 등에 남아 있는 pnpm은 먼저 소유자를 확인해 정리한다. 프로젝트 버전 해석기는 새로 만들지 않고 pnpm 자체 기능을 사용한다.

| 순서 | 우선순위 | 작업·산출물 | 의존 | 실행 방식 | 완료 근거 |
| --- | --- | --- | --- | --- | --- |
| 1 | P0 | 정책·실행 경로·기존 설치 조사 | 없음 | Mac별 `parallel_execution` 가능 | 저장소 revision, 설치·경로 목록 |
| 2 | P0 | 중복 설치 소유권·변경·복구 계획 | 1 | Mac별 독립 검토 | 승인 대상 파일·패키지 명시 |
| 3 | P0 | 충돌 정리 후 Homebrew 링크 전환 | 2와 해당 Mac 승인 | 같은 Mac에서는 직렬 | 일반 링크·PATH 모두 승인 설치본 |
| 4 | P0 | 새 셸·nvm·독립 프로세스·Codex 검증 | 3 | Mac별 `parallel_execution` 가능 | 아래 검증표의 실제 출력 |
| 5 | P1 | 프로젝트 버전 선택 검증 | 4 | 서로 다른 프로젝트는 독립 | 프로젝트 선언과 실행 버전 일치 |
| 6 | P0 | 업데이트·반복 적용·Mac 간 결과 비교 | 4·5 | 같은 Mac에서는 직렬 | 전체 성공 및 미검증 항목 없음 |

진단과 저장소 테스트는 실제 설치를 대신하지 않는다. 전환·Homebrew 업그레이드·npm 정리 작업을 같은 Mac에서 동시에 실행하지 않는다. 전환의 `--apply`와 자동 업데이트는 기존 `logs/.update.flock` 잠금을 공유하며, 다른 실행이 잠금을 잡고 있으면 exit code 75로 중단한다. 수동 업데이트와 직접 실행하는 Homebrew/npm 명령은 담당자가 직렬로 진행한다. 잠금 파일이 남아 있다는 이유만으로 실행 중이라고 판단하거나 삭제하지 않는다.

## ‘동일 환경’의 범위

- 전역: 모든 Mac에서 **같은 승인 메이저**의 Homebrew 최신 버전을 사용한다. `brew pin`으로 패치 업데이트까지 막는 정책은 아니다.
- 프로젝트: 동일한 프로젝트 revision의 버전 선언과 lockfile을 사용하고 실제 선택 버전을 비교한다.
- 실행 경로: Homebrew prefix 자체는 Apple Silicon과 Intel에서 다를 수 있지만, 선택되는 설치 주체와 formula는 같아야 한다.
- 비교 시 Node·npm·전역 pnpm의 실제 버전도 기록한다. 실행 시점이나 Homebrew 배포 차이로 패치가 다르면 ‘정확히 동일’이라고 보고하지 않는다. 같은 시점에 다시 갱신하고 차이를 확인한다.
- 모든 Mac의 전역 패치까지 항상 동일하게 고정하려면 별도의 정확 버전 배포 정책이 필요하다. 현재의 ‘승인 계열 내 최신’ 정책만으로 이를 보장하지 않는다.

`pnpm@11`은 keg-only formula다. `brew link --force`는 keg-only 연결을 허용하며, 기존 파일을 삭제하는 `--overwrite`와 다르다. 도구는 `--overwrite`를 사용하지 않는다. [Homebrew link 문서](https://docs.brew.sh/Manpage#link-ln-options-installed_formula-installed_cask-)

macOS·CPU에 따라 bottle 지원이 다르고, 소스 빌드에는 Node를 포함한 추가 빌드 의존성이 필요할 수 있다. 담당 에이전트는 대상 Mac의 설치 계획을 확인한다. 이 도구는 macOS·Homebrew·Homebrew nvm 설치 자체를 제공하는 bootstrap은 아니다. [pnpm@11 formula](https://formulae.brew.sh/formula/pnpm@11)

## 1. 변경 없이 진단

각 Mac에 같은 저장소 revision을 준비한다. 기존 변경을 확인하고 강제 reset이나 설정 덮어쓰기로 맞추지 않는다. 아래 경로는 해당 Mac의 실제 경로로 바꾼다.

```zsh
UPDATE_DIR="$HOME/projects/mac-env/shell-update"
git -C "$UPDATE_DIR" status --short
git -C "$UPDATE_DIR" rev-parse HEAD
zsh "$UPDATE_DIR/migrate-pnpm.zsh"
```

기본 진단은 기존 pnpm을 실행하거나 사용자 초기화 파일을 source하지 않는다. 현재 PATH와 nvm 설치별 pnpm·pnpx, Homebrew 목록, 셸 설정 대상과 기존 관리 블록을 조사한다. pnpm 자동 다운로드·사용자 셸 Hook 실행을 진단으로 유발하지 않는다. 종료 코드 0은 조사 완료이며 전환 완료가 아니다.

다음 표를 Mac별로 채운다. 동적 alias·function과 GUI 앱이 가진 PATH는 자식 진단 프로세스만으로 확정할 수 없으므로 실제 해당 실행 환경에서 확인한다.

| 항목 | 기록할 값 |
| --- | --- |
| Mac·CPU·macOS | 담당 환경 식별자, `uname -m`, `sw_vers -productVersion` |
| 저장소 | 경로·HEAD·WIP 여부 |
| Homebrew | `command -v brew`, `brew --prefix`, 설치·pin 목록 |
| Node | nvm 설치 목록, 활성 Node·npm 경로 |
| pnpm·pnpx | 모든 PATH 후보와 실제 symlink 목적지, nvm 각 버전의 후보 |
| 셸 | `ZDOTDIR`, 실제 `.zshrc` 대상, 동명 alias·function, 기존 관리 블록 |
| 전환 계획 | unlink할 formula, 정리할 중복 파일, 백업·복구 경로 |

첫 Mac에 Node.js 24가 없다면 승인 후 기존 `update.sh --auto`로 준비한다. pnpm 단계에서 미설치 또는 연결 미완료로 실패할 수 있으며 이는 전체 성공이 아니다. nvm이 초기화된 셸에서 `nvm use 24` 후 아래 전환을 진행한다. nvm 초기화 실패는 먼저 해결한다.

## 2. 충돌의 소유권 확인과 정리

각 Mac 담당 에이전트가 **실제 패키지·링크·셸 설정 변경 범위**와 복구 계획을 제시하고, 그 Mac에 이미 받은 승인이 있는지 확인한다. 저장소 코드 변경이나 다른 Mac의 적용 승인을 새 Mac의 변경 승인으로 확대하지 않는다.

| 발견 상태 | 처리 |
| --- | --- |
| 선택한 Homebrew prefix의 pnpm formula 링크 | 전환 도구가 이전 formula를 unlink하고 승인 formula를 연결. 이전 설치본은 삭제하지 않음 |
| nvm 설치 안의 npm 글로벌 pnpm | 아래처럼 해당 Node prefix의 소유권 확인·백업 후 그 pnpm만 제거 |
| Corepack 소유 pnpm·pnpx shim | 소유권 확인·백업 후 해당 bin의 pnpm shim만 disable |
| 이전 formula의 `opt/.../bin`·별도 PNPM_HOME 직접 경로 | 설정 출처를 찾고 승인 후 오래된 경로를 정리. 일반 Homebrew 링크만 바꿔서는 해결되지 않음 |
| 알 수 없는 파일·외부 링크·사용자 alias/function | 자동 삭제하지 않고 정의·소유자·의도를 확인하여 개별 처리 |
| 수정되거나 중복된 자체 관리 블록 | 원문을 보존하고 사용자가 추가한 변경을 확인한 뒤 개별 정리 |

설치된 모든 nvm Node 버전을 조사한다. 현재 Node의 pnpm만 정리하면 나중에 `nvm use`로 이전 버전으로 돌아갈 때 다시 충돌할 수 있다. 다른 Node·npm·Yarn·Corepack 본체·프로젝트 의존성과 store는 제거하지 않는다.

### npm이 소유한 pnpm의 구체적인 정리 예시

아래 `NODE_PREFIX`는 진단에서 확인한 **한 개의 실제 설치 경로**로 바꾼다. 다른 prefix에 일괄 적용하지 않는다.

```zsh
NODE_PREFIX="$HOME/.nvm/versions/node/v24.21.0"
ls -l "$NODE_PREFIX/bin/pnpm" "$NODE_PREFIX/bin/pnpx"
"$NODE_PREFIX/bin/node" -p 'JSON.stringify(require(process.argv[1]).bin)' \
  "$NODE_PREFIX/lib/node_modules/pnpm/package.json"
```

manifest에 선언된 **모든 bin**의 symlink가 그 대상과 실제로 일치하는지 확인한다. 버전에 따라 `pnpm`·`pnpx` 외에 `pn`·`pnx`도 있다. 일반 파일이거나 Corepack 등 다른 소유자의 대상이면 아래 npm 제거 절차를 사용하지 않는다. npm 제거는 패키지의 bin 전체에 영향을 주므로, 확인된 전체 목록을 백업하고 승인된 제거만 수행한다.

```zsh
# 실제 manifest와 소유권 확인 결과로 전체 목록을 지정한다.
PNPM_BIN_NAMES=(pnpm pnpx)
PNPM_BIN_PATHS=()
for name in "${PNPM_BIN_NAMES[@]}"; do
  PNPM_BIN_PATHS+=("bin/$name")
done
if BACKUP_DIR="$(mktemp -d "$HOME/pnpm-migration-backup.XXXXXX")" &&
   tar -czf "$BACKUP_DIR/npm-pnpm.tgz" -C "$NODE_PREFIX" \
     lib/node_modules/pnpm "${PNPM_BIN_PATHS[@]}"; then
  PATH="$NODE_PREFIX/bin:$PATH" "$NODE_PREFIX/bin/node" \
    "$NODE_PREFIX/lib/node_modules/npm/bin/npm-cli.js" \
    uninstall --global --prefix "$NODE_PREFIX" --ignore-scripts pnpm
else
  print -u2 '백업 실패: pnpm을 제거하지 않았습니다.'
fi
```

manifest가 없거나 npm 자체가 고장났다면 파일을 추측해서 지우지 않는다. 백업 압축 내용은 `tar -tzf`로 확인한다. 복구가 필요하면 변경 후 새 파일과 충돌하지 않는지 검토하고 승인 후 같은 prefix에 복원한다. Node 버전 자체가 이미 제거된 경우 다른 prefix로 임의 복원하지 않는다.

### Corepack이 소유한 shim의 구체적인 정리 예시

같은 `NODE_PREFIX`의 `lib/node_modules/corepack/package.json` bin 정보와 pnpm·pnpx symlink 목적지를 비교한다. `corepack disable`은 이름만 보고 링크를 제거할 수 있으므로 **이 소유권 확인을 생략하지 않는다.** pnpm만 npm 소유이고 pnpx는 Corepack 소유인 혼합 상태는 개별 검토한다.

소유권·백업·승인 확인 후 해당 설치의 Corepack만 실행한다.

```zsh
if BACKUP_DIR="$(mktemp -d "$HOME/pnpm-migration-backup.XXXXXX")" &&
   tar -czf "$BACKUP_DIR/corepack-pnpm-links.tgz" -C "$NODE_PREFIX" bin/pnpm bin/pnpx; then
  "$NODE_PREFIX/bin/node" "$NODE_PREFIX/lib/node_modules/corepack/dist/corepack.js" \
    disable pnpm --install-directory "$NODE_PREFIX/bin"
else
  print -u2 '백업 실패: Corepack shim을 변경하지 않았습니다.'
fi
```

Corepack entry 경로는 해당 설치의 manifest에 따라 확인한다. 없는 파일이면 명령을 실행하지 말고 실제 entry를 사용한다. 복구가 필요하면 대상 bin의 현 상태를 비교하고 백업 링크를 되돌린다. Yarn·npm shim까지 일괄 disable하지 않는다.

## 3. Homebrew 연결 적용

중복 정리 후 기본 진단을 다시 실행하고, 승인된 적용을 진행한다.

```zsh
zsh "$UPDATE_DIR/migrate-pnpm.zsh"
zsh "$UPDATE_DIR/migrate-pnpm.zsh" --apply
```

도구는 미설치 formula를 `brew install --skip-link`로 확보하여 검증 전 자동 연결을 막고, 실제 경로·프로젝트 밖 메이저를 검증한 뒤 일반 Homebrew 링크를 전환한다. 기존 자체 셸 함수 블록이 있다면 원본을 백업하고 그 블록만 제거한다. `.zshrc`가 symlink이면 실제 대상만 편집하며 링크를 보존한다. 새 설정 파일이나 함수는 만들지 않는다.

적용 완료 메시지는 아래 전체 검증을 대신하지 않는다. 이미 열려 있는 셸에는 이전 함수·alias·명령 캐시가 남을 수 있으므로 새 셸을 열고, Codex에서도 새 명령 프로세스로 확인한다. 앱의 상속 PATH에 오래된 직접 경로가 남아 있으면 해당 설정을 정리한 뒤 앱을 다시 열어 확인한다. 앱 재시작만으로 모든 PATH 문제가 해결된다고 가정하지 않는다.

## 4. 새 셸·Codex·업데이트 검증

새 사용자 zsh에서 프로젝트 밖으로 이동해 확인한다. 첫 번째 명령으로 동명 함수·alias가 남아 있는지도 확인한다.

```zsh
cd /
whence -va pnpm pnpx
pnpm --version
command pnpm --version
/bin/zsh -fc 'command -v pnpm; command pnpm --version'
/usr/bin/env pnpm --version
nvm use 24
whence -va pnpm pnpx
command pnpm --version
/bin/zsh -fc 'command pnpm --version'
```

추가로 실제 사용하는 다른 nvm Node 버전에도 전환하여 같은 검증을 반복한다. 최종 활성 Node는 승인된 24로 되돌린다. Node 호환 조건을 충족하지 않는 과거 프로젝트는 별도 요구를 기록하며, 실행 실패를 전역 전환 성공으로 감추지 않는다.

**Codex에서는 담당 에이전트가 도구로 실제 실행하는 환경에서** 작업 디렉터리를 프로젝트 밖으로 지정하고 `command -v pnpm`, `pnpm --version`, `command pnpm --version`을 실행해 사용자 셸 결과와 비교한다. 터미널 출력이나 함수가 만든 자식 프로세스 결과로 Codex 검증을 대체하지 않는다.

그다음 같은 Mac에서 순서대로 실행한다.

```zsh
zsh "$UPDATE_DIR/update.sh" --auto
zsh "$UPDATE_DIR/migrate-pnpm.zsh" --apply
```

업데이트 6단계가 모두 성공해야 한다. 반복 적용에서는 불필요한 링크 변경·추가 백업이 없어야 한다. `update.sh`는 업데이트 후 일반 PATH의 pnpm·pnpx까지 확인하므로 충돌이 재발하면 실패로 표시한다. 직접 다른 formula를 `brew link`하거나 외부 도구가 pnpm을 다시 설치하는 행동까지 영구 차단하는 잠금은 아니다.

## 5. 프로젝트 버전 선택 검증

프로젝트의 기존 정책을 먼저 읽는다. 예를 들어 `package.json`에 `"packageManager": "pnpm@11.26.0"`이 있으면 해당 정확 버전을 선택한다. pnpm 11에서는 `devEngines.packageManager`로 범위도 선언할 수 있고 두 선언이 함께 있으면 `devEngines.packageManager`가 우선한다. `engines.pnpm`은 호환성 검사이며 이 필드만으로 자동 다운로드·전환을 보장하지 않는다.

pnpm의 `pmOnFail` 기본 동작은 `download`다. 설정이 `ignore`, `warn`, `error`로 바뀌었거나 Corepack이 실행을 중개하면 실제 동작도 달라질 수 있다. 담당 에이전트는 프로젝트·전역 설정과 환경변수를 확인하고 기존 정책을 임의로 변경하지 않는다. [pnpm 버전 선택](https://pnpm.io/settings/cli#pmonfail), [프로젝트 버전 선언](https://pnpm.io/package_json#devenginespackagemanager)

대상 프로젝트 안과 하위 디렉터리에서 일반 `pnpm --version`, `command pnpm --version`, 독립 zsh의 `command pnpm --version`을 비교한다. 첫 실행은 지정 버전 다운로드나 lockfile 기록을 수반할 수 있으므로 필요한 다운로드·프로젝트 변경 승인을 먼저 확인한다. 실제 프로젝트 원문 보존이 필요하면 해당 선언과 필요한 lockfile을 임시 검증 디렉터리에 복사하여 실행하고, 원본 프로젝트의 검증 여부와 구분한다.

| 검증 위치 | 기대 결과 |
| --- | --- |
| 프로젝트 밖·버전 미지정 위치 | 전역 승인 메이저 |
| 정확 버전 선언 프로젝트 및 하위 디렉터리 | 선언한 정확 버전 |
| 범위 선언 프로젝트 | 범위와 기존 lockfile 해석에 맞는 버전, 다른 Mac 결과와 비교 |
| 다른 프로젝트로 이동 후 다시 프로젝트 밖 | 전역 기본 유지; 다른 프로젝트에 버전 변경 전파 없음 |

Codex는 프로젝트 지침·버전 선언을 읽고 **실제 작업 디렉터리에서 선택된 버전**으로 설치·테스트한다. 불일치 시 PATH와 설정을 해결하며, 맞추기 위해 프로젝트 선언·lockfile을 자동으로 고치거나 `--pm-on-fail=ignore`로 우회하지 않는다. Homebrew가 전역 실행 진입점을 관리하고, pnpm이 프로젝트 버전 캐시를 관리하는 것은 중복 전역 설치와 다르다.

## 6. 실패·복구와 Mac 간 완료 보고

- 목표 설치·버전 확인 실패: 기존 링크·셸 설정을 바꾸지 않는다. 새로 설치된 formula나 다운로드는 남을 수 있으며 패키지 설치 전체를 rollback하지 않는다.
- 링크 전환·후속 검증·셸 편집 실패: 도구의 복구 결과를 확인한다. 이전 formula 링크 복구까지 실패하면 **부분 적용**으로 취급하고 실제 pnpm·pnpx 링크를 확인한다.
- 셸 백업은 실제 설정 파일 옆의 `<설정파일>.shell-update-pnpm.XXXXXX`에 남긴다. 적용 뒤 추가한 사용자 변경이 있으면 백업 전체로 덮어쓰지 않고 해당 블록 변경만 복원한다.
- 이전 Homebrew 연결로 수동 복구할 때는 현재 링크와 도구가 기록한 이전 formula를 확인하고, 승인 후 목표 formula unlink → 이전 formula link 순으로 수행한다. `--overwrite`나 무조건 `rm`으로 충돌을 제거하지 않는다.
- nvm 중복 정리를 복구하면 다시 shadow가 생길 수 있다. 복구 완료와 전환 완료를 구분하고 전체 검증표를 다시 확인한다.
- 장기간 보관할 필요가 없는 테스트 임시 디렉터리는 테스트가 정리한다. 실제 설정·패키지 백업은 자동 삭제하지 않고 검증·안정화 후 사용자가 정리한다.

모든 Mac 담당자가 아래 같은 표를 제출하고 운영 담당자가 취합한다. 하나라도 누락·실패·미검증이면 전체 전환 완료로 표시하지 않는다.

| 항목 | Mac A | Mac B |
| --- | --- | --- |
| 저장소 HEAD·CPU·macOS | | |
| Homebrew prefix·승인 formula | | |
| Node·npm·프로젝트 밖 pnpm 버전 | | |
| 일반 pnpm·command pnpm·pnpx 실제 경로 | | |
| nvm 전환 후·독립 프로세스 결과 | | |
| 실제 Codex 실행 결과 | | |
| 프로젝트 revision·버전 선언·실제 선택 버전 | | |
| update.sh 6단계·반복 적용 결과 | | |
| 백업·로그·남은 충돌/미검증 항목 | | |

## 다른 Mac 담당 에이전트에게 전달할 요청

> 이 저장소의 `docs/pnpm-migration.md`를 읽고 같은 revision을 기준으로 현재 Mac을 먼저 진단해 주세요. 전역은 승인 메이저 11, 프로젝트는 그 프로젝트의 버전 선언을 사용합니다. 현재 PATH와 설치된 모든 nvm Node의 pnpm·pnpx 소유권, 셸 정의, Homebrew 링크를 조사하고 변경·백업·복구 범위를 제시하세요. 해당 Mac에 대한 실제 변경 승인을 확인한 뒤 중복 설치만 정리하고 `migrate-pnpm.zsh --apply`를 수행하세요. 새 셸·nvm 전환·command pnpm·독립 프로세스·실제 Codex 실행·프로젝트 선택·업데이트 6단계·반복 적용을 검증하고 문서의 Mac 비교표를 제출하세요. 미검증 경로가 있으면 완료로 보고하지 마세요. 프로젝트 정책·lockfile·store와 다른 패키지를 임의로 변경하지 마세요.
