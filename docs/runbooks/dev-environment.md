# dev 환경 런북

운영과 같은 규격의 dev 서버 환경(`dev.api.easyselect.kr`)을 세우고, 운영하고, 접는 절차다.
코드는 [`environments/dev/`](../../environments/dev/)에 있고, 운영 스택(저장소 루트)과 **state를 나눈다**(`dev/terraform.tfstate`).

## # 한눈에 보기

| | 운영 | dev |
|---|---|---|
| 도메인 | `api.easyselect.kr` | `dev.api.easyselect.kr` |
| 앱 EC2 | `wes-app` (t4g.micro) | `wes-dev-app` (t4g.micro) |
| ALB | `wes` | `wes-dev` |
| RDS | `wes-db` (db.t4g.micro) | `wes-dev-db` (db.t4g.micro) |
| 사진 버킷 | `wes-photos-<계정>` | `wes-dev-photos-<계정>` |
| SSM 프리픽스 | `/wes/prod/` | `/wes/dev/` |
| Spring 프로필 | `prod` | `dev` (서버 저장소가 추가) |
| Lambda | `wes-embedder`·`wes-score`·`wes-categorize` | `wes-dev-embedder`·`wes-dev-score`·`wes-dev-categorize` |
| ECR | `wes-embedder`·`wes-score`·`wes-categorize` | `wes-dev-embedder`·`wes-dev-score`·`wes-dev-categorize` |
| GPU 워커 | `wes-score-gpu` × 2 (2a·2c) | `wes-dev-score-gpu` × 1 (2a) |
| 관리자 호스트 | `wes-admin` (t4g.small), `admin.easyselect.kr` | `wes-dev-admin` (t4g.small), `dev.admin.easyselect.kr` |
| 관리자 SSM | `/wes/admin-api/prod/`, 키 `/wes/admin/tailscale-auth-key` | `/wes/admin-api/dev/`, 키 `/wes/dev-admin/tailscale-auth-key` |
| CD 브랜치 | `main` | `develop` |

**같이 쓰는 것**: VPC·서브넷·S3 게이트웨이 엔드포인트·Bedrock 리전 피어링(#71), 모니터링 서버(Loki·Grafana), Route53 존, GPU AMI.
dev가 운영 리소스에 덧붙이는 것은 운영 모니터링 SG의 Loki `:3100` 인그레스 규칙 하나뿐이다.

**만들지 않는 것**: 모니터링 서버, AMI 파이프라인. 관리자 호스트는 Tailscale 태그(`tag:wes-admin`)를 운영과 같이 써서 tailnet policy를 고치지 않는다.

> 로컬 개발용 `wes-local-photos-<계정>` 버킷과 `/wes/local/`은 이 환경과 **별개**다(운영 스택의 `storage_local`). 노트북의
> `local` 프로필용이고, dev 서버는 `wes-dev-photos-*`를 쓴다 — 로컬 pg와 dev RDS의 갤러리 id가 겹쳐 키 공간이 섞이지 않게.
>
> `wes-dev-photos-<계정>`은 예전 로컬 버킷 이름이었다. 아래 [0] 참고.

### # GPU 워커를 운영 AMI로 돌리는 방법

dev는 AMI를 따로 굽지 않는다. 운영 AMI의 `/etc/wes-score/image.env`에는 `PARAMETER_PREFIX=/wes/prod`와 운영 이미지
(`wes-score:gpu`)가 구워져 있는데, dev 워커는 user_data의 cloud-config `bootcmd`로 **부팅마다** 이 두 줄을 `/wes/dev`와
`wes-dev-score:gpu`로 덮는다. 워커 코드(AI 저장소)는 바뀌지 않는다 — 원래 기동 때 SSM에서 DB 주소·비밀번호·버킷을 읽으므로
프리픽스만 바뀌면 dev RDS·dev 버킷에 붙는다.

dev 워커 롤은 `/wes/dev/` 세 파라미터만 읽을 수 있어, 덮기 전에 서비스가 먼저 떠도 운영 파라미터를 읽지 못하고 실패 → 15초 뒤 재시작에서
덮인 값을 읽는다. 운영 DB에 붙는 경우는 없다.

**G 쿼터**: 계정 G 인스턴스 쿼터 12 vCPU = 운영 워커 2대(8) + AMI 빌드(4). dev 워커(4)는 AMI 빌드 몫을 빌려 쓴다.
AMI 빌드 중에 운영 2대와 dev 1대가 모두 켜져 있으면 늦게 켜는 쪽이 `VcpuLimitExceeded`로 실패한다 — AMI 빌드는
dev 워커가 꺼져 있을 때 돌리고, 길게 겹쳐 쓸 거면 쿼터 증설(16)을 신청한다.

### # 비용 (고정비, 월 약 $85)

| 항목 | 월 |
|---|---|
| ALB `wes-dev` + 퍼블릭 IPv4 2개 | $24.8 |
| RDS `wes-dev-db` (db.t4g.micro + gp3 20GB) | $21.6 |
| 앱 EC2 `wes-dev-app` (t4g.micro + gp3 20GB + 퍼블릭 IP) | $13.1 |
| 관리자 EC2 `wes-dev-admin` (t4g.small + gp3 20GB + 퍼블릭 IP) | 약 $20 |
| GPU 워커 1대 (정지 상태 gp3 30GB) | $2.8 |
| ECR dev 리포지토리 (score GPU 이미지 포함 약 15~20GB) | $1.5~2 |
| S3·SSM·CloudWatch | $1 미만 |

Lambda·GPU는 쓴 만큼(운영과 같은 단가). 안 쓰는 기간이 길면 [폐기](#-폐기)했다가 다시 세우는 편이 싸다.

---

## # 처음 세우기

순서가 중요하다. [1]이 없으면 PR의 dev plan부터 실패하고, [3]이 없으면 Lambda가 만들어지지 않는다.

### # [0] 로컬 버킷 이름 변경이 먼저

dev 버킷 이름(`wes-dev-photos-<계정>`)은 예전 로컬 버킷 이름이다. 로컬 버킷 이름 변경(infra #75)이 운영에 apply 되어 옛 버킷이
지워진 뒤에야 dev 스택이 그 이름으로 버킷을 만들 수 있다. 삭제 직후 같은 이름 생성이 잠시 `OperationAborted`로 실패할 수 있다 —
몇 분 뒤 dev apply를 다시 돌린다.

### # [1] SSM 수동 파라미터 (`/wes/dev/` 아래)

앱은 부팅 때 `/wes/dev/` 아래를 통째로 읽는다. **비밀 값은 운영 값을 복사하지 않고 새로 만든다**(dev가 뚫려도 운영 토큰을
위조할 수 없게). OAuth 클라이언트는 운영 앱을 재사용해도 되지만 redirect URI는 dev 도메인이다([7]).

| 파라미터 | 타입 | 값 |
|---|---|---|
| `spring.datasource.password` | SecureString | dev RDS 마스터 비밀번호 — **apply 전에** 있어야 함 |
| `embedder.db.password` | SecureString | dev DB `embedder` 사용자 비밀번호([5]) |
| `photoselect.db.password` | SecureString | dev DB `photoselect` 사용자 비밀번호([5]). dev GPU 워커가 기동 때 읽는다 |
| `cors.allowed-origins` | String | dev 프론트 오리진(쉼표 구분). **apply의 입력** — dev 버킷 CORS가 같은 값을 쓴다 |
| `jwt.secret` | SecureString | 새로 생성 |
| `springdoc.server-url` | String | `https://dev.api.easyselect.kr` |
| `spring.security.oauth2.client.registration.{kakao,google,naver}.*` | SecureString/String | 운영과 같은 키 목록. `redirect-uri`만 dev 도메인 |
| 그 밖에 운영에만 손으로 넣은 키 | | `admin.initial-password`·`app.collab.base-url`·`app.invite.base-url`·`app.llm.enabled`·`app.mock-gallery.template-gallery-id`·`app.analysis.discord-webhook-url` 등 — 아래 명령으로 운영 목록과 대조 |

Terraform이 만드는 것(등록하지 않는다): `spring.datasource.url`·`username`, `app.storage.bucket`, `app.analysis.*-function-name`,
`app.analysis.gpu.enabled`·`gpu.tag`, `app.llm.region`·`model-id`, `app.logging.loki-url`.

```bash
REGION=ap-northeast-2
aws ssm put-parameter --region $REGION --name /wes/dev/spring.datasource.password --type SecureString --value "$(openssl rand -base64 24 | tr -d '/+=')"
aws ssm put-parameter --region $REGION --name /wes/dev/embedder.db.password      --type SecureString --value "$(openssl rand -base64 24 | tr -d '/+=')"
aws ssm put-parameter --region $REGION --name /wes/dev/photoselect.db.password   --type SecureString --value "$(openssl rand -base64 24 | tr -d '/+=')"
aws ssm put-parameter --region $REGION --name /wes/dev/jwt.secret                --type SecureString --value "$(openssl rand -base64 48)"
aws ssm put-parameter --region $REGION --name /wes/dev/springdoc.server-url      --type String --value https://dev.api.easyselect.kr
aws ssm put-parameter --region $REGION --name /wes/dev/cors.allowed-origins      --type String --value 'http://localhost:3000,http://localhost:5173'

# 운영에는 있고 dev에는 없는 키 — Terraform이 만드는 키는 dev apply 뒤 사라진다. 남는 것이 손으로 넣을 목록이다.
comm -23 \
  <(aws ssm get-parameters-by-path --region $REGION --path /wes/prod/ --recursive --query 'Parameters[].Name' --output text | tr '\t' '\n' | sed 's|^/wes/prod/||' | sort) \
  <(aws ssm get-parameters-by-path --region $REGION --path /wes/dev/  --recursive --query 'Parameters[].Name' --output text | tr '\t' '\n' | sed 's|^/wes/dev/||'  | sort)
```

### # [2] ECR만 먼저 만들기 (로컬)

Lambda는 이미지가 있는 리포지토리를 상대로만 만들어진다. 첫 apply는 리포지토리만 로컬에서 만든다.

```bash
terraform -chdir=environments/dev init
terraform -chdir=environments/dev apply \
  -target='module.analysis.aws_ecr_repository.this' \
  -target='module.analysis.aws_ecr_lifecycle_policy.this'
```

### # [3] 첫 이미지 넣기

AI 저장소의 dev CD([7])가 아직 없으면 운영 이미지를 그대로 복사한다(압축 약 7GB, score GPU 이미지가 4GB).
`imagetools create`는 레지스트리끼리 블롭을 복사해 로컬 디스크를 쓰지 않는다. 다만 태그를 원본을 감싼 이미지 인덱스에 달아
다이제스트가 원본과 달라지고, Lambda는 인덱스를 거부할 수 있다 — 그래서 블롭 복사 뒤 원본 매니페스트를 `put-image`로 다시 태그한다.
결과 다이제스트가 운영과 같아야 한다. bash로 돌린다(zsh는 인자 분리가 달라 `copy` 인자가 깨진다).

```bash
#!/usr/bin/env bash
set -eo pipefail
REG=233927217926.dkr.ecr.ap-northeast-2.amazonaws.com
aws ecr get-login-password --region ap-northeast-2 | docker login --username AWS --password-stdin $REG

copy() {  # copy <운영 리포지토리> <dev 리포지토리> <태그>
  docker buildx imagetools create -t "$REG/$2:$3" "$REG/$1:$3"   # 블롭 복사
  local q="images[0]"
  aws ecr put-image --repository-name "$2" --image-tag "$3"     --image-manifest "$(aws ecr batch-get-image --repository-name "$1" --image-ids imageTag="$3" --query "$q.imageManifest" --output text)"     --image-manifest-media-type "$(aws ecr batch-get-image --repository-name "$1" --image-ids imageTag="$3" --query "$q.imageManifestMediaType" --output text)" >/dev/null
  aws ecr describe-images --repository-name "$2" --image-ids imageTag="$3" --query 'imageDetails[0].imageDigest' --output text
}
copy wes-embedder   wes-dev-embedder   latest
copy wes-score      wes-dev-score      latest
copy wes-categorize wes-dev-categorize latest
copy wes-score      wes-dev-score      gpu      # dev GPU 워커가 부팅 때 pull
```

### # [4] 전체 apply

```bash
terraform -chdir=environments/dev plan
terraform -chdir=environments/dev apply
```

이후 변경은 PR → CI plan(`dev` 스택) → 머지 → CI apply(`apply-dev`, 운영 apply 다음)로 간다. dev 롤은 이름이 `wes-dev-*`라
운영 tf_apply의 IAM 울타리 안이어서 CI로 만들어진다.

GPU 워커는 생성 직후 정지된다. 켜는 것은 dev 앱(GpuController, 태그 `wes-dev-score-gpu`)이다.

### # [5] dev DB 사용자 (앱이 한 번 뜬 뒤)

테이블은 앱 첫 기동 때 Flyway가 만든다. 서버 dev CD로 앱을 한 번 띄운 뒤([7]), 운영 런북
[DB 사용자](runbook.md#-1-db-사용자-db를-새로-만들-때마다) 절차를 그대로 따르되 값만 바꾼다:

- 인스턴스 `wes-dev-app` (SSM 세션 또는 Run Command), RDS 주소 `terraform -chdir=environments/dev output -raw rds_endpoint`
- 비밀번호 파라미터 `/wes/dev/spring.datasource.password`·`/wes/dev/embedder.db.password`·`/wes/dev/photoselect.db.password`
- 커넥션 상한: `photoselect`는 dev 워커가 1대라 운영과 같은 24로 둬도 넉넉하다

### # [6] Lambda 비밀번호 주입

운영 런북 [비밀번호 주입](runbook.md#-2-비밀번호-주입-함수를-새로-만들-때마다)의 `inject` 함수를 그대로 쓰고 대상만 바꾼다:

```bash
inject wes-dev-embedder   /wes/dev/embedder.db.password
inject wes-dev-score      /wes/dev/photoselect.db.password
inject wes-dev-categorize /wes/dev/photoselect.db.password
```

### # [7] 다른 저장소·콘솔

| 어디 | 무엇 |
|---|---|
| 카카오·구글·네이버 개발자 콘솔 | `terraform -chdir=environments/dev output oauth_redirect_uris`의 URI를 redirect URI로 추가 |
| 서버 저장소 | `application.yml`에 `on-profile: dev` 문서(`spring.config.import: aws-parameterstore:/wes/dev/`), `docker-compose.dev.yml`(`SPRING_PROFILES_ACTIVE=dev`), `develop` 브랜치 push로 도는 dev CD(`INSTANCE_NAME_TAG=wes-dev-app`, 공개 API만 — 관리자 API 배포 잡 없음), alloy 설정의 env 라벨(운영 Loki에 dev 로그가 섞이므로) |
| 서버 저장소 시크릿 | `AWS_DEV_DEPLOY_ROLE_ARN` = `terraform -chdir=environments/dev output -raw github_deploy_role_arn` |
| AI 저장소 | `develop` 브랜치 push로 도는 dev CD — `wes-dev-*` ECR에 `latest`(Lambda)·`gpu`(GPU 워커) push, `wes-dev-*` 함수 `update-function-code` |
| AI 저장소 시크릿 | `AWS_DEV_WORKER_DEPLOY_ROLE_ARN` = `terraform -chdir=environments/dev output -raw github_worker_deploy_role_arn` |

dev CD 롤은 `develop` 브랜치 토큰만 받는다(`dev_branch` 변수). 다른 브랜치에서 dev에 올리려면 변수를 바꾸는 PR을 낸다.

### # [8] 관리자 호스트 (`wes-dev-admin`)

운영 관리자(`docs/architecture/admin-internal-access.md`)와 같은 2단계다.

1. **apply 전** 손으로 넣는다. auth key는 부팅 때 한 번만 읽으므로 없이 뜨면 인스턴스를 교체해야 한다.
   - Tailscale 콘솔에서 one-off · non-ephemeral · pre-approved · `tag:wes-admin` auth key → `/wes/dev-admin/tailscale-auth-key` SecureString
   - `/wes/admin-api/dev/spring.datasource.password` SecureString (새로 생성)
2. apply 뒤 SSM으로 `cloud-init status --wait; tailscale ip -4` → 나온 IP를 `admin_tailscale_ipv4` 기본값에 커밋하는 PR. plan이 A 레코드 1개만 추가하는지 본다.
3. dev DB에 관리자 API 사용자(`wes_admin_api`)를 운영과 같은 권한으로 만든다(비밀번호 = 1의 값).
4. 서버 저장소 시크릿 `AWS_DEV_ADMIN_API_DEPLOY_ROLE_ARN` = `output -raw github_admin_api_deploy_role_arn`,
   백오피스 저장소 시크릿 `AWS_DEV_DEPLOY_ROLE_ARN` = `output -raw github_admin_deploy_role_arn`. 두 저장소 모두 `develop` 브랜치에서만 assume 된다.

---

## # 폐기

```bash
terraform -chdir=environments/dev destroy
```

운영에는 영향이 없다 — 운영 모니터링 SG의 dev Loki 규칙만 같이 지워진다. RDS는 최종 스냅샷 없이, 사진 버킷과 ECR은 내용째 지워진다
(운영과 같은 "테스트 환경" 설정). SSM `/wes/dev/` 수동 파라미터는 남으므로 다시 세울 때 [1]을 건너뛴다. 다시 세울 때는 [2]부터.

---

## # 문제 해결

| 증상 | 원인 | 조치 |
|---|---|---|
| PR의 `dev` plan이 `reading SSM Parameter (/wes/dev/cors.allowed-origins)`로 실패 | [1]을 안 했다 | [1] 등록 후 plan 재실행 |
| apply가 Lambda 생성에서 `Source image ... does not exist` | dev ECR에 이미지가 없다 | [3] 후 다시 apply |
| dev 앱이 `Could not resolve placeholder` 재시작 루프 | 운영에만 손으로 넣은 키가 `/wes/dev/`에 없다 | [1]의 `comm` 명령으로 빠진 키 확인 |
| dev 분석이 GPU를 안 켜고 Lambda 폴백만 돈다 | `/wes/dev/app.analysis.gpu.tag`가 없거나 앱이 그 전에 떴다 | dev apply 확인 후 앱 재시작 |
| dev GPU 워커가 켜졌다가 바로 꺼진다 | `wes-dev-score:gpu` 이미지가 없거나 `/wes/dev/photoselect.db.password`가 없다 | SSM 세션으로 `journalctl -u wes-score`, `cat /etc/wes-score/image.env`가 dev 값인지 확인 |
| dev GPU 워커 Start가 `VcpuLimitExceeded` | AMI 빌드·운영 2대와 겹쳤다 | 빌드가 끝난 뒤 다시, 또는 G 쿼터 증설 |
| Grafana에 dev 로그가 운영과 섞인다 | 서버 alloy 설정에 env 라벨이 없다 | [7] 서버 저장소 항목 |
