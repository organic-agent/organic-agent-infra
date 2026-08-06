# WES 배포 순서

제로 상태(앱 스택 destroy)에서 서비스가 뜰 때까지의 전체 순서.
각 단계의 상세 절차는 [runbook.md](runbook.md) 해당 섹션 참고.

```
[1] dns 스택 (최초 1회)          — Route53 존 + NS 위임
[2] SSM 수동 파라미터 등록        — DB 비밀번호, OAuth, cors 등
[3] ECR만 먼저 apply → 이미지 푸시 — 임베더 컨테이너 (Lambda보다 먼저 있어야 한다)
[4] 앱 스택 terraform apply      — VPC/ALB/EC2/RDS + S3 + Lambda + 배포 롤
[5] AWS_DEPLOY_ROLE_ARN 시크릿   — 서버 저장소에 롤 ARN 등록
[6] 서버 저장소 main 머지         — CD가 빌드→GHCR→SSM 배포 (Flyway가 스키마 생성)
[7] 임베딩용 DB 사용자 생성        — photos 테이블이 생긴 뒤 1회
[8] 검증                         — 헬스체크·타깃 그룹·OAuth·업로드
```

1~2는 한 번 해두면 destroy 후 재배포 때 건너뛴다. 3~5는 스택을 다시 세울 때마다,
6·8은 배포할 때마다 반복된다. 7은 DB를 새로 만들 때만 다시 한다.

## [1] dns 스택 — 최초 1회

존은 앱 스택과 분리되어 destroy 후에도 남는다. 이미 위임돼 있으면 생략.

```bash
terraform -chdir=dns apply
dig NS easyselect.kr +short   # awsdns 4개면 위임 완료
```

상세: [runbook.md > 배포 1단계](runbook.md#1단계--dns-스택으로-존-생성-등록기관에서-ns-변경)

## [2] SSM 수동 파라미터 — 최초 1회

앱은 부팅 시 `/wes/prod/` 아래를 통째로 읽는다. **아래가 없으면 앱이 부팅에 실패한다**
(빠지면 `Could not resolve placeholder ...` 에러로 컨테이너가 재시작 루프를 돈다):

| 파라미터 (`/wes/prod/` 아래) | 타입 | 비고 |
|---|---|---|
| `spring.datasource.password` | SecureString | RDS 마스터 비밀번호 — apply **전에** 있어야 함 |
| `jwt.secret` | SecureString | |
| `spring.security.oauth2.client.registration.{kakao,google,naver}.*` | SecureString | client-id/secret, redirect-uri, scope 등 |
| `cors.allowed-origins` | String | 쉼표 구분 문자열 (프론트 오리진 목록) |
| `springdoc.server-url` | String | `https://api.easyselect.kr` |

`spring.datasource.url`·`username`, `app.storage.bucket`, `app.embedding.function-name`은
테라폼이 apply 때 자동 생성하므로 등록하지 않는다.
파라미터는 destroy와 무관하게 남으므로 최초 1회만 등록하면 된다.

> `cors.allowed-origins`는 apply의 **입력**이기도 하다. 루트 스택이 이 값을 읽어 S3 버킷의
> CORS 허용 오리진으로 그대로 쓴다(브라우저가 S3에 직접 PUT/GET 하므로 프리플라이트에
> 답하는 것도 S3다). 없으면 apply가 파라미터를 찾지 못해 멈춘다.

상세: [runbook.md > 사전 준비](runbook.md#사전-준비-최초-1회), [설정 주입](runbook.md#설정-주입-ssm-파라미터)

## [3] 임베더 이미지 — 스택 세울 때마다

**Lambda는 이미지가 없는 ECR을 상대로 만들어지지 않는다.** 리포지토리만 먼저 만들고,
이미지를 밀고, 그 다음에 전체 apply 한다.

```bash
terraform apply -target=module.embedding.aws_ecr_repository.this

REPO="$(terraform output -raw embedder_repository_url)"
aws ecr get-login-password --region ap-northeast-2 \
  | docker login --username AWS --password-stdin "${REPO%%/*}"

cd ../organic-agent-server/wes/embedder
docker buildx build --platform linux/amd64 --provenance=false --sbom=false \
  -t "${REPO}:latest" --push .
```

세 플래그가 전부 필요한 이유(아키텍처, manifest list)는 서버 저장소의
`wes/embedder/README.md`에 있다. 이미지가 3~5GB라 첫 빌드·푸시는 수십 분 걸린다.

> 태그의 중괄호를 빼면 안 된다. zsh는 `"$REPO:latest"`의 `:l`을 소문자 변환 모디파이어로
> 해석해서 `wes-embedderatest` 같은 이름을 만든다. 빌드를 다 마친 뒤 푸시 단계에서
> `repository does not exist`로 떨어진다.

## [4] 앱 스택 apply — 스택 세울 때마다

```bash
terraform apply   # ACM 검증 포함 5~15분
```

EC2 user_data가 Docker·스왑을 설치하고, S3 사진 버킷과 임베딩 Lambda,
GitHub Actions용 OIDC 배포 롤도 함께 생성된다.

## [5] 배포 롤 시크릿 등록 — 스택 세울 때마다

```bash
terraform output -raw github_deploy_role_arn
```

이 값을 서버 저장소 **Settings → Secrets and variables → Actions**의
`AWS_DEPLOY_ROLE_ARN` 시크릿에 등록(있으면 Update).

> **주의:** 롤 이름에 랜덤 접미사가 붙어 **destroy → apply를 거치면 ARN이 바뀐다.**
> 스택을 다시 세웠다면 시크릿도 갱신해야 한다. 안 하면 CD가
> `Not authorized to perform sts:AssumeRoleWithWebIdentity`로 실패한다.

## [6] 앱 배포 — CD 자동

서버 저장소(WES-Server)에서 **main에 머지**하면 CD가 자동으로:

1. JAR 빌드 → arm64 이미지 빌드 → GHCR 푸시
2. OIDC로 배포 롤 assume (main 브랜치 토큰만 허용)
3. `wes-app` 태그로 인스턴스 조회 → SSM Run Command로 `docker compose pull && up`
4. 헬스체크(최대 150초) 통과까지 확인

같은 이미지 재배포는 Actions 탭 → `[PROD] Build and Deploy` → Run workflow (**main 브랜치 선택** — 다른 브랜치는 롤 신뢰 조건에 걸려 실패한다).

순서 주의: 스택이 없는 상태에서 머지하면 배포 잡이 "실행 중인 wes-app 인스턴스가
없습니다"로 실패한다(빌드·푸시는 성공). 재실행은 [3]~[5] 후 workflow_dispatch로.

앱이 처음 뜰 때 **Flyway가 스키마를 만든다**(`CREATE EXTENSION vector` 포함). 그전에는
`photos` 테이블이 없으므로 다음 단계를 할 수 없다.

## [7] 임베딩용 DB 사용자 — DB를 새로 만들 때마다

Lambda는 비밀번호 없이 **RDS IAM 인증**으로 붙는다. Terraform이 `rds-db:connect` 권한과
인스턴스의 IAM 인증 활성화까지는 해주지만, **DB 안의 사용자는 만들지 못한다** — SQL이라서다.
그 사용자가 없으면 임베딩 실행이 `PAM authentication failed`로 죽는다.

상세 절차(psql 접속 포함): [runbook.md > 임베딩 파이프라인](runbook.md#임베딩-파이프라인)

```sql
CREATE USER embedder;
GRANT rds_iam TO embedder;
GRANT SELECT, UPDATE ON photos TO embedder;
```

## [8] 검증

```bash
curl -s https://api.easyselect.kr/actuator/health   # {"status":"UP"}
```

타깃 그룹은 기동 후 `healthy` 전환까지 2~3분 걸린다(30초 간격 × 5회).
전체 체크리스트: [runbook.md > 검증 체크리스트](runbook.md#검증-체크리스트)

## 폐기 시 남는 것

`terraform destroy` 후에도 다음은 남는다 — 재배포 시 재사용되므로 지우지 말 것
(프로젝트를 완전히 접을 때만 정리):

| 남는 것 | 위치 |
|---|---|
| Route53 존 | dns 스택 (월 $0.50) |
| `/wes/prod/*` 수동 파라미터 | SSM Parameter Store |
| 컨테이너 이미지 | GHCR |
| `AWS_DEPLOY_ROLE_ARN` 시크릿 | 서버 저장소 (재apply 시 값 갱신 필요 — [5] 참고) |

반대로 **함께 사라지는 것** 중 하나는 조심해야 한다: 사진 버킷과 그 안의 원본이다.
버킷은 이 스택이 소유하고, ECR 리포지토리도 `force_delete`라 임베더 이미지까지 지워진다.
destroy 후 다시 세우려면 [3]의 빌드·푸시를 처음부터 다시 해야 한다(수십 분).
