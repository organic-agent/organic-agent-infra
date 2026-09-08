# docs/

인프라 저장소의 문서. **성격**으로 폴더를 나눈다 — 무엇에 대한 문서인지가 아니라, 언제 꺼내 읽는지로.

| 폴더 | 기준 | 지금 있는 것 |
|---|---|---|
| `runbooks/` | **손으로 하는 절차.** 배포 순서, 수동 작업, 점검, 문제 해결, 롤백. 명령이 들어 있고 위에서 아래로 따라 한다 | `deploy-order.md`(제로 → 서비스까지 [1]~[8]) · `runbook.md`(운영 전반: 접속·CI/CD·AI 파이프라인·GPU AMI·모니터링·폐기) · `frontend-test.md`(테스트 프론트 배포·점검·롤백) |
| `architecture/` | **왜 이렇게 생겼는지.** 구성·경계·결정 근거. 절차가 아니라 설명. `study/`는 학습 메모 | `wes-infrastructure-architecture.{drawio,png}`(전체 그림, README가 보여 준다) · `admin-internal-access.md`(백오피스 Tailscale 내부 접근의 구성·보안 경계·배포 계약) · `study/wes-terraform-learning-guide.md` |
| `plans/` | **앞으로 할 일의 설계.** 결정 표, PR 순서, 다른 저장소에 요구하는 계약, 롤백. 끝나면 남겨 두고 검토 이력을 붙인다 | `pipeline-v2-infra-plan.md`(GPU score 워커 풀·AMI 파이프라인·Phase 0, 결정 A~L) |
| `improvements/` | **발견한 문제와 고친 근거.** 전/후 비교, 실측, 트레이드오프. 코드가 바뀐 뒤 "왜 이렇게 됐나"를 남긴다 | `score-lambda-to-gpu-worker-pool-2026-09-08.md`(score 단계 Lambda → GPU 워커 풀: 인프라 변경·성능·비용·트레이드오프) |
| `research/` | 인프라와 무관한 조사·검토. 저장소에 들어온 이력 때문에 남겨 둔다 | `mass-market-project-ideas-50-detailed-review.md` |

서버 저장소(`organic-agent-server/wes/docs`)의 `experiments/`(개발 전 테스트: 실측·평가)에 해당하는 문서는 아직 없다 — 생기면 같은 이름으로 만든다. Phase별 실측(`pipeline-v2-phase{0,3,5}.md`)은 계획 문서가 요구하는 산출물이라 `plans/` 옆이 아니라 `experiments/`에 둔다.

## 시작점

- 처음 세우거나 destroy 뒤 다시 세운다 → [`runbooks/deploy-order.md`](runbooks/deploy-order.md)
- 뭔가 안 된다 → [`runbooks/runbook.md`](runbooks/runbook.md)의 각 절 끝 "문제 해결" 표
- 왜 이런 구조인지 → 루트 [`README.md`](../README.md) 아키텍처 절 → `architecture/`
- Lambda에서 GPU로 왜·어떻게 바꿨고 무엇을 감수했나 → [`improvements/score-lambda-to-gpu-worker-pool-2026-09-08.md`](improvements/score-lambda-to-gpu-worker-pool-2026-09-08.md)
- 파이프라인 v2 진행 상황 → [`plans/pipeline-v2-infra-plan.md`](plans/pipeline-v2-infra-plan.md) §3 PR 순서·§10 검토 이력

## 이전 경로 대조표 (2026-09-08, #61)

코드 주석·README·테스트·워크플로의 경로는 함께 옮겼다. 외부(다른 저장소·위키)에서 옛 경로로 링크했다면 아래로 바꾼다.

| 이전 | 지금 |
|---|---|
| `docs/runbook.md` | `docs/runbooks/runbook.md` |
| `docs/deploy-order.md` | `docs/runbooks/deploy-order.md` |
| `docs/frontend-test.md` | `docs/runbooks/frontend-test.md` |
| `docs/admin-internal-access.md` | `docs/architecture/admin-internal-access.md` |
| `docs/wes-infrastructure-architecture.drawio` · `.png` | `docs/architecture/wes-infrastructure-architecture.drawio` · `.png` |
| `wes-terraform-learning-guide.md` (저장소 루트) | `docs/architecture/study/wes-terraform-learning-guide.md` |
| `docs/pipeline-v2-infra-plan.md` | `docs/plans/pipeline-v2-infra-plan.md` |
| `docs/mass-market-project-ideas-50-detailed-review.md` | `docs/research/mass-market-project-ideas-50-detailed-review.md` |

## 규칙

- 새 문서는 위 표의 기준으로 폴더를 고른다. 절차와 설명이 섞이면 절차는 `runbooks/`, 근거는 `architecture/`로 나누고 서로 링크한다.
- 파일을 옮기면 `rg -n 'docs/<옛이름>'`으로 코드 주석·테스트·워크플로까지 같이 고치고, 이 대조표에 한 줄 더한다.
- 링크는 상대 경로. 같은 폴더면 파일명만, 다른 폴더면 `../<폴더>/<파일>`.
