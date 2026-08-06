# WES 인프라 런북

OAuth(Kakao/Google/Naver) 로그인 테스트를 위한 최소 사양 환경.
API 도메인: `api.easyselect.kr`

> **운영 설정 아님** — 백업/스냅샷/삭제 보호가 전부 꺼져 있고, 앱 스택은 `terraform destroy`로 언제든 폐기 가능하다.

## 빠른 참조

| 하고 싶은 것 | 명령 / 위치 |
|---|---|
| 제로부터 전체 배포 | [deploy-order.md](deploy-order.md) (순서 요약) |
| 서버 쉘 접속 | `ssh wes` (설정은 [서버 접속](#서버-접속-ssm--22번-포트-불필요)) |
| 앱 배포 | 서버 저장소 main 머지 시 CD 자동 (재배포는 Actions 수동 실행) → [앱 배포](#앱-배포-cd-자동) |
| 인프라 배포 | `terraform apply` (루트에서) → [배포](#배포-ns-위임-때문에-2단계) |
| 임베더 이미지 빌드·배포 | [임베딩 파이프라인](#임베딩-파이프라인) |
| 임베딩이 안 돌 때 | [임베딩 파이프라인 > 문제 해결](#문제-해결) |
| 전부 정리 | `terraform destroy` (존은 남음) → [폐기](#폐기) |
| DB 비밀번호 변경 | [사전 준비](#사전-준비-최초-1회) 하단 참조 |

## 아키텍처

```
Route53 존 easyselect.kr (dns/ 스택 소유, 공용)
  → api.easyselect.kr
  → ALB (ACM/HTTPS, 80→443 리다이렉트)
  → EC2 t4g.micro (Ubuntu 24.04 arm64, Docker + 스왑 2GB, Spring Boot 컨테이너 :8080, 퍼블릭 서브넷)
  → RDS PostgreSQL 16 db.t4g.micro (비공개, DB 서브넷, EC2·Lambda SG에서만 접근)

브라우저 ──서명 URL──→ S3 (wes-photos-*, 전면 비공개)
                          ↑ GET
앱 ──lambda:Invoke(EVENT)──→ 임베딩 Lambda (DB 서브넷, S3 게이트웨이 엔드포인트)
                          └─ IAM 인증으로 RDS에 UPDATE photos SET embedding
```

### 스택 구조

| 스택 | 경로 | 담당 | destroy 시 |
|---|---|---|---|
| 앱 스택 | 저장소 루트 | VPC / ALB / EC2 / RDS | 전부 삭제 (테스트 데이터 포함) |
| 존 스택 | `dns/` | Route53 호스팅 존 + NS 위임 | 앱 스택과 무관하게 유지 |

- state는 **S3 원격 백엔드** (`wes-tf-state-233927217926`, 암호화+버전닝+S3 네이티브 잠금). AWS 자격증명만 있으면 누구든 plan/apply 가능 — 동시 apply는 잠금이 막아준다.
- 설정값은 전부 `variables.tf` 기본값으로 커밋돼 있다 — tfvars 파일 불필요. 값을 바꿀 땐 기본값을 수정해 커밋한다.

### 네트워크 / 접속

- 서버 접속은 **SSM 경유가 기본** — 보안그룹에 22번 포트 인바운드 규칙이 없다(`ssh_allowed_cidr` 기본값 `null` → 규칙 미생성). 키페어(`wes-aws-key`)는 비상용으로 등록만 해둔다.
- NAT 게이트웨이 없음. EC2가 퍼블릭 IP로 OAuth 토큰 교환 아웃바운드를 직접 처리한다.
- EC2 퍼블릭 IP는 stop/start 시 바뀐다(EIP 없음). SSH 주소만 영향받고 redirect URI는 도메인 경유라 무관하다.

### 설정 주입 (SSM 파라미터)

팀 컨벤션 `/wes/<환경>/<스프링 프로퍼티>`를 따른다. 이 환경은 `/wes/prod/`.

| 파라미터 | 생성 주체 | 비고 |
|---|---|---|
| `spring.datasource.url` | 테라폼 (apply 시 자동) | 비밀 아님 |
| `spring.datasource.username` | 테라폼 (apply 시 자동) | 비밀 아님 |
| `spring.datasource.password` | **수동 등록** (SecureString) | 테라폼은 ephemeral + write-only(`password_wo`)로 전달만 — **state에 비밀번호가 남지 않는다** |
| `app.storage.bucket` | 테라폼 (apply 시 자동) | 원본 사진 버킷 이름 |
| `app.embedding.function-name` | 테라폼 (apply 시 자동) | 임베딩 Lambda 이름 |
| `cors.allowed-origins` | **수동 등록** (String) | apply의 **입력**이기도 하다 — 테라폼이 이 값을 읽어 S3 버킷 CORS에 그대로 쓴다 |

앱은 부팅 시 Spring Cloud AWS로 `/wes/prod/` 아래 파라미터를 직접 읽는다. EC2 인스턴스 프로파일에 이 경로 읽기 권한이 있으므로 앱용 자격증명/env var 주입이 필요 없고, 나중에 OAuth 클라이언트 시크릿 등을 `/wes/prod/`에 추가하면 앱이 바로 읽을 수 있다.

### 비용

월 ~$45–50 (ALB ~$17.5, RDS ~$21, EC2+EBS ~$8.5) + 존 $0.50.
**테스트 안 할 때는 앱 스택 destroy 권장.**

임베딩 파이프라인이 붙어도 고정비는 거의 늘지 않는다. S3 게이트웨이 엔드포인트는 무료고,
Lambda는 부를 때만 과금된다(3GB × 실행 시간). 실질적으로 늘어나는 것은 S3에 쌓이는 원본과
ECR에 있는 임베더 이미지 3~5GB(월 ~$0.5)다.

## 사전 준비 (최초 1회)

DB 마스터 비밀번호를 SSM에 등록한다 (RDS 금지 문자 `/ @ " 공백` 제외, 8자 이상):

```bash
aws ssm put-parameter --name /wes/prod/spring.datasource.password --type SecureString \
  --value "$(openssl rand -hex 24)" --region ap-northeast-2
```

이미 등록돼 있으면 생략.

> **비밀번호를 바꿀 때는** `put-parameter --overwrite` 후 `variables.tf`의 `db_password_version` 기본값을 1 올려 **커밋**하고 apply해야 RDS에 반영된다. (커밋해야 다른 협업자의 plan과 어긋나지 않는다.)

## 배포 (NS 위임 때문에 2단계)

ACM 인증서의 DNS 검증은 easyselect.kr의 네임서버가 Route53 존으로 위임된 뒤에만 완료된다.
**위임 전에 앱 스택을 apply하면** `aws_acm_certificate_validation`에서 대기하다 타임아웃(75분)난다.

### 1단계 — dns 스택으로 존 생성, 등록기관에서 NS 변경

```bash
terraform -chdir=dns init
terraform -chdir=dns apply
terraform -chdir=dns output name_servers
```

출력된 NS 4개(`ns-xxx.awsdns-xx...`)를 easyselect.kr 등록기관(가비아/후이즈 등)의 **네임서버 설정**에 입력한다.

전파 확인 (몇 분~몇 시간):

```bash
dig NS easyselect.kr +short   # awsdns 4개가 보이면 위임 완료
```

### 2단계 — 앱 스택 apply (저장소 루트에서)

```bash
terraform init
terraform apply   # ~36개 리소스, ACM 검증 포함 5~15분
terraform output
```

## OAuth 콘솔 등록

`terraform output oauth_redirect_uris` 값을 각 콘솔에 등록:

| 제공자 | 콘솔 | redirect URI |
|---|---|---|
| Kakao | developers.kakao.com | `https://api.easyselect.kr/login/oauth2/code/kakao` |
| Google | console.cloud.google.com | `https://api.easyselect.kr/login/oauth2/code/google` |
| Naver | developers.naver.com | `https://api.easyselect.kr/login/oauth2/code/naver` |

(Spring Security 기본 패턴 `/login/oauth2/code/{registrationId}` 기준. 백엔드가 커스텀 경로를 쓰면 그에 맞게 수정.)

## 서버 접속 (SSM — 22번 포트 불필요)

보안그룹에 SSH 인바운드 규칙이 없고, 접근 제어는 IAM으로 한다.
AWS 자격증명이 있는 팀원은 아래 설정만 하면 각자 접속 가능.

### 쉘만 필요할 때 — 키·플러그인 설정 불필요

```bash
aws ssm start-session --region ap-northeast-2 \
  --target $(aws ec2 describe-instances --region ap-northeast-2 \
    --filters 'Name=tag:Name,Values=wes-app' 'Name=instance-state-name,Values=running' \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)
```

### scp/ssh 쓰려면 — 최초 1회, 팀원 각자 로컬 설정

1. Session Manager 플러그인 설치:

   ```bash
   brew install --cask session-manager-plugin   # macOS 기준
   ```

2. 개인키 `~/.ssh/wes-aws-key`를 팀 비밀 채널(1Password 등)로 전달받아 저장:

   ```bash
   chmod 600 ~/.ssh/wes-aws-key
   ```

3. `~/.ssh/config`에 추가:

   ```
   # WES 앱 서버 — SSM 터널 위로 SSH/SCP (22번 포트 개방 불필요)
   # Name 태그로 인스턴스 ID를 찾으므로 인스턴스가 재생성돼도 그대로 동작
   Host wes
     User ubuntu
     IdentityFile ~/.ssh/wes-aws-key
     ProxyCommand sh -c "aws ssm start-session --region ap-northeast-2 --target $(aws ec2 describe-instances --region ap-northeast-2 --filters 'Name=tag:Name,Values=wes-app' 'Name=instance-state-name,Values=running' --query 'Reservations[0].Instances[0].InstanceId' --output text) --document-name AWS-StartSSHSession --parameters 'portNumber=%p'"

   # 인스턴스 ID 직접 지정: ssh i-xxxxxxxx
   Host i-* mi-*
     User ubuntu
     IdentityFile ~/.ssh/wes-aws-key
     ProxyCommand aws ssm start-session --region ap-northeast-2 --target %h --document-name AWS-StartSSHSession --parameters 'portNumber=%p'
   ```

이후 `ssh wes`, `scp app.jar wes:~/`, `rsync` 전부 평소처럼 동작한다.

> 인스턴스를 재생성하면 호스트 키가 바뀐다. 경고가 뜨면 `ssh-keygen -R wes` 후 재접속.

### 비상용 직접 SSH (SSM 장애 등)

```bash
terraform apply -var="ssh_allowed_cidr=$(curl -s ifconfig.me)/32"   # 내 IP만 22번 오픈
ssh -i ~/.ssh/wes-aws-key ubuntu@$(terraform output -raw ec2_public_ip)
terraform apply                                                     # 작업 후 규칙 제거
```

## 앱 배포 (CD 자동)

서버 저장소(WES-Server)의 CD가 main 머지 시 GHCR에 arm64 이미지를 올리고,
**GitHub OIDC → `wes-deploy-*` 롤 → SSM Run Command**로 EC2에서 `docker compose pull && up`을 실행한다.
SSH 키·호스트 IP·22번 포트가 전혀 필요 없다. 같은 이미지 재배포는 Actions의 `workflow_dispatch` 수동 실행.

### 최초 1회 — 서버 저장소에 배포 롤 연결

```bash
terraform output -raw github_deploy_role_arn
```

이 값을 서버 저장소의 Actions 시크릿 `AWS_DEPLOY_ROLE_ARN`에 등록한다. (비밀은 아니지만 저장소 밖 값이라 시크릿으로 관리)

> 롤의 신뢰 조건은 `organic-agent/organic-agent-server`의 **main 브랜치**로 제한돼 있다.
> 저장소를 옮기면 `variables.tf`의 `github_repository` 기본값을 수정해 apply.

수동 점검이 필요하면 `ssh wes` 후 `docker ps`, `docker logs wes-app`, 컨테이너 교체는 `/opt/wes-prod`에서 `docker compose` 명령으로 한다.

앱이 Spring Cloud AWS로 `/wes/prod/` 파라미터를 직접 읽으므로 DB env var 주입은 필요 없다.
OAuth 클라이언트 ID/시크릿도 `/wes/prod/` 아래 SecureString 파라미터로 등록하면 앱이 같은 방식으로 읽는다 — 인프라/저장소에 커밋하지 않는다.

## 임베딩 파이프라인

작가가 갤러리에 원본을 올리면 각 사진의 임베딩 벡터가 `photos.embedding`(pgvector
`vector(768)`)에 적재된다. 잡 코드는 서버 저장소의 `wes/embedder/`에 있다.

```
프론트 ──서명 PUT──→ S3          (앱은 목적지만 정해주고 바이트는 거치지 않는다)
프론트 ──POST /photos/complete──→ 앱   (status: PENDING → UPLOADED)
프론트 ──POST /embeddings/run──→ 앱 ──lambda:Invoke(EVENT)──→ 임베딩 Lambda
                                                              ├─ S3 GET (게이트웨이 엔드포인트)
                                                              ├─ DINOv2 (CPU)
                                                              └─ UPDATE photos SET embedding
진행 상황: GET /photos/summary 의 embedded 수
```

**갤러리 단위로 한 번 부른다.** S3 이벤트로 장당 트리거를 걸면 수천 장 업로드가 Lambda
수천 개를 동시에 띄우고, 각자 커넥션을 열어 db.t4g.micro를 고갈시킨다.

**응답을 기다리지 않는다(EVENT).** 갤러리 하나가 Lambda 상한인 15분까지 걸릴 수 있다.

**재실행이 안전하다.** 대상 조건이 `embedding IS NULL`이라 중간에 죽어도 다시 부르면
남은 것만 이어서 한다.

### 접속에 비밀번호가 없다 — 그래서 수동 작업이 하나 있다

Lambda는 NAT도 인터페이스 엔드포인트도 없는 DB 서브넷에 있어서 Parameter Store를 읽을 수
없고, 비밀번호를 환경변수로 주입하면 이 스택이 지켜 온 "비밀번호는 state에 남기지 않는다"가
깨진다. 그래서 **RDS IAM 인증**을 쓴다 — 토큰 생성은 네트워크를 타지 않는 로컬 서명이다.

Terraform이 해주는 것은 두 가지뿐이다:

- RDS 인스턴스의 `iam_database_authentication_enabled = true`
- Lambda 롤의 `rds-db:connect` (대상 ARN에 RDS 리소스 ID와 사용자 이름이 박힌다)

**DB 안의 사용자는 Terraform이 만들지 못한다.** SQL이라서다. 없으면 임베딩 실행이
`PAM authentication failed`로 죽는다. DB를 새로 만들 때마다 한 번씩:

```bash
# photos 테이블은 앱이 처음 뜰 때 Flyway가 만든다. 그 뒤에 실행할 것.
ssh wes
sudo apt-get install -y postgresql-client
DB_PASSWORD=$(aws ssm get-parameter --name /wes/prod/spring.datasource.password \
  --with-decryption --query Parameter.Value --output text --region ap-northeast-2)
PGPASSWORD="$DB_PASSWORD" psql -h <rds_address> -U wes_admin -d wes_db
```

```sql
CREATE USER embedder;
GRANT rds_iam TO embedder;
-- 잡이 건드리는 것은 이 테이블뿐이다. 넓게 주지 않는다.
GRANT SELECT, UPDATE ON photos TO embedder;
```

> 마스터 계정(`wes_admin`)에 `rds_iam`을 주는 것으로 대신할 수 없다. RDS가 마스터 사용자에
> 대해서는 그 역할 부여를 거부한다.

### 이미지 빌드·배포

첫 apply 순서(리포지토리 → 푸시 → 전체 apply)는
[deploy-order.md의 [3]](deploy-order.md#3-임베더-이미지--스택-세울-때마다)에 있다.
코드만 바뀐 뒤의 재배포는 apply 없이:

```bash
REPO="$(terraform output -raw embedder_repository_url)"
aws ecr get-login-password --region ap-northeast-2 \
  | docker login --username AWS --password-stdin "${REPO%%/*}"

cd ../organic-agent-server/wes/embedder
docker buildx build --platform linux/amd64 --provenance=false --sbom=false \
  -t "${REPO}:latest" --push .

aws lambda update-function-code --region ap-northeast-2 \
  --function-name "$(terraform output -raw embedder_function_name)" \
  --image-uri "${REPO}:latest"
```

> 태그의 중괄호를 빼면 안 된다. zsh는 `"$REPO:latest"`의 `:l`을 소문자 변환 모디파이어로
> 해석해서 엉뚱한 리포지토리 이름을 만든다 (deploy-order.md의 [3] 참고).

함수의 `image_uri`는 `ignore_changes`라 이렇게 밀어 넣어도 다음 plan이 되돌리지 않는다.

### 수동 실행

```bash
aws lambda invoke --region ap-northeast-2 \
  --function-name "$(terraform output -raw embedder_function_name)" \
  --cli-binary-format raw-in-base64-out \
  --payload '{"galleryId":1,"force":false}' /dev/stdout
```

로그: `aws logs tail /aws/lambda/wes-embedder --follow`

### 문제 해결

| 증상 | 원인 |
|---|---|
| `PAM authentication failed for user "embedder"` | DB 사용자를 안 만들었거나 `GRANT rds_iam`이 빠졌다 (위 참고) |
| S3 GET에서 타임아웃 (자격증명 오류처럼 보이지 않는다) | DB 서브넷의 S3 게이트웨이 엔드포인트가 없다 |
| 호출은 되는데 핸들러 로그가 없다 | VPC 함수의 ENI를 못 만들었다 — 롤에 `AWSLambdaVPCAccessExecutionRole` 확인 |
| `InvalidParameterValueException: image manifest ... not supported` | buildx가 manifest list를 만들었다 — `--provenance=false --sbom=false` 빠짐 |
| 앱이 `PHOTO_503_1`로 답한다 | `app.embedding.function-name` 파라미터가 없다 (apply가 만든다) |
| 앱이 `PHOTO_502_1`로 답한다 | 호출 자체가 거절됐다 — 인스턴스 롤의 `lambda:InvokeFunction` 확인 |
| 업로드가 브라우저 프리플라이트에서 죽는다 | S3 버킷 CORS의 오리진 — `cors.allowed-origins` 파라미터를 고치고 apply |

## 검증 체크리스트

| # | 확인 | 기대 결과 |
|---|---|---|
| 1 | `dig NS easyselect.kr +short` | awsdns 4개 (위임 확인) |
| 2 | `dig api.easyselect.kr +short` | ALB IP 2개 |
| 3 | `curl -I http://api.easyselect.kr` | `301` (https 리다이렉트) |
| 4 | `curl -v https://api.easyselect.kr/actuator/health` | 인증서 유효. 앱 미배포 시 `502/503`이면 ALB→TG 배선은 정상 |
| 5 | EC2에서 DB 연결 (아래 명령) | `select 1` 성공 |
| 6 | 앱 배포 후 EC2 콘솔/CLI | 타깃 그룹 `healthy` |
| 7 | 브라우저 | Kakao/Google/Naver 로그인 라운드트립 |
| 8 | 갤러리에 사진 업로드 → `GET /photos/summary` | `uploaded` 수가 올라간다 (S3 CORS·서명 URL 확인) |
| 9 | `POST /embeddings/run` 후 잠시 뒤 같은 집계 | `embedded` 수가 올라간다 (Lambda·IAM 인증·S3 엔드포인트 확인) |

5번 DB 연결 확인 (EC2에서):

```bash
sudo apt-get install -y postgresql-client
DB_PASSWORD=$(aws ssm get-parameter --name /wes/prod/spring.datasource.password \
  --with-decryption --query Parameter.Value --output text --region ap-northeast-2)
PGPASSWORD="$DB_PASSWORD" psql -h <rds_address> -U wes_admin -d wes_db -c 'select 1;'
```

## 폐기

```bash
terraform destroy   # 앱 스택 (루트에서)
```

- 스냅샷 없이 전부 삭제된다(테스트 데이터 포함).
- 호스팅 존은 dns 스택 소유라 **그대로 남는다** — NS 재위임 없이 나중에 apply만 다시 하면 된다 (존 유지 비용 월 $0.50).
- 존까지 완전히 없애려면(프로젝트 종료 시에만):

  ```bash
  terraform -chdir=dns destroy
  ```
