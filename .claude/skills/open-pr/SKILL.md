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

1. `.github/pull_request_template.md`를 Read로 읽어 섹션 구조(`## 1. 연관 이슈`, `## 2. 구현 사항`,
   `## 3. Plan 결과 / 롤백`)를 그대로 따르라. 템플릿의 안내 문구(`❗️...`)와 빈 표는 지우고 실제 내용으로 채운다.
2. `.claude/spec/issue-pr-writing.md`를 Read로 읽어 본문을 채우는 규칙을 확인하라 — 맨 위 한 줄 요약,
   왜 / 무엇을 바꿨나 / 어떻게 확인했나, 한 줄에 한 사실, 전→후 표, 약어 풀이, 제목 세 층(섹션 `##` → 칸 `###` → 본문).
3. `.claude/spec/git-convention.md`를 Read로 읽어 PR 제목의 커밋 메시지 형식을 확인하라.
4. 본문을 섹션에 맞춰 작성하라:
   - 맨 위: `> ` 인용 한 줄 요약. 놓치면 사고가 나는 것(머지 순서·apply 뒤 수동 작업·다운타임)이 있을 때만
     `> [!WARNING]` 하나를 그 아래에 둔다.
   - `1. 연관 이슈`: `- close #{이슈번호}`
   - `2. 구현 사항`: 아래 세 칸을 이 순서로 쓴다.
     - `### 왜`: 문제 1~3줄
     - `### 무엇을 바꿨나`: 리소스·값·경로 변경은 `전 | 후` 표(행 7개 이하). 표에 안 담기는 것은 묶음 3~5개,
       묶음마다 굵은 제목 한 줄 + 항목 3개 이하. 특별한 설계를 택한 곳만 근거를 한 줄 덧붙여라.
     - `### 어떻게 확인했나`: 돌린 검사(`fmt`·`validate`·정적 테스트 개수)와 직접 확인한 것. 하지 않은 확인은 쓰지 마라.
     - 커밋 메시지나 파일 목록을 그대로 옮기지 마라 — Phase 1의 diff를 이해한 뒤 요약하라.
   - `3. Plan 결과 / 롤백`: 리소스 변경이 있는 PR이면 `terraform plan`(dns 스택은 `-chdir=dns`)을 돌려 아래 세 칸을 쓴다.
     - `### Plan 요약`: `N to add, N to change, N to destroy`와 교체(replace) 개수
     - `### 주의할 변경`: 교체·삭제되는 리소스, 권한 변경, 예상 다운타임, apply 뒤 사람이 해야 하는 일.
       apply 전이라 확인하지 못한 것은 "apply 뒤에 확인 필요"로 적어라. 없으면 "없음".
     - `### 롤백`: 되돌리는 방법 한두 줄과 revert로 돌아오지 않는 것
     - 문서·스킬 등 리소스 변경이 없는 PR이면 이 섹션은 "리소스 변경 없음" 한 줄로 끝낸다.
     - plan 출력 전문을 붙이지 마라 — 리뷰어가 봐야 할 변경만 추려라.
   - 본문이 화면 한 장(약 40줄)을 넘으면 세부 목록은 `<details>`로 접어라. 요약·경고·Plan 요약·롤백은 접지 않는다.
5. PR 제목은 git-convention.md의 커밋 메시지 형식을 따른다: `{type}: {설명}(#{이슈번호})`.
   설명은 결과를 말하는 한국어 한 구절이다.
6. `issue-pr-writing.md`의 "만들기 전 자가 점검"을 하나씩 확인하고 걸리면 고쳐라.
7. 완성한 본문을 스크래치 파일에 Write하라. `gh`에는 `--body-file`로 넘긴다 —
   한국어·백틱·따옴표가 섞인 본문을 `--body`에 인라인으로 넣으면 셸이 깨먹는다.
8. 제목·base·본문 전문을 사용자에게 보여 주고 "이대로 PR을 열까요?"로 확인받아라. 승인 전에는 만들지 마라.

> 다음 Phase 조건: 제목과 본문 파일이 준비되고 사용자가 승인했을 때

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
