---
name: open-pr
description: |
  PR을 생성한다. pull_request_template.md 규격에 맞춰 본문을 작성하고 gh pr create를 실행한다.
  Trigger: "PR 날려줘", "PR 만들어줘", "PR 생성해줘", "PR 올려줘"
  Do NOT use for: 커밋·푸시(→ commit-push), 이슈·브랜치 생성(→ open-issue), 코드 리뷰
  Boundary: PR 생성까지만 수행한다. 머지, 리뷰 요청, 라벨 설정은 범위 밖이다.
allowed-tools: Bash(git *), Bash(gh *), Bash(terraform *), Read, Write
model: sonnet
effort: xhigh
---

# PR 생성

대상 브랜치: $ARGUMENTS (비어있으면 `main`)

이 저장소는 `dev` 없이 작업 브랜치가 `main`에서 분기해 `main`으로 병합된다
(`.claude/spec/git-convention.md`). 그래서 base 기본값은 `main`이다.

## Phase 1: 현재 브랜치 및 변경 사항 파악

1. `git branch --show-current`로 현재 브랜치명을 확인하라. `main`이면 PR을 열 수 없으니 중단하라.
2. 브랜치명에서 이슈 번호를 추출하라 (형식: `{type}/{이슈번호}-{slug}`)
   - 예: `feat/12-rds-backup` → 이슈 번호 `12`
   - 이슈 번호가 없으면 사용자에게 물어보라.
3. base 브랜치를 최신화하고(`git fetch origin {base}`), 이 브랜치의 커밋과 변경 파일을 확인하라:
   ```bash
   git log origin/{base}..HEAD --oneline
   git diff origin/{base}...HEAD --stat
   ```
   - 커밋이 하나도 없으면 PR을 열 게 없다. 알리고 중단하라.
4. 이미 열린 PR이 있는지 확인하라 (`gh pr view --json url,state 2>/dev/null`).
   있으면 URL을 알리고 중단하라 — push된 커밋은 기존 PR에 이미 반영된다.

> 다음 Phase 조건: 이슈 번호와 변경 사항이 파악되었을 때

> Skip 조건: 없음 (필수 Phase)

## Phase 2: PR 제목 및 본문 작성

1. `.github/pull_request_template.md`를 Read로 읽어 섹션 구조(`### 1. 연관 이슈`, `### 2. 구현 사항`,
   `### 3. Plan 결과 / 롤백`)와 구분선(`---`)을 그대로 따르라. 템플릿의 안내 문구(`❗️...`)는 지우고 실제 내용으로 채운다.
2. `.claude/spec/git-convention.md`를 Read로 읽어 PR 제목의 커밋 메시지 형식을 확인하라.
3. 본문은 템플릿 섹션에 맞춰 컴팩트하게 작성하라:
   - `1. 연관 이슈`: `- close #{이슈번호}`
   - `2. 구현 사항`: 이 브랜치의 변경을 추가/수정한 것 위주로 항목화하라.
     "무엇을 어떻게 추가/수정했는지"만 명확히 적고, 불필요한 서술은 늘리지 마라.
     - 항목 예: `- 추가: {무엇을 — 어디에}`, `- 수정: {무엇을 — 어떻게}`
     - 변경이 여러 갈래면 `**구현 사항 1**`, `**구현 사항 2**`로 분리
     - 특별한 로직·설계를 채택한 부분만 근거를 한두 줄 덧붙여라 (그 외 근거 서술은 생략)
     - 커밋 메시지를 그대로 복사하지 마라 — Phase 1의 diff를 이해한 뒤 요약하라
   - `3. Plan 결과 / 롤백`: 리소스 변경이 있는 PR이면 `terraform plan`(dns 스택은 `-chdir=dns`)을 돌려
     요약을 적어라 — `N to add, N to change, N to destroy`와 교체(replace)·삭제되는 리소스 목록.
     교체·삭제·권한 변경·예상 다운타임이 있으면 명시하고, 문제가 생겼을 때 되돌리는 방법을 한두 줄로 적어라.
     - 문서·스킬 등 리소스 변경이 없는 PR이면 이 섹션은 "리소스 변경 없음" 한 줄로 끝낸다.
     - plan 출력 전문을 붙이지 마라 — 리뷰어가 봐야 할 변경만 추려라.
4. PR 제목은 git-convention.md의 커밋 메시지 형식을 따른다: `{type}: {설명}(#{이슈번호})`
5. 완성한 본문을 스크래치 파일에 Write하라. `gh`에는 `--body-file`로 넘긴다 —
   한국어·백틱·따옴표가 섞인 본문을 `--body`에 인라인으로 넣으면 셸이 깨먹는다.

> 다음 Phase 조건: 제목과 본문 파일이 준비되었을 때

> Skip 조건: 없음 (필수 Phase)

## Phase 3: PR 생성

1. 대상 브랜치를 결정하라: $ARGUMENTS가 있으면 해당 브랜치, 없으면 `main`.
2. 현재 브랜치가 원격에 push되어 있는지, 로컬에 안 올라간 커밋이 없는지 확인하라:
   ```bash
   git rev-parse HEAD
   git rev-parse origin/{현재브랜치} 2>/dev/null
   ```
   - 원격 브랜치가 없거나 해시가 다르면 push되지 않은 커밋이 있는 것이다.
     사용자에게 알리고 중단하라 (commit-push 스킬로 먼저 올려야 한다).
3. 다음 명령으로 PR을 생성하라:
   ```bash
   gh pr create --title "{제목}" --body-file {본문파일} --base {대상 브랜치}
   ```
4. 생성된 PR URL을 제목·base와 함께 사용자에게 보고하라.

> Skip 조건: 없음 (필수 Phase)
