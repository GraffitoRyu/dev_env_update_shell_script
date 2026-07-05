# AGENTS.md

<!-- codex-local-git-approval-policy:start -->
## Local Git Approval Policy

이 섹션은 이 repo의 로컬 git 계정이 다음 중 하나일 때만 적용한다.

- `git config user.email` 값이 `yth4135@naver.com`
- `git config user.name` 값이 `GraffitoRyu`

조건이 충족되지 않으면 commit과 push는 각각 별도 사용자 승인이 필요하다.

- `commit`과 `push`: 요청받은 작업 범위 안에서는 commit-push 상시 승인으로 본다.

이 정책은 tag, PR, release, deploy, hook/config/runtime 변경, dependency/lockfile 변경, destructive git operation을 승인하지 않는다. 해당 작업은 항상 별도 사용자 승인이 필요하다.
<!-- codex-local-git-approval-policy:end -->
