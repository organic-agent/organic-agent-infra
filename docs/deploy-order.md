# WES 배포 순서

제로 상태(앱 스택 destroy)에서 서비스가 뜰 때까지의 전체 순서.
각 단계의 상세 절차는 [runbook.md](runbook.md) 해당 섹션 참고.

```
[1] dns 스택 (최초 1회)          — Route53 존 + NS 위임
[2] SSM 수동 파라미터 등록        — DB 비밀번호, OAuth, cors 등
[3] ECR만 먼저 apply → 이미지 푸시 — Lambda 셋 컨테이너 (Lambda보다 먼저 있어야 한다)
[4] 앱 스택 terraform apply      — VPC/ALB/EC2/RDS + S3 + Lambda 셋 + VPC 엔드포인트 + 배포 롤 + 모니터링 EC2
[5] GitHub OIDC 롤 시크릿         — API·관리자 API·BackOffice·AI Lambda 롤 ARN 등록
[6] 서버 저장소 main 머지         — CD가 빌드→GHCR→SSM 배포 (Flyway가 스키마 생성)
[7] Lambda용 DB 사용자 생성        — 테이블이 생긴 뒤 1회 (embedder · photoselect)
[8] 검증                         — 헬스체크·타깃 그룹·OAuth·업로드
```

1-2는 한 번 해두면 destroy 후 재배포 때 건너뛴다. 3-5는 스택을 다시 세울 때마다,
6과 8은 배포할 때마다 반복된다. 7은 DB를 새로 만들 때만 다시 한다.

---

## # [1] dns 스택 (최초 1회)

존은 앱 스택과 분리되어 destroy 후에도 남는다. 이미 위임돼 있으면 생략.

```bash
terraform -chdir=dns apply
dig NS easyselect.kr +short   # awsdns 4개면 위임 완료
```

상세 : [runbook.md > 배포 1단계](runbook.md#-1단계-dns-스택-apply-ns-위임)

---

## # [2] SSM 수동 파라미터 (최초 1회)

앱은 부팅 시 `/wes/prod/` 아래를 통째로 읽으므로, **아래가 없으면 앱이 부팅에 실패한다**
(빠지면 `Could not resolve placeholder ...` 에러로 컨테이너가 재시작 루프를 돈다):

| 파라미터 (`/wes/prod/` 아래) | 타입 | 비고 |
|---|---|---|
| `spring.datasource.password` | SecureString | RDS 마스터 비밀번호 — apply **전에** 있어야 함 |
| `embedder.db.password` | SecureString | 임베더용 DB 사용자 비밀번호. 앱은 읽지 않는다 — SCP 우회로 전용([7] 참고) |
| `photoselect.db.password` | SecureString | score·categorize용 DB 사용자(`photoselect`) 비밀번호. 역시 앱은 읽지 않는다([7] 참고) |
| `jwt.secret` | SecureString | |
| `spring.security.oauth2.client.registration.{kakao,google,naver}.*` | SecureString | client-id/secret, redirect-uri, scope 등 |
| `cors.allowed-origins` | String | 쉼표 구분 문자열 (프론트 오리진 목록) |
| `springdoc.server-url` | String | `https://api.easyselect.kr` |

`spring.datasource.url`·`username`, `app.storage.bucket`, `app.embedding.function-name`,
`app.analysis.score-function-name`·`app.analysis.categorize-function-name`,
`app.logging.loki-url`은 테라폼이 apply 때 자동 생성하므로 등록하지 않는다.
파라미터는 destroy와 무관하게 남으므로 최초 1회만 등록하면 된다.

**관리자 API용 — `/wes/admin-api/prod/` 아래.** Terraform이 URL·사용자명·버킷·Lambda
이름을 생성하고, 다음 비밀번호만 수동 SecureString으로 등록한다. 공개 앱 비밀번호나 OAuth/JWT
값을 복사하지 않는다.

| 파라미터 (`/wes/admin-api/prod/` 아래) | 타입 | 비고 |
|---|---|---|
| `spring.datasource.password` | SecureString | 수동 생성한 `wes_admin_api` 런타임 계정 비밀번호. Flyway/DDL 권한 없음 |

**모니터링 서버용 — `/wes/prod/` 가 아니라 `/wes/monitoring/` 아래.** 앱이 `/wes/prod/`를
통째로 읽기 때문에 Grafana 비밀번호를 거기 두면 앱 컨테이너에 노출된다:

| 파라미터 (`/wes/monitoring/` 아래) | 타입 | 비고 |
|---|---|---|
| `grafana.admin-password` | SecureString | Grafana `admin` 초기 비밀번호. 없으면 모니터링 EC2의 user_data가 기동 단계에서 멈춘다 |

```bash
aws ssm put-parameter --name /wes/monitoring/grafana.admin-password --type SecureString \
  --value "$(openssl rand -base64 24)" --region ap-northeast-2
```

> `cors.allowed-origins`는 apply의 **입력**이기도 하다. 브라우저가 S3에 직접 PUT/GET 해서 프리플라이트에 답하는 것도 S3이므로, 루트 스택이 이 값을 읽어 S3 버킷의 CORS 허용 오리진으로 그대로 쓴다. 없으면 apply가 파라미터를 찾지 못해 멈춘다.

상세 : [runbook.md > 사전 준비](runbook.md#-사전-준비-최초-1회), [설정 주입](runbook.md#-설정-주입-ssm-파라미터)

---

## # [3] Lambda 셋 이미지 (스택 세울 때마다)

**Lambda는 이미지가 없는 ECR을 상대로 만들어지지 않으므로**, 리포지토리 셋만 먼저 만들고
이미지를 민 뒤에 전체 apply 한다. 코드는 AI 저장소(`organic-agent-ai`)의 최상위 디렉토리
하나 = 함수 하나(`embedder/` · `score/` · `categorize/`)이고, 각 디렉토리의 `deploy.sh`가
ECR 이름을 AWS API로 찾아 빌드·푸시하고 함수를 갱신한다. **함수가 아직 없는 첫 apply 전에는**
`deploy.sh`의 마지막 단계(`update-function-code`)가 실패하므로 빌드·푸시만 손으로 한다:

```bash
terraform apply -target='module.analysis.aws_ecr_repository.this'

aws ecr get-login-password --region ap-northeast-2 \
  | docker login --username AWS --password-stdin \
      "$(terraform output -json lambda_repository_urls | jq -r '.embedder' | cut -d/ -f1)"

for module in embedder score categorize; do
  REPO="$(aws ecr describe-repositories --region ap-northeast-2 \
    --repository-names "wes-$module" --query 'repositories[0].repositoryUri' --output text)"
  ( cd "../organic-agent-ai/$module" && docker buildx build \
      --platform linux/amd64 --provenance=false --sbom=false \
      -t "${REPO}:latest" --push . )
done
```

embedder는 DINOv3가 게이트 모델이라 빌드에 Hugging Face 토큰(`--secret id=hf_token,env=HF_TOKEN`)이
필요하다 — AI 저장소 `embedder/README.md`의 "빌드와 배포" 참고. 세 플래그가 전부 필요한
이유(아키텍처, manifest list)도 거기에 있다. embedder·score는 torch와 가중치로 이미지가
3-5GB라 첫 빌드·푸시는 수십 분 걸린다.

> 태그의 중괄호를 빼면 안 된다. zsh는 `"$REPO:latest"`의 `:l`을 소문자 변환 모디파이어로
> 해석해서 `wes-embedderatest` 같은 이름을 만들고, 빌드를 다 마친 뒤 푸시 단계에서
> `repository does not exist`로 실패한다.

---

## # [4] 앱 스택 apply (스택 세울 때마다)

```bash
terraform apply   # ACM 검증 포함 5-15분
```

EC2 user_data가 Docker·스왑을 설치하고, S3 사진 버킷과 Lambda 셋(`wes-embedder` ·
`wes-score` · `wes-categorize`), DB 서브넷의 `lambda`·`bedrock-runtime` 인터페이스 엔드포인트,
GitHub Actions용 OIDC 배포 롤도 함께 생성된다. 인터페이스 엔드포인트는 생성 뒤 몇 분 동안
`pending` 상태라, apply 직후 첫 분석 잡의 재호출·체인이 타임아웃하면 잠시 뒤 다시 부른다.

로컬 개발용 사진 버킷(`wes-dev-photos-<계정>`, `module.storage_dev`)도 같이 만들어지고
`/wes/local/app.storage.bucket`에 기록된다. 운영 버킷과 달리 인스턴스 롤 정책이 없다 — 노트북
자격증명(개발자 IAM)으로 서명·읽기·쓰기 한다. 로컬 프론트 오리진은 `local_web_origins` 변수다.
서버 저장소의 `scripts/local-ai.sh`가 이 버킷을 `S3_BUCKET`으로 읽는다.

모니터링 EC2(`wes-monitoring`)도 같이 뜬다. user_data가 Loki·Grafana·Caddy를 compose로
올리고, Caddy가 `monitoring.easyselect.kr`의 Let's Encrypt 인증서를 받는다 — A 레코드가
같은 apply에서 생기므로 **apply 완료 후 1-3분**은 인증서 오류가 정상이다.
[2]의 Grafana 비밀번호를 빼먹었으면 등록 후 서버에서 `sudo /opt/wes-monitoring/start.sh`만 다시 돌린다
([runbook.md > 모니터링](runbook.md#-모니터링-loki--grafana)).

---

## # [5] 배포 롤 시크릿 (스택 세울 때마다)

```bash
terraform output -raw github_deploy_role_arn
terraform output -raw github_admin_api_deploy_role_arn
terraform output -raw github_worker_deploy_role_arn
terraform output -raw github_admin_deploy_role_arn
```

첫 값은 서버 저장소 `AWS_DEPLOY_ROLE_ARN`, 둘째 값은 같은 저장소
`AWS_ADMIN_API_DEPLOY_ROLE_ARN`, 넷째 값은 BackOffice 저장소 `AWS_DEPLOY_ROLE_ARN`에
**시크릿**으로 등록한다. 셋째 값은 AI 저장소(`organic-agent-ai`)의 **변수(vars)**
`AWS_LAMBDA_DEPLOY_ROLE_ARN`이다 — 그 저장소의 `deploy-lambda.yml`은 이 변수가 비어 있으면
조용히 skip 하고, 있으면 main 푸시에서 바뀐 모듈의 `deploy.sh`만 돌린다. worker 역할은
`wes-embedder`·`wes-score`·`wes-categorize` ECR push와 같은 이름의 Lambda 코드 갱신·조회만
허용한다.

```bash
gh variable set AWS_LAMBDA_DEPLOY_ROLE_ARN --repo organic-agent/organic-agent-ai \
  --body "$(terraform output -raw github_worker_deploy_role_arn)"
```

**이 저장소(인프라)의 CI/CD 롤도 같이** 등록한다. 이후 PR의 plan과 main 머지의 apply가 이 롤로 돈다:

```bash
gh secret set AWS_PLAN_ROLE_ARN  --body "$(terraform output -raw github_tf_plan_role_arn)"
gh secret set AWS_APPLY_ROLE_ARN --body "$(terraform output -raw github_tf_apply_role_arn)"
```

상세 : [runbook.md > 인프라 CI/CD](runbook.md#-인프라-cicd-plan--apply)

> **주의 :** 롤 이름에 랜덤 접미사가 붙어 **destroy → apply를 거치면 ARN이 바뀌므로**,
> 스택을 다시 세웠다면 관련 역할 ARN 시크릿을 모두 갱신해야 한다. 안 하면 CD가
> `Not authorized to perform sts:AssumeRoleWithWebIdentity`로 실패한다.

---

## # [6] 앱 배포 (CD 자동)

서버 저장소(WES-Server)에서 **main에 머지**하면 CD가 자동으로:

1. `wes-domain`, `wes-api`, `wes-admin-api`를 검사하고 API 이미지 두 개를 GHCR에 푸시
2. 공개 API 전용 역할로 `wes-app`을 교체하고 Flyway/health 완료
3. 성공한 경우에만 관리자 API 전용 역할로 `wes-admin`의 API 컨테이너를 교체
4. 관리자 API health와 BackOffice BFF의 미인증 세션 `401` 연결 확인

Lambda 셋은 서버 CD와 무관하다. AI 저장소 main에 `embedder/`·`score/`·`categorize/` 변경이
머지되면 그 저장소의 `deploy-lambda.yml`이 worker 역할로 바뀐 모듈의 `deploy.sh`를 돌린다
(인프라만 바뀌어 다시 밀어야 하면 같은 워크플로의 Run workflow에서 모듈을 고른다).

`wes-admin`에서 API와 BackOffice 배포가 겹치지 않도록 두 SSM 스크립트 모두
`/var/lock/wes-admin-deploy.lock`을 `flock`으로 잡는다.

같은 이미지 재배포는 Actions 탭 → `[PROD] Build and Deploy` → Run workflow (**main 브랜치 선택** — 다른 브랜치는 롤 신뢰 조건에 걸려 실패한다).

순서 주의 : 스택이 없는 상태에서 머지하면 배포 잡이 "실행 중인 wes-app 인스턴스가
없습니다"로 실패한다(빌드·푸시는 성공). 재실행은 [3]-[5] 후 workflow_dispatch로.

앱이 처음 뜰 때 **Flyway가 스키마를 만든다**(`CREATE EXTENSION vector` 포함). 그전에는
`photos` 테이블이 없으므로 다음 단계를 할 수 없다.

---

## # [7] Lambda 셋의 DB 접속 (수동 작업 2개)

둘 다 apply가 해주지 못하는 일이고, 하나라도 빠지면 함수가 접속 단계에서 실패해 사진이
한 장도 처리되지 않는다. 상세 절차(psql 접속, 진단법 포함) :
[runbook.md > AI 파이프라인](runbook.md#-ai-파이프라인-embedder--score--categorize)

**7-1. DB 사용자** — DB를 새로 만들 때마다. SQL이라 Terraform이 만들지 못한다. 사용자는 둘이다 —
`embedder`(임베더)와 `photoselect`(score·categorize). 테이블별 GRANT는 서버의 Flyway 베이스라인이
**role이 있을 때만** 거므로, 사용자를 만든 뒤 앱을 한 번 재배포(또는 런북의 GRANT 블록을 직접 실행)한다.

```sql
CREATE USER embedder    WITH PASSWORD '<embedder.db.password 와 같은 값>';
CREATE USER photoselect WITH PASSWORD '<photoselect.db.password 와 같은 값>';
```

**7-2. 비밀번호 주입** — 함수를 새로 만들 때마다, 함수 셋 각각. Terraform이 넣으면 state에 평문으로
남으므로 apply 밖에서 넣고, `ignore_changes`가 이후 apply에서 그 키를 지킨다.
`--environment`는 맵 전체를 덮어쓰므로 **기존 값을 읽어 병합**해야 한다 — 명령은 런북에 있다.

> **원래 설계는 비밀번호가 아니라 RDS IAM 인증이었다.** 조직 SCP가 이 계정에서
> `rds-db:connect`를 거부해 임시로 되돌린 상태다. 그래서 `GRANT rds_iam`도 지금은 하지
> 않는다 — 주면 pg_hba가 PAM 경로로 보내 비밀번호 인증이 아예 막힌다.
> 판별법과 원복 절차 : [runbook.md > SCP 차단](runbook.md#-scp-차단-임시-우회로)

---

## # [8] 검증

```bash
curl -s https://api.easyselect.kr/actuator/health   # {"status":"UP"}
```

타깃 그룹은 기동 후 `healthy` 전환까지 2-3분 걸린다(30초 간격 × 5회).

```bash
curl -sI https://monitoring.easyselect.kr | head -1    # HTTP/2 302 (Grafana 로그인으로 리다이렉트)
```

브라우저로 `https://monitoring.easyselect.kr`에 `admin` / `/wes/monitoring/grafana.admin-password` 값으로
로그인 → Explore → Loki 데이터소스에 `{app="wes"}` 류의 쿼리가 앱 로그를 보여주면 끝
(앱 쪽 appender가 붙은 뒤에야 로그가 들어온다 — 서버 저장소 이슈).
전체 체크리스트 : [runbook.md > 검증 체크리스트](runbook.md#-검증-체크리스트)

---

## # 폐기 시 남는 것

`terraform destroy` 후에도 다음은 남는다 — 재배포 시 재사용되므로 지우지 말 것
(프로젝트를 완전히 접을 때만 정리):

| 남는 것 | 위치 |
|---|---|
| Route53 존 | dns 스택 (월 $0.50) |
| `/wes/prod/*`·`/wes/monitoring/*` 수동 파라미터 | SSM Parameter Store |
| 컨테이너 이미지 | GHCR |
| `AWS_DEPLOY_ROLE_ARN` 시크릿 | 서버 저장소 (재apply 시 값 갱신 필요 — [5] 참고) |
| `AWS_ADMIN_API_DEPLOY_ROLE_ARN` 시크릿 | 서버 저장소 (재apply 시 값 갱신 필요 — [5] 참고) |
| `AWS_LAMBDA_DEPLOY_ROLE_ARN` 변수 | AI 저장소 (재apply 시 값 갱신 필요 — [5] 참고) |
| `AWS_DEPLOY_ROLE_ARN` 시크릿 | BackOffice 저장소 (재apply 시 값 갱신 필요 — [5] 참고) |
| `AWS_PLAN_ROLE_ARN`·`AWS_APPLY_ROLE_ARN` 시크릿 | 이 저장소 (재apply 시 값 갱신 필요 — [5] 참고) |

반대로 **함께 사라지는 것** 중 하나는 조심해야 한다: 사진 버킷과 그 안의 원본이다.
버킷은 이 스택이 소유하고, ECR 리포지토리 셋도 `force_delete`라 Lambda 이미지까지 지워진다.
destroy 후 다시 세우려면 [3]의 빌드·푸시를 처음부터 다시 해야 한다(수십 분).
모니터링 EC2의 로그(Loki 데이터)와 EIP도 함께 사라진다 — EIP가 바뀌어도 A 레코드는
테라폼이 다시 쓰고, 인증서는 Caddy가 새로 받는다.
