# Git 컨벤션

## 브랜치 전략

현재는 `dev` 브랜치 없이 작업 브랜치가 `main`에서 직접 분기하여 `main`으로 병합되는
단순한 흐름(`feature → main`)을 사용한다. 작업 브랜치는 `origin/main`을 base로 생성한다.
`hotfix`는 성격상 base가 다를 수 있으므로 작업 시작 전 사용자에게 base 브랜치를 확인한다.

## 커밋 타입 표

형식: `{type}: 커밋 내용(#{이슈번호})`

| 종류 | 설명 | Title 접두사 | 브랜치 접두사 | 이슈 라벨 |
|---|---|---|---|---|
| feat | 새로운 기능 추가 | `feat:` | `feat/` | `feat` |
| fix | 버그 수정 | `fix:` | `fix/` | `fix` |
| refactor | 동작 변경 없는 코드 개선 | `refactor:` | `refactor/` | `refactor` |
| hotfix | 운영 환경 긴급 수정 | `hotfix:` | `hotfix/` | `hotfix` |
| docs | 문서 추가·수정 | `docs:` | `docs/` | `docs` |
| test | 테스트 코드 추가·수정 | `test:` | `test/` | `test` |
| cicd | CI/CD 파이프라인·빌드 설정 | `cicd:` | `cicd/` | `cicd` |
| chore | 그 외 잡무(의존성, 설정 등) | `chore:` | `chore/` | `chore` |

## 브랜치 명명 규칙

`{종류}/{이슈번호}-{slug}` 형식을 사용한다. `slug`는 영문 kebab-case로 작성한 간단한 설명이다.

예: fix 이슈 #12 "ALB 헬스체크 경로 불일치" → `fix/12-alb-health-check`
