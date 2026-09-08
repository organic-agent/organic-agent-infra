# WES 인프라 런북

OAuth(Kakao/Google/Naver) 로그인과 사진 갤러리(업로드·임베딩) 테스트를 위한 최소 사양 환경.
API 도메인 : `api.easyselect.kr` · 로그 조회 : `monitoring.easyselect.kr`

> **운영 설정 아님** — 백업/스냅샷/삭제 보호가 전부 꺼져 있고, 앱 스택은 `terraform destroy`로 언제든 폐기 가능하다.

---

## # 빠른 참조

| 하고 싶은 것 | 명령 / 위치 |
|---|---|
| 제로부터 전체 배포 | [deploy-order.md](deploy-order.md) (순서 요약) |
| 서버 쉘 접속 | `ssh wes` (설정은 [서버 접속](#-서버-접속-ssm)) |
| 앱 배포 | 서버 저장소 main 머지 시 CD 자동 (재배포는 Actions 수동 실행) → [앱 배포](#-앱-배포-cd-자동) |
| 인프라 배포 | PR → plan 댓글 확인 → main 머지 시 CD가 apply → [인프라 CI/CD](#-인프라-cicd-plan--apply). 최초 1회는 로컬 `terraform apply` → [배포](#-배포-2단계) |
| Lambda 셋 이미지 빌드·배포 | [AI 파이프라인](#-ai-파이프라인-embedder--score--categorize) |
| 임베딩·분석이 안 돌 때 | [AI 파이프라인 > 문제 해결](#-문제-해결) |
| 앱 로그 보기 | `https://monitoring.easyselect.kr` (Grafana → Explore) → [모니터링](#-모니터링-loki--grafana) |
| 로그가 안 들어올 때 | [모니터링 > 문제 해결](#-문제-해결-1) |
| 전부 정리 | `terraform destroy` (존은 남음) → [폐기](#-폐기) |
| DB 비밀번호 변경 | [사전 준비](#-사전-준비-최초-1회) 하단 참조 |

---

## # 아키텍처

```
Route53 존 easyselect.kr (dns/ 스택 소유, 공용)
  → api.easyselect.kr
  → ALB (ACM/HTTPS, 80→443 리다이렉트)
  → EC2 t4g.micro (Ubuntu 24.04 arm64, Docker + 스왑 2GB, Spring Boot 컨테이너 :8080, 퍼블릭 서브넷)
  → RDS PostgreSQL 16 db.t4g.micro (비공개, DB 서브넷, EC2·Lambda SG에서만 접근)

브라우저 ──서명 URL──→ S3 (wes-photos-*, 전면 비공개)
                          ↑ GET
앱 ──lambda:Invoke(EVENT)──→ 임베딩 Lambda (DB 서브넷, S3 게이트웨이 엔드포인트)
                          └─ RDS에 UPDATE photos SET embedding
                             (지금은 비밀번호 인증 — SCP가 IAM 인증을 막아 임시 전환, 아래 SCP 차단 참고)

앱 ──logback Loki appender (프라이빗 IP :3100)──→ 모니터링 EC2 t4g.micro (퍼블릭 서브넷, EIP)
                                                  ├─ Loki   (filesystem, 7일 보관)
                                                  ├─ Grafana (Loki 데이터소스 프로비저닝)
                                                  └─ Caddy  (Let's Encrypt TLS)
운영자 ──→ monitoring.easyselect.kr ──→ EIP 직결 (ALB 미경유) ──→ Caddy :443 ──→ Grafana
```

### # 스택 구조

| 스택 | 경로 | 담당 | destroy 시 |
|---|---|---|---|
| 앱 스택 | 저장소 루트 | VPC / ALB / EC2 / RDS / S3 / Lambda 셋 / VPC 엔드포인트 / 모니터링 EC2 | 전부 삭제 (테스트 데이터·로그 포함) |
| 존 스택 | `dns/` | Route53 호스팅 존 + NS 위임 | 앱 스택과 무관하게 유지 |

- state는 **S3 원격 백엔드**(`wes-tf-state-233927217926`, 암호화+버전닝+S3 네이티브 잠금)라서 AWS 자격증명만 있으면 누구든 plan/apply 할 수 있다 — 동시 apply는 잠금이 막는다.
- 설정값은 전부 `variables.tf` 기본값으로 커밋돼 있어 tfvars 파일이 필요 없다. 값을 바꿀 땐 기본값을 수정해 커밋한다.

### # 네트워크와 접속

- 보안그룹에 22번 포트 인바운드 규칙이 없으므로(`ssh_allowed_cidr` 기본값 `null` → 규칙 미생성) 서버 접속은 **SSM 경유가 기본**이다. 키페어(`wes-aws-key`)는 비상용으로 등록만 해둔다.
- NAT 게이트웨이 없음. EC2가 퍼블릭 IP로 OAuth 토큰 교환 아웃바운드를 직접 처리한다.
- EC2 퍼블릭 IP는 stop/start 시 바뀐다(EIP 없음). SSH 주소만 영향받고 redirect URI는 도메인 경유라 무관하다.
- 모니터링 EC2만 **EIP**를 쓴다. Let's Encrypt가 A 레코드로 찾아오는 대상이라 IP가 바뀌면 인증서 재발급과 DNS 전파를 기다려야 하기 때문이다. 80/443은 공개, **3100(Loki)은 앱 EC2 SG에서만** 열려 있고, SSH는 앱 서버와 같은 `ssh_allowed_cidr` 규칙을 따른다.

### # 설정 주입 (SSM 파라미터)

팀 컨벤션 `/wes/<환경>/<스프링 프로퍼티>`를 따른다. 이 환경은 `/wes/prod/`.

| 파라미터 | 생성 주체 | 비고 |
|---|---|---|
| `spring.datasource.url` | 테라폼 (apply 시 자동) | 비밀 아님 |
| `spring.datasource.username` | 테라폼 (apply 시 자동) | 비밀 아님 |
| `spring.datasource.password` | **수동 등록** (SecureString) | 테라폼은 ephemeral + write-only(`password_wo`)로 전달만 — **state에 비밀번호가 남지 않는다** |
| `app.storage.bucket` | 테라폼 (apply 시 자동) | 원본 사진 버킷 이름 |
| `app.analysis.embedder-function-name` | 테라폼 (apply 시 자동) | 임베딩 Lambda 이름 (wes V16부터 이 키. 옛 `app.embedding.function-name`은 #43에서 제거) |
| `app.analysis.gpu.enabled` | 테라폼 (변수 `gpu_score_enabled`) | GPU 워커 풀 스위치. 워커 풀(PR-3c) 전에는 `false` |
| `app.analysis.score-function-name` | 테라폼 (apply 시 자동) | 점수 Lambda 이름 (앱의 분석 오케스트레이터가 읽는다) |
| `app.analysis.categorize-function-name` | 테라폼 (apply 시 자동) | 카테고리 Lambda 이름 |
| `app.logging.loki-url` | 테라폼 (apply 시 자동) | Loki push URL(`http://<모니터링 프라이빗 IP>:3100/loki/api/v1/push`). 인스턴스가 재생성되면 값이 바뀌므로 앱 재시작 필요 |
| `cors.allowed-origins` | **수동 등록** (String) | apply의 **입력**이기도 하다 — 테라폼이 이 값을 읽어 S3 버킷 CORS에 그대로 쓴다 |

모니터링 서버는 **별도 프리픽스 `/wes/monitoring/`** 를 읽는다. 앱이 `/wes/prod/`를 통째로 읽으므로 Grafana 비밀번호를 거기 두면 앱 컨테이너에 노출되고, 반대로 모니터링 인스턴스 롤은 `/wes/prod/`를 읽을 수 없게 해 두었다(이 서버가 뚫려도 DB·OAuth 시크릿은 새지 않는다).

| 파라미터 (`/wes/monitoring/` 아래) | 생성 주체 | 비고 |
|---|---|---|
| `grafana.admin-password` | **수동 등록** (SecureString) | Grafana `admin` 초기 비밀번호. **최초 기동에만** 반영된다 — 이후 변경은 Grafana UI |

앱은 부팅 시 Spring Cloud AWS로 `/wes/prod/` 아래 파라미터를 직접 읽는다. EC2 인스턴스 프로파일에 이 경로 읽기 권한이 있으므로 앱용 자격증명/env var 주입이 필요 없고, 나중에 OAuth 클라이언트 시크릿 등을 `/wes/prod/`에 추가하면 앱이 바로 읽을 수 있다.

### # 비용

월 $55-60 수준 (ALB $17.5, RDS $21, EC2+EBS $8.5, 모니터링 EC2+EBS+EIP $12) + 존 $0.50.
테스트하지 않는 기간에는 앱 스택을 destroy 한다.

모니터링 비용을 더 줄이려면 `monitoring_instance_type`을 `t4g.nano`로 내릴 수 있지만(−$3),
512MiB에 Grafana+Loki를 같이 올리면 compactor가 돌 때 OOM이 잦다. 스왑이 받아주긴 해도 조회가 느려진다.

AI 파이프라인의 고정비는 **인터페이스 VPC 엔드포인트**가 거의 전부다. `lambda`·`bedrock-runtime` 둘을 두 AZ에 두면 ENI 넷 × 약 $0.0147/h ≈ 월 $43이고, `interface_endpoint_subnet_indexes = [0]`으로 한 AZ만 두면 절반이다. S3 게이트웨이 엔드포인트는 무료고 Lambda는 호출할 때만 과금되므로(embedder 3GB · score 8GB · categorize 3GB × 실행 시간), 그 밖에 늘어나는 것은 S3에 쌓이는 원본·미리보기, ECR의 이미지(embedder·score 각 3-5GB, 월 $1 수준), categorize의 Bedrock 호출(갤러리당 몇 번)이다.

---

## # 사전 준비 (최초 1회)

DB 마스터 비밀번호를 SSM에 등록한다 (RDS 금지 문자 `/ @ " 공백` 제외, 8자 이상):

```bash
aws ssm put-parameter --name /wes/prod/spring.datasource.password --type SecureString \
  --value "$(openssl rand -hex 24)" --region ap-northeast-2
```

Grafana admin 초기 비밀번호도 등록한다 (앱 프리픽스 밖, 이유는 [설정 주입](#-설정-주입-ssm-파라미터)):

```bash
aws ssm put-parameter --name /wes/monitoring/grafana.admin-password --type SecureString \
  --value "$(openssl rand -base64 24)" --region ap-northeast-2
```

둘 다 이미 등록돼 있으면 생략.

> **비밀번호를 바꿀 때는** `put-parameter --overwrite` 후 `variables.tf`의 `db_password_version` 기본값을 1 올려 **커밋**하고 apply해야 RDS에 반영된다. (커밋해야 다른 협업자의 plan과 어긋나지 않는다.)

---

## # 배포 (2단계)

ACM 인증서의 DNS 검증은 easyselect.kr의 네임서버가 Route53 존으로 위임된 뒤에만 완료되므로, **위임 전에 앱 스택을 apply하면** `aws_acm_certificate_validation`에서 대기하다 타임아웃(75분)된다.

### # 1단계 (dns 스택 apply, NS 위임)

```bash
terraform -chdir=dns init
terraform -chdir=dns apply
terraform -chdir=dns output name_servers
```

출력된 NS 4개(`ns-xxx.awsdns-xx...`)를 easyselect.kr 등록기관(가비아/후이즈 등)의 **네임서버 설정**에 입력한다.

전파 확인 (몇 분에서 몇 시간):

```bash
dig NS easyselect.kr +short   # awsdns 4개가 보이면 위임 완료
```

### # 2단계 (앱 스택 apply)

저장소 루트에서:

```bash
terraform init
terraform apply   # 약 60개 리소스, ACM 검증 포함 5-15분
terraform output
```

---

## # 인프라 CI/CD (plan / apply)

| 이벤트 | 워크플로우 | 롤 | 하는 일 |
|---|---|---|---|
| PR → main | `terraform-plan.yml` | `wes-tf-plan-*` (ReadOnlyAccess + SecureString 복호화) | 바뀐 스택(app / dns)에 `fmt -check`·`validate`·`plan`. 요약(`Plan: N to add…` + 교체·삭제 대상)을 PR 댓글로, 전체 plan은 아티팩트로 |
| main 푸시 | `terraform-apply.yml` | `wes-tf-apply-*` (PowerUserAccess + `wes-*` IAM 쓰기) | 바뀐 스택에 `apply -auto-approve`. dns가 바뀌었으면 dns → app 순서 |
| 수동 (`workflow_dispatch`) | `terraform-apply.yml` | 〃 | 스택을 골라 강제 apply (경로 감지 무시) — drift 복구용 |

**승인은 PR 머지다.** 댓글의 plan 요약에 교체·삭제가 있으면 머지 전에 아티팩트로 전체 plan을 읽는다.
둘 다 `modules/github-actions`의 롤을 OIDC로 assume 하며 장기 키가 없다. plan 롤은 state 잠금 파일도 못 쓰므로 `-lock=false`로 돈다(plan은 state를 쓰지 않아 안전).
`destroy`는 워크플로우에 없다 — 항상 로컬에서 수동.

### # 최초 1회 — 롤 ARN을 시크릿에

롤은 이 스택이 만들므로 **첫 apply는 로컬**이어야 한다. 그 뒤:

```bash
gh secret set AWS_PLAN_ROLE_ARN  --body "$(terraform output -raw github_tf_plan_role_arn)"
gh secret set AWS_APPLY_ROLE_ARN --body "$(terraform output -raw github_tf_apply_role_arn)"
```

`modules/github-actions`(롤 자체)를 고칠 때도 같은 이유로 로컬 apply다 — CD가 자기 롤의 권한을 바꾸지 못하게 IAM 쓰기를 `wes-*`로 묶어 두긴 했지만, 롤 정의가 깨지면 CD가 스스로를 못 고친다.

apply 잡은 `production` 환경에 묶여 있다. GitHub **Settings → Environments → production**에 Required reviewers를 걸면 머지 뒤 한 번 더 사람이 눌러야 apply가 돈다(지금은 비어 있어 바로 돈다).
따라서 apply 역할의 exact `sub`는 `repo:organic-agent/organic-agent-infra:environment:production`이다.
이 저장소와 Server는 이름 기반 기본 `sub`를 쓰지만, IAM은 `repository_owner_id=299031009`,
각 `repository_id`, `ref=refs/heads/main`, apply의 `environment=production`까지 함께 검사한다.
저장소 이름이 재사용돼도 ID가 다른 주체는 assume할 수 없다.

### # 문제 해결

| 증상 | 원인 |
|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | 시크릿의 ARN이 낡았거나 token context가 다르다. plan은 `pull_request`, apply는 `environment:production` sub와 `ref:refs/heads/main`을 모두 요구한다 — 다른 브랜치 dispatch는 거절 |
| plan에서 `AccessDeniedException ... kms:Decrypt` | plan 롤의 `plan-extra` 정책 확인 — database 모듈의 ephemeral SecureString 읽기 |
| apply에서 `iam:... AccessDenied` | 새 IAM 리소스 이름이 `wes-`로 시작하지 않거나, 목록에 없는 iam 액션 — `modules/github-actions`의 `IamWritePrefixedOnly` 갱신(로컬 apply) |
| apply가 `Error acquiring the state lock` | 다른 apply(로컬 포함)가 도는 중. 끝나길 기다렸다가 Actions에서 Re-run |
| PR에 plan 댓글이 안 달린다 | `.tf`·`modules/**`·`dns/**` 밖만 바뀐 PR(문서 등)은 plan을 건너뛴다 — 정상 |

---

## # OAuth 콘솔 등록

`terraform output oauth_redirect_uris` 값을 각 콘솔에 등록:

| 제공자 | 콘솔 | redirect URI |
|---|---|---|
| Kakao | developers.kakao.com | `https://api.easyselect.kr/login/oauth2/code/kakao` |
| Google | console.cloud.google.com | `https://api.easyselect.kr/login/oauth2/code/google` |
| Naver | developers.naver.com | `https://api.easyselect.kr/login/oauth2/code/naver` |

(Spring Security 기본 패턴 `/login/oauth2/code/{registrationId}` 기준. 백엔드가 커스텀 경로를 쓰면 그에 맞게 수정.)

---

## # 서버 접속 (SSM)

보안그룹에 SSH 인바운드 규칙이 없고, 접근 제어는 IAM으로 한다.
AWS 자격증명이 있는 팀원은 아래 설정만 하면 각자 접속 가능.

### # 쉘만 필요할 때

키·플러그인 설정이 필요 없다:

```bash
aws ssm start-session --region ap-northeast-2 \
  --target $(aws ec2 describe-instances --region ap-northeast-2 \
    --filters 'Name=tag:Name,Values=wes-app' 'Name=instance-state-name,Values=running' \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)
```

### # scp와 ssh 설정 (최초 1회)

팀원 각자 로컬에서 설정한다.

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

   # 모니터링 서버 — 같은 키, Name 태그만 다르다
   Host wes-monitoring
     User ubuntu
     IdentityFile ~/.ssh/wes-aws-key
     ProxyCommand sh -c "aws ssm start-session --region ap-northeast-2 --target $(aws ec2 describe-instances --region ap-northeast-2 --filters 'Name=tag:Name,Values=wes-monitoring' 'Name=instance-state-name,Values=running' --query 'Reservations[0].Instances[0].InstanceId' --output text) --document-name AWS-StartSSHSession --parameters 'portNumber=%p'"

   # 인스턴스 ID 직접 지정: ssh i-xxxxxxxx
   Host i-* mi-*
     User ubuntu
     IdentityFile ~/.ssh/wes-aws-key
     ProxyCommand aws ssm start-session --region ap-northeast-2 --target %h --document-name AWS-StartSSHSession --parameters 'portNumber=%p'
   ```

이후 `ssh wes`, `ssh wes-monitoring`, `scp app.jar wes:~/`, `rsync` 전부 평소처럼 동작한다.

> 인스턴스를 재생성하면 호스트 키가 바뀐다. 경고가 뜨면 `ssh-keygen -R wes` 후 재접속.

### # 비상용 직접 SSH

SSM 장애 등으로 직접 접속이 필요할 때만:

```bash
terraform apply -var="ssh_allowed_cidr=$(curl -s ifconfig.me)/32"   # 내 IP만 22번 오픈
ssh -i ~/.ssh/wes-aws-key ubuntu@$(terraform output -raw ec2_public_ip)
terraform apply                                                     # 작업 후 규칙 제거
```

---

## # 앱 배포 (CD 자동)

서버 저장소(WES-Server)의 CD가 main 머지 시 GHCR에 arm64 이미지를 올리고,
**GitHub OIDC → `wes-deploy-*` 롤 → SSM Run Command**로 EC2에서 `docker compose pull && up`을 실행한다.
SSH 키·호스트 IP·22번 포트가 전혀 필요 없다. 같은 이미지 재배포는 Actions의 `workflow_dispatch` 수동 실행.

### # 최초 1회 — 서버 저장소에 배포 롤 연결

```bash
terraform output -raw github_deploy_role_arn
terraform output -raw github_admin_api_deploy_role_arn
```

두 값을 서버 저장소의 Actions 시크릿 `AWS_DEPLOY_ROLE_ARN`, `AWS_ADMIN_API_DEPLOY_ROLE_ARN`에
각각 등록한다. (비밀은 아니지만 저장소 밖 값이라 시크릿으로 관리)

Lambda 셋의 배포 역할은 서버가 아니라 **AI 저장소**가 쓴다 — `deploy-lambda.yml`이 읽는 변수(vars)에 넣는다:

```bash
gh variable set AWS_LAMBDA_DEPLOY_ROLE_ARN --repo organic-agent/organic-agent-ai \
  --body "$(terraform output -raw github_worker_deploy_role_arn)"
```

> 롤의 신뢰 조건은 각 저장소의 **main 브랜치**로 제한돼 있다 (서버 롤 둘은 `organic-agent-server`,
> worker 롤은 `organic-agent-ai`). 이름뿐 아니라 immutable repository/owner ID도 정확히 검사한다. 저장소를 이전하면 이름과 ID를
> 함께 검토하고 의도적인 IAM/GitHub OIDC 전환 순서로 적용한다.

수동 점검이 필요하면 `ssh wes` 후 `docker ps`, `docker logs wes-app`, 컨테이너 교체는 `/opt/wes-prod`에서 `docker compose` 명령으로 한다.

앱이 Spring Cloud AWS로 `/wes/prod/` 파라미터를 직접 읽으므로 DB env var 주입은 필요 없다.
OAuth 클라이언트 ID/시크릿도 `/wes/prod/` 아래 SecureString 파라미터로 등록하면 앱이 같은 방식으로 읽는다 — 인프라/저장소에 커밋하지 않는다.

---

## # AI 파이프라인 (embedder → score → categorize)

작가가 갤러리에 원본을 올리고 "AI 분석"을 누르면 Lambda 셋이 차례로 돈다. 코드는 AI 저장소(`organic-agent-ai`)의 최상위 디렉토리 하나 = 함수 하나(`embedder/` · `score/` · `categorize/`)다.

```
프론트 ──서명 PUT──→ S3          (앱은 목적지만 정해주고 바이트는 거치지 않는다)
프론트 ──POST /photos/complete──→ 앱   (status: PENDING → UPLOADED)
프론트 ──"AI 분석"──→ 앱(분석 오케스트레이터) ──EVENT──→ [wes-embedder]   S3 GET(원본) → 미리보기 PUT → DINOv3 → photo_analysis.embedding
                                             ──EVENT──→ [wes-score]      S3 GET(미리보기) → CLIP·ARNIQA·LAION → photo_analysis 점수
                                                            └──EVENT(체인)──→ [wes-categorize]  그룹 묶기 → Bedrock(이름) → ai_concept_assignments, 잡 DONE
진행 상황: ai_analysis_jobs (앱이 30초마다 스윕)
```

- **갤러리 단위로 한 번 부른다.** S3 이벤트로 장당 트리거를 걸면 수천 장 업로드가 Lambda 수천 개를 동시에 띄우고, 각자 커넥션을 열어 db.t4g.micro를 고갈시킨다.
- **응답을 기다리지 않는다(EVENT).** 갤러리 하나가 Lambda 상한인 15분까지 걸릴 수 있다. embedder·score는 15분 앞에서 배치 경계에 멈추고 **자기 자신을 다시 부른다** — 그래서 실행 롤에 자기 함수의 `lambda:InvokeFunction`이 있다.
- **embedder·score는 갤러리를 샤드로 나눠 동시에 돈다.** wes가 부른 실행은 조정자가 되어 사진 150장당 샤드 하나(최대 32)로 자기 함수를 다시 EVENT 하고 끝난다. 샤드는 자기 몫만 처리한다. embedder 샤드는 각자 끝나면 그만이고(앱이 `photo_analysis`를 세어 단계를 닫는다), score는 마지막으로 끝난 샤드가 `wes-categorize`를 부른다. 그래서 두 함수의 예약 동시성은 샤드 상한(32) 이상이어야 한다 — 낮으면 샤드가 스로틀되어 라운드가 늘어난다. 샤드 상한은 RDS 커넥션이 정한다(샤드당 1개를 세션 advisory lock 으로 끝까지 붙든다 — db.t4g.micro 79 개 중 평상시 24 + 샤드 32).
- **재실행이 안전하다.** embedder는 `embedding IS NULL`, score는 `MODEL_VERSION` + CLIP 유무로 남은 것만 이어서 한다.
- **재시도 주체는 앱의 오케스트레이터 하나다.** Lambda 서비스 재시도는 셋 다 0회이며, 이벤트 수명은 20분(15분 runtime 상한 + 최대 5분 queue 지연)이다. 오래 적체된 이벤트를 뒤늦게 중복 실행하지 않는다.
- **DB 서브넷은 인터넷이 없다.** S3는 게이트웨이 엔드포인트, Lambda API(재호출·체인)와 Bedrock(categorize의 이름 짓기)은 `lambda`·`bedrock-runtime` **인터페이스 엔드포인트**로 나간다. 인터페이스 엔드포인트는 ENI당 시간 과금이다([비용](#-비용)).
- **categorize의 대표 사진은 국외로 나간다.** 서울 온디맨드에 Sonnet이 없어 `global.` 크로스 리전 프로필(`bedrock_model_id`)을 쓴다.

| 함수 | 메모리 | /tmp | 동시 실행 | DB 사용자 | 특이 권한 |
|---|---|---|---|---|---|
| `wes-embedder` | 3GB | 512MB | 32 (= 샤드 상한) | `embedder` | S3 원본 읽기·`previews/` 쓰기, 자기 재호출(샤드 fan-out) |
| `wes-score` | 8GB | 10GB (미리보기 전부 내려받음) | 32 (= 샤드 상한) | `photoselect` | S3 `previews/` 읽기, 자기 재호출(샤드 fan-out), `wes-categorize` 호출 |
| `wes-categorize` | 3GB | 512MB | 2 | `photoselect` | S3 `previews/` 읽기, `bedrock:InvokeModel`(프로필 + 기반 모델) |

### # DB 접속 (설계와 현재 상태)

원래 설계는 **RDS IAM 인증**이었다. Lambda는 NAT도 없는 DB 서브넷에 있어서 Parameter Store를 읽을 수 없고, 비밀번호를 환경변수로 주입하면 이 스택이 지켜 온 "비밀번호는 state에 남기지 않는다"가 깨진다. 토큰 생성은 네트워크를 타지 않는 로컬 서명이라 둘 다 피할 수 있었다.

**지금은 쓰지 못한다.** 조직 SCP가 이 계정 전체에서 `rds-db:connect`를 거부한다. 계정 `233927217926`은 조직의 멤버 계정이라 여기서는 풀 수 없다 ( SCP는 관리 계정에는 적용되지 않으므로, 관리자인데도 막힌다는 것이 곧 멤버 계정이라는 증거다 ). 그래서 접속은 임시로 비밀번호를 쓴다 — 함수 셋 모두. 판별법과 원복 절차는 아래 [SCP 차단](#-scp-차단-임시-우회로) 참고.

수동 작업은 **두 가지**다. 둘 다 Terraform이 할 수 없는 일이고, 하나라도 빠지면 함수가 접속 단계에서 실패한다.

#### # 1. DB 사용자 (DB를 새로 만들 때마다)

SQL이라 Terraform이 만들지 못한다. 없으면 `password authentication failed`로 실패한다 ( 로그 DETAIL에 `Role "embedder" does not exist`가 함께 찍힌다 ). 사용자는 둘이다 — `embedder`(임베더)와 `photoselect`(score·categorize).

```bash
# 테이블은 앱이 처음 뜰 때 Flyway가 만든다. 그 뒤에 실행할 것.
ssh wes
sudo apt-get install -y postgresql-client
DB_PASSWORD=$(aws ssm get-parameter --name /wes/prod/spring.datasource.password \
  --with-decryption --query Parameter.Value --output text --region ap-northeast-2)
PGPASSWORD="$DB_PASSWORD" psql -h <rds_address> -U wes_admin -d wes_db
```

`<rds_address>`는 `terraform output -raw rds_endpoint`에서 `:5432`를 뗀 값이다.

```sql
-- 마스터와 다른 값을 쓴다. 각각 /wes/prod/embedder.db.password, /wes/prod/photoselect.db.password 에 등록한 값과 같아야 한다.
CREATE USER embedder    WITH PASSWORD '<embedder 전용 비밀번호>';
CREATE USER photoselect WITH PASSWORD '<photoselect 전용 비밀번호>';

-- 이 DB는 public 스키마의 PUBLIC USAGE가 회수돼 있어 role마다 따로 준다. 없으면 테이블은커녕
-- `vector` 타입도 못 봐서 접속 직후 `vector type not found in the database`(pgvector register)로 죽는다.
GRANT USAGE ON SCHEMA public TO embedder, photoselect;

-- SCP 우회로를 쓰는 동안에는 rds_iam을 주지 않는다 (아래 설명). 이미 준 상태라면:
REVOKE rds_iam FROM embedder;
```

**역할별 커넥션 상한** — 사용자를 만든 직후, 그리고 DB를 새로 만들 때마다 같이 건다. 분석 파이프라인
(Lambda 샤드·GPU 워커)이 한꺼번에 붙어도 앱 사용자의 커넥션을 뺏지 못하게 하는 울타리다. 상한의 목적은
"한 역할이 다른 역할 몫을 못 뺏게" 하는 것이라 합계(80)가 db.t4g.micro의 `max_connections`(79)를 넘는 것은
의도된 값이다 — 셋이 동시에 다 차는 경우는 없다. `ALTER ROLE`은 무중단이고 이미 열린 커넥션은 끊지 않는다.

```sql
ALTER ROLE embedder    CONNECTION LIMIT 32;   -- embedder Lambda 예약 동시성과 같은 값 (샤드당 커넥션 1)
ALTER ROLE photoselect CONNECTION LIMIT  8;   -- score·categorize Lambda + GPU 워커 2대
ALTER ROLE wes_admin   CONNECTION LIMIT 40;   -- 앱(마스터). Hikari 풀 + Flyway + 이 psql 세션이 여기 든다
-- 확인
SELECT rolname, rolconnlimit FROM pg_roles WHERE rolname IN ('embedder','photoselect','wes_admin');
```

관리자 API 계정(`wes_admin_api`)의 상한은 서버 저장소가 정한다. embedder 예약 동시성을 올리면(`embedder_reserved_concurrent_executions`)
이 값도 같이 올린다 — 낮으면 샤드가 `FATAL: too many connections for role "embedder"`로 죽는다. 상한을 풀려면 `CONNECTION LIMIT -1`.
값의 근거와 RDS 클래스 결정 시점은 [분석 파이프라인 v2 인프라 계획](pipeline-v2-infra-plan.md) 결정 D·E.

테이블별 GRANT의 원본은 서버 저장소 Flyway 베이스라인(`V1__baseline.sql`의 `EMBEDDER_GRANT_CONTRACT` ·
`PHOTOSELECT_GRANT_CONTRACT`)이다. 그 블록은 **마이그레이션이 도는 시점에 role이 있을 때만** 건다 —
V1이 이미 돈 DB에 사용자를 뒤늦게 만들면 앱을 재배포해도 V1은 다시 돌지 않으므로 **직접 건다**.
photoselect용은 아래를 psql에 넣는다(없는 테이블은 건너뛴다). embedder는 V1 블록의 컬럼 목록을 같은 식으로 옮긴다.

```sql
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['galleries','photos','photo_analysis','concept_folders','detail_folders',
      'photo_category_assignments','photo_selections','photo_selection_items','ai_analysis_jobs',
      'ai_concept_assignments','ai_selection_jobs','ai_recommendations','ai_pair_verdicts'] LOOP
    IF to_regclass('public.' || t) IS NOT NULL THEN EXECUTE format('GRANT SELECT ON public.%I TO photoselect', t); END IF;
  END LOOP;
  FOREACH t IN ARRAY ARRAY['photo_analysis','ai_concept_assignments','ai_recommendations','ai_pair_verdicts'] LOOP
    IF to_regclass('public.' || t) IS NOT NULL THEN EXECUTE format('GRANT INSERT, UPDATE ON public.%I TO photoselect', t); END IF;
  END LOOP;
  FOREACH t IN ARRAY ARRAY['ai_analysis_jobs','ai_selection_jobs'] LOOP
    IF to_regclass('public.' || t) IS NOT NULL THEN EXECUTE format('GRANT UPDATE ON public.%I TO photoselect', t); END IF;
  END LOOP;
END $$;
-- 확인
SELECT table_name, string_agg(privilege_type, ',') FROM information_schema.table_privileges
 WHERE grantee = 'photoselect' GROUP BY 1 ORDER BY 1;
```

서버 저장소의 GRANT 계약이 바뀌면(새 테이블 등) 그 마이그레이션도 role 유무를 보고 걸므로, 그때는 자동으로 따라온다.

> 로컬에 psql이 없으면 `wes-app` 인스턴스에 SSM Run Command(`AWS-RunShellScript`)로 보낸다 — 인스턴스 롤이
> `/wes/prod/*`를 읽을 수 있어 마스터 비밀번호를 노트북으로 가져올 필요가 없다. `-c`는 psql 변수를 치환하지
> 않으므로 `CREATE USER … PASSWORD :'pw'`는 stdin이나 `-f`로 넣고 `-v pw=…`로 값을 준다.

> **`rds_iam`과 비밀번호 인증은 동시에 쓸 수 없다.** pg_hba는 선착순 매칭인데, RDS가 넣어
> 두는 규칙 순서가 이렇다:
>
> | line | type | user | method |
> |---|---|---|---|
> | 13 | hostssl | `+rds_iam` | pam |
> | 14 | host | `+rds_iam` | reject |
> | 15 | hostssl | all | md5 |
>
> `rds_iam` 멤버는 13번에서 잡혀 15번까지 가지 못하므로 **우회로를 쓰는 동안에는
> `REVOKE rds_iam FROM embedder;`가 필요하다.** SCP가 풀리면 다시 GRANT 한다.
>
> 직접 확인: `select line_number, type, user_name, auth_method from pg_hba_file_rules order by line_number;`

> 마스터 계정(`wes_admin`)에 `rds_iam`을 주는 것으로 대신할 수 없다. RDS가 마스터 사용자에
> 대해서는 그 역할 부여를 거부한다.

#### # 2. 비밀번호 주입 (함수를 새로 만들 때마다)

`DB_PASSWORD`는 Terraform이 넣으면 state에 평문으로 남으므로 apply 밖에서 한 번 주입하고, `modules/analysis`의 `ignore_changes`가 이후 apply에서 그 키를 지켜 준다.

`update-function-configuration --environment`는 **환경변수 맵 전체를 덮어쓴다.** 값 하나만 넘기면 `DB_HOST` 이하가 전부 사라지므로, 반드시 기존 맵을 읽어 병합해야 한다. 함수 셋을 한 번에:

```bash
REGION=ap-northeast-2

inject() {  # inject <함수> <SSM 파라미터>
  local fn=$1 param=$2
  local pw merged
  pw=$(aws ssm get-parameter --region "$REGION" --name "$param" \
    --with-decryption --query Parameter.Value --output text)
  merged=$(aws lambda get-function-configuration --region "$REGION" --function-name "$fn" \
    --query 'Environment.Variables' --output json | jq --arg pw "$pw" '. + {DB_PASSWORD: $pw}')
  aws lambda update-function-configuration --region "$REGION" --function-name "$fn" \
    --environment "$(jq -n --argjson v "$merged" '{Variables: $v}')" --no-cli-pager --output text --query LastUpdateStatus
  aws lambda wait function-updated --region "$REGION" --function-name "$fn"
}

inject wes-embedder   /wes/prod/embedder.db.password
inject wes-score      /wes/prod/photoselect.db.password
inject wes-categorize /wes/prod/photoselect.db.password
```

확인 (값 자체는 찍지 않는다):

```bash
for fn in wes-embedder wes-score wes-categorize; do
  aws lambda get-function-configuration --region ap-northeast-2 --function-name "$fn" \
    --query 'Environment.Variables | keys' --output json
done
```

> apply 뒤에는 이 키가 살아남았는지 한 번 확인할 것. `ignore_changes`가 지켜 주지만,
> 함수가 **재생성**되면(태그·이름 변경 등) 새 함수에는 없으므로 다시 주입해야 한다.

### # SCP 차단 (임시 우회로)

`PAM authentication failed`인데 DB 사용자와 `GRANT rds_iam`이 멀쩡하다면 SCP를 의심한다.
RDS 에러 로그에는 `pam_authenticate failed: Permission denied`로 찍힌다.

판별은 IAM 정책 시뮬레이터로 한다. **`MatchedStatements`가 비어 있는데 `explicitDeny`**이면 이 계정 안의 어떤 정책도 거부하지 않았다는 뜻이므로, 거부는 조직 SCP에서 온 것이다:

```bash
aws iam simulate-principal-policy \
  --policy-source-arn "$(terraform output -json lambda_role_arns | jq -r '.embedder')" \
  --action-names rds-db:connect \
  --resource-arns "arn:aws:rds-db:ap-northeast-2:233927217926:dbuser:$(terraform output -raw db_resource_id)/embedder" \
  --query 'EvaluationResults[].{D:EvalDecision,Org:OrganizationsDecisionDetail.AllowedByOrganizations}'
```

`Org: false`면 SCP다. 대조군으로 `s3:GetObject`를 같이 돌려 보면 `true`가 나온다.

**원복 (관리 계정에서 SCP를 푼 뒤):**

1. 위 시뮬레이션이 `allowed`로 바뀌는지 확인
2. `psql`에서 `GRANT rds_iam TO embedder;` `GRANT rds_iam TO photoselect;` (우회로를 쓰며 REVOKE 했다면)
3. AI 저장소 세 모듈의 `db.py`를 `generate_db_auth_token` 방식으로 되돌리고 이미지 재배포. score·categorize 실행 롤에는 `rds-db:connect` 문장이 아직 없으므로 `modules/analysis`의 embedder 정책과 같은 문장을 추가
4. Lambda 환경변수에서 `DB_PASSWORD` 제거, `modules/analysis`의 `ignore_changes`에서 해당 줄 제거
5. **마스터 비밀번호 교체** — state 버킷은 버저닝이 켜져 있어 우회로를 쓰는 동안의 값이 과거 버전에 남는다. 절차는 [사전 준비](#-사전-준비-최초-1회) 하단

### # 이미지 빌드와 배포

첫 apply 순서(리포지토리 셋 → 푸시 → 전체 apply)는
[deploy-order.md의 [3]](deploy-order.md#-3-lambda-셋-이미지-스택-세울-때마다)에 있다.
코드만 바뀐 뒤의 재배포는 apply 없이 AI 저장소의 모듈별 `deploy.sh`로 한다 — 빌드·푸시·
`update-function-code`·다이제스트 검증까지 한 스크립트가 하고, 운영 CD(`deploy-lambda.yml`)도
같은 스크립트를 돌린다:

```bash
cd ../organic-agent-ai
embedder/deploy.sh     # HF_TOKEN 또는 `hf auth login` 필요 (DINOv3 게이트 모델)
score/deploy.sh
categorize/deploy.sh
```

함수의 `image_uri`는 `ignore_changes`라 이렇게 밀어 넣어도 다음 plan이 되돌리지 않는다.
운영 CD에서는 AI 저장소 main만 신뢰하는 worker 역할(`AWS_LAMBDA_DEPLOY_ROLE_ARN` 변수)이
세 ECR repository와 세 Lambda를 갱신한다. 공개/관리자 EC2 배포 역할에는 ECR·Lambda 쓰기 권한이 없다.

### # 수동 실행

```bash
# 임베딩만
aws lambda invoke --region ap-northeast-2 --function-name wes-embedder \
  --cli-binary-format raw-in-base64-out \
  --payload '{"galleryId":1,"force":false}' /dev/stdout

# 점수 → (체인) 카테고리. jobId 없이 부르면 잡 계약 밖의 적재만 하고 체인은 타지 않는다.
aws lambda invoke --region ap-northeast-2 --function-name wes-score \
  --cli-binary-format raw-in-base64-out \
  --payload '{"galleryId":1}' /dev/stdout
```

로그 : `aws logs tail /aws/lambda/wes-embedder --follow` (`wes-score` · `wes-categorize`도 같은 경로)

### # 문제 해결

| 증상 | 원인 |
|---|---|
| `password authentication failed for user "embedder"` / `"photoselect"` | DB 사용자가 없다. RDS 에러 로그 DETAIL에 `Role "…" does not exist`가 함께 찍힌다 |
| `vector type not found in the database` (접속 직후, pgvector register) | role에 `public` 스키마 USAGE가 없다 — `GRANT USAGE ON SCHEMA public TO <role>;` |
| `permission denied for table photo_analysis` (photoselect) | 사용자는 있는데 GRANT가 없다 — V1이 role보다 먼저 돌았다. 위 "DB 사용자"의 GRANT 블록을 직접 실행 |
| `FATAL: too many connections for role "embedder"` (또는 `photoselect`) | 역할별 `CONNECTION LIMIT`에 걸렸다. 예약 동시성을 올렸는데 상한을 같이 올리지 않았거나, 죽은 세션이 남아 있다 — `pg_stat_activity`로 확인 뒤 상한 조정 |
| `PAM authentication failed` + DB 사용자·GRANT 정상 | 조직 SCP가 `rds-db:connect`를 막고 있다 → [SCP 차단](#-scp-차단-임시-우회로) |
| `PAM authentication failed` + 비밀번호로 붙는 중 | 사용자가 아직 `rds_iam` 멤버다. pg_hba가 PAM 경로로 보내 비밀번호를 아예 안 본다 — `REVOKE rds_iam FROM …;` |
| 접속 성공하다가 apply 후 갑자기 실패 | apply가 `DB_PASSWORD` 환경변수를 지웠다. 함수가 재생성되면 `ignore_changes`도 못 지킨다 — 다시 주입 |
| S3 GET에서 타임아웃 (자격증명 오류처럼 보이지 않는다) | DB 서브넷의 S3 게이트웨이 엔드포인트가 없다 |
| `reinvoked=false` / `chained=false`, 로그에 `Connect timeout on endpoint URL: "https://lambda…"` | `lambda` 인터페이스 엔드포인트가 없거나 아직 `pending`이다. 잡은 score가 FAILED로 닫는다 — 엔드포인트가 `available`이 된 뒤 앱에서 다시 분석 |
| 재호출·체인이 `AccessDeniedException` | 실행 롤의 `lambda:InvokeFunction` 대상(자기 함수·categorize) 확인 |
| categorize 로그에 `Connect timeout on endpoint URL: "https://bedrock-runtime…"` | `bedrock-runtime` 인터페이스 엔드포인트가 없다 |
| categorize가 Bedrock `AccessDeniedException` | 프로필 ARN과 기반 모델 ARN **둘 다** `bedrock:InvokeModel`이 있어야 한다. `bedrock_model_id`와 `BEDROCK_MODEL_ID`가 같은지, 프로필이 리전에 있는지(`aws bedrock list-inference-profiles`) 확인 |
| score가 `[Errno 28] No space left on device` | `/tmp`가 찼다. 갤러리 미리보기 전부를 내려받으므로 `score_ephemeral_storage_mb`를 올린다 |
| 호출은 되는데 핸들러 로그가 없다 | VPC 함수의 ENI를 못 만들었다 — 롤에 `AWSLambdaVPCAccessExecutionRole` 확인 |
| `InvalidParameterValueException: image manifest ... not supported` | buildx가 manifest list를 만들었다 — `--provenance=false --sbom=false` 빠짐 |
| 앱이 `PHOTO_503_1`로 답한다 | `app.analysis.embedder-function-name` 파라미터가 없다 (apply가 만든다) |
| 앱이 분석 요청에 503으로 답한다 | `app.analysis.score-function-name`·`categorize-function-name` 파라미터가 없다 (apply가 만든다) |
| 앱이 `PHOTO_502_1` / 분석 dispatch가 거절된다 | 호출 자체가 거절됐다 — 인스턴스 롤의 `lambda:InvokeFunction`(함수 셋) 확인 |
| 업로드가 브라우저 프리플라이트에서 죽는다 | S3 버킷 CORS의 오리진 — `cors.allowed-origins` 파라미터를 고치고 apply |

### # 파이프라인 v2 준비 (Phase 0 수동 작업)

[분석 파이프라인 v2 인프라 계획](pipeline-v2-infra-plan.md)의 Phase 0. 셋 다 Terraform 밖의 작업이고 다운타임이 없다.
전체 순서와 근거는 계획 문서 §5, 이후 Phase(GPU AMI 파이프라인·워커 풀)는 §3 PR 순서를 따른다.

**1. 역할별 커넥션 상한** — 위 [DB 사용자](#-1-db-사용자-db를-새로-만들-때마다)의 `ALTER ROLE … CONNECTION LIMIT` 3건.

**2. GPU 벤치마크 IAM 정리** — 2026-09-07 GPU·SageMaker 벤치마크가 콘솔/CLI로 만든 롤 두 개가 남아 있다.
Terraform 밖 리소스라 `plan`에 나오지 않는다. SageMaker는 운영에서 쓰지 않는 것으로 확정됐다.
삭제 전 `RoleLastUsed`가 벤치마크 날짜(09-07)인지 확인한다.

```bash
export AWS_PAGER=""
for r in wes-gpu-benchmark wes-sagemaker-benchmark; do
  aws iam get-role --role-name "$r" --query 'Role.[RoleName,RoleLastUsed.LastUsedDate]' --output text
done

# wes-gpu-benchmark: 인스턴스 프로파일 → 인라인 정책 → 관리형 정책 → 롤 순서 (역순이면 DeleteConflict)
aws iam remove-role-from-instance-profile --instance-profile-name wes-gpu-benchmark --role-name wes-gpu-benchmark
aws iam delete-instance-profile --instance-profile-name wes-gpu-benchmark
aws iam delete-role-policy --role-name wes-gpu-benchmark --policy-name benchmark
aws iam detach-role-policy --role-name wes-gpu-benchmark --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam delete-role --role-name wes-gpu-benchmark

# wes-sagemaker-benchmark: 인라인 정책 → 롤
aws iam delete-role-policy --role-name wes-sagemaker-benchmark --policy-name benchmark
aws iam delete-role --role-name wes-sagemaker-benchmark
```

벤치마크가 ECR `wes-score`에 남긴 `gpu` 태그(AI 저장소 main #70 빌드, 4.2GB)는 **지우지 않는다** — GPU 워커 풀이 부팅 시 pull 하는 이동 태그로 그대로 쓴다.

**3. EC2 G 인스턴스 쿼터 8 → 12** — g6.xlarge는 4 vCPU라 지금 쿼터(8)로는 워커 2대가 상한이고, AMI 빌드 인스턴스(g6.xlarge)가
겹치면 쿼터 초과로 빌드가 실패한다. 인스턴스 대수는 2대 그대로라 비용은 변하지 않는다. 승인은 보통 1~2일.

```bash
aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA --region ap-northeast-2 \
  --query 'Quota.[QuotaName,Value]' --output text
aws service-quotas request-service-quota-increase --service-code ec2 --quota-code L-DB2E81BA \
  --desired-value 12 --region ap-northeast-2
aws service-quotas list-requested-service-quota-change-history-by-quota --service-code ec2 \
  --quota-code L-DB2E81BA --region ap-northeast-2 --query 'RequestedQuotas[].[Status,DesiredValue,Created]' --output text
```

### # GPU AMI (score 워커, Image Builder)

[계획](pipeline-v2-infra-plan.md) §4.1의 AMI 파이프라인(`modules/score-gpu`, PR-3b). AMI에는 NVIDIA 드라이버(브랜치 고정) ·
Docker · nvidia-container-toolkit · `wes-score` systemd 유닛만 굽는다. 코드 이미지는 워커가 부팅 때 ECR `wes-score:gpu`
(이동 태그)를 pull 하고, DB 주소·비밀번호·버킷은 기동 때 `/wes/prod/` 파라미터 세 개에서 읽는다 — 코드나 RDS가 바뀌어도
AMI를 다시 굽지 않는다(결정 B·J). 파이프라인에는 schedule이 없다. **드라이버·베이스를 올릴 때만** 사람이 돌린다.

| 언제 | 무엇을 |
|---|---|
| 3b 머지·CI apply 직후 | 첫 실행 → AMI ID를 `gpu_ami_id`에 박는 PR(3c) |
| 분기 1회 또는 CUDA 하한 변경 | `nvidia_driver_branch`·`component_version`·`recipe_version`을 올리는 PR → apply → 실행 → `gpu_ami_id` 갱신 PR(인스턴스 replace) |
| `worker_idle_stop_seconds`·env 스크립트·유닛 변경 | 같은 절차(AMI에 구워지는 값이다). `component_version`을 올리지 않으면 apply가 already exists로 실패한다 |

```bash
export AWS_PAGER=""
ARN=$(terraform output -raw score_gpu_image_pipeline_arn)

# 실행 (빌드 g6.xlarge → 재부팅 2회 → 테스트 인스턴스 1대, 합쳐 25~35분). 쿼터: 빌드 4 vCPU + 워커 풀 8 vCPU = 12
aws imagebuilder start-image-pipeline-execution --image-pipeline-arn "$ARN" --region ap-northeast-2 --query imageBuildVersionArn --output text

# 진행 상태 (BUILDING → TESTING → DISTRIBUTING → AVAILABLE. FAILED면 콘솔 Image Builder > Images > 로그 링크)
aws imagebuilder list-image-pipeline-images --image-pipeline-arn "$ARN" --region ap-northeast-2 \
  --query 'imageSummaryList[].[version,state.status,dateCreated,outputResources.amis[0].image]' --output text

# 결과 AMI (Name 태그 wes-score-gpu-ami). 이 ID를 variables.tf의 gpu_ami_id 기본값으로
aws ec2 describe-images --owners self --region ap-northeast-2 --filters Name=tag:Name,Values=wes-score-gpu-ami \
  --query 'sort_by(Images,&CreationDate)[].[ImageId,Name,CreationDate]' --output text
```

- 빌드 인스턴스는 SSM으로만 접속되고(인바운드 0) 실패하면 스스로 종료된다(`terminate_instance_on_failure`).
  빌드 로그는 CloudWatch `/aws/imagebuilder/wes-score-gpu`에 남는다.
- 테스트 단계는 완성된 AMI로 새 인스턴스를 띄운다. 거기서 `wes-score` 유닛은 빌더 롤이라 SSM 읽기가 실패해
  세 번 시도 후 멈추는데, 이건 의도된 동작이다(워커 롤이 있는 3c 인스턴스에서만 산다).
- 만들어진 AMI·스냅샷은 Terraform 밖이다(배포 구성이 만든다). 옛 AMI는 `gpu_ami_id`가 새 것으로 바뀐 뒤
  `deregister-image` + `delete-snapshot`으로 지운다. 스냅샷 30GB ≈ 월 $1.5.
- 파이프라인 실행 중 `InsufficientInstanceCapacity`/쿼터 초과면 워커 2대가 켜져 있는지 본다(G 쿼터 12 기준 셋이 같이 돌 수 있다).

**워커 유닛이 하는 일**(AMI 안, `modules/score-gpu/files/`): `wes-score-env.sh`가 SSM 세 파라미터 → `/run/wes-score.env`(tmpfs, 0600),
`wes-score-pull.sh`가 ECR 로그인·`gpu` pull, 그다음 `docker run --gpus all`. 워커가 유휴 `WORKER_IDLE_STOP_SECONDS`(30, #51)를 넘기면
자기 인스턴스를 정지한다. 10분 안에 세 번 기동에 실패하면 `wes-score-failsafe`가 인스턴스를 정지한다 — 켜진 채 남아 시간당
요금을 내는 일이 없게. 점검은 SSM 접속 뒤 `journalctl -u wes-score -u wes-score-failsafe`.

### # GPU 워커 풀 점검 (PR-3c)

워커는 AZ마다 한 대(`ap-northeast-2a`·`2c`), 태그 `Name=wes-score-gpu`, 생성 직후 정지 상태다. 켜고 끄는 주체는 넷이고 순서대로
1차 → 최후다: wes `GpuController`(점수 없는 UPLOADED 사진이 있으면 Start) → 워커 유휴 30초 자기 정지 → wes 2분 무진행 안전망 Stop →
CloudWatch 알람(CPU 30분 < 5%) 정지 액션. 인프라가 소유하는 건 마지막 둘(생성 직후 정지·알람)뿐이다.

```bash
export AWS_PAGER=""
# 상태 (stopped가 평상시. running인데 잡이 없으면 아래 강제 정지)
aws ec2 describe-instances --region ap-northeast-2 --filters Name=tag:Name,Values=wes-score-gpu \
  --query 'Reservations[].Instances[].[InstanceId,Placement.AvailabilityZone,State.Name,LaunchTime]' --output text

# 접속 (SSH 없음) → 유닛·워커 로그
aws ssm start-session --region ap-northeast-2 --target <instance-id>
sudo journalctl -u wes-score -u wes-score-failsafe -n 200 --no-pager
sudo docker logs --tail 200 wes-score

# 강제 정지 / 수동 켜기 (wes를 거치지 않는다)
aws ec2 stop-instances  --region ap-northeast-2 --instance-ids <instance-id>
aws ec2 start-instances --region ap-northeast-2 --instance-ids <instance-id>
```

- **켜기 스위치**: wes는 SSM `/wes/prod/app.analysis.gpu.enabled`(변수 `gpu_score_enabled`)가 `true`일 때만 풀을 쓴다. `false`면
  score Lambda 폴백만 돈다. 값은 앱이 부팅 때 읽으므로 바꾼 뒤 wes-api 컨테이너를 재시작한다. 첫 실측은 `false` → 수동 Start로
  워커가 점수를 내는지 확인 → `true` 순서가 안전하다.
- **인스턴스 0대도 정상**: 워커를 지우거나 Start가 실패(`InsufficientInstanceCapacity`)하면 wes가 Lambda 폴백으로 흐른다.
  Terraform으로 풀을 없애려면 `modules/score-gpu/workers.tf`와 security의 `score_gpu` SG를 지운다(앱 코드 변경 없음).
- **AMI 갱신**: `gpu_ami_id`를 바꾸면 워커 2대가 replace 되고 `aws_ec2_instance_state`가 새 인스턴스도 정지시킨다. 워커는 상태가
  없어 진행 중인 배치는 잠금이 풀려 다른 워커나 Lambda가 다시 집는다.
- **비용**: 정지 상태는 루트 gp3 30GB × 2 ≈ 월 $5. running은 g6.xlarge 시간당 약 $0.99/대.

---

## # 모니터링 (Loki + Grafana)

앱 컨테이너의 로그를 Loki에 모아 Grafana에서 조회한다. 장애 때 앱 EC2에 들어가 `docker logs`를 뒤지지 않기 위한 것이다. 구성은 `modules/monitoring`, 컨테이너 정의는 `modules/monitoring/user_data.sh.tftpl`에 있다.

| 항목 | 값 |
|---|---|
| 접속 | `https://monitoring.easyselect.kr` — `admin` / `/wes/monitoring/grafana.admin-password` |
| 로그 전송 | 앱 → `http://<프라이빗 IP>:3100/loki/api/v1/push` (`/wes/prod/app.logging.loki-url`) |
| 보관 | 7일 (`loki_retention`, compactor가 삭제) |
| 데이터 위치 | 서버 `/opt/wes-monitoring/{loki,grafana,caddy}/` — 컨테이너를 갈아도 남는다 |
| 이미지 | `modules/monitoring/variables.tf`의 `*_image` 기본값에 고정 |

**왜 ALB 뒤가 아닌가.** 앱 ALB와 운명을 같이하지 않게 하고, 호스트 라우팅·타깃 그룹·ACM 추가를 들이지 않기 위해 EIP에 직결하고 TLS는 Caddy가 Let's Encrypt로 받는다.

**왜 프라이빗 IP로 보내는가.** 3100은 앱 EC2 SG 참조 규칙으로만 열려 있고, SG 참조는 VPC 안 프라이빗 경로에서만 매칭된다. 퍼블릭 도메인으로 보내면 IGW를 돌아 들어와 막힌다.

### # 점검

```bash
ssh wes-monitoring
cd /opt/wes-monitoring
docker compose ps                      # loki / grafana / caddy 셋 다 Up
docker compose logs --tail 50 caddy    # 인증서 발급 로그 (certificate obtained successfully)
curl -s localhost:3100/ready           # ready
```

### # 비밀번호 변경

SSM 값은 **최초 기동에만** 쓰인다. 이미 뜬 Grafana는 UI(프로필 → Change password)나 아래로 바꾼다:

```bash
docker compose exec grafana grafana cli admin reset-admin-password '<새 비밀번호>'
```

SSM 파라미터도 같이 `--overwrite` 해 두어야 인스턴스 재생성 때 같은 값으로 뜬다.

### # 재기동·설정 반영

`user_data`는 첫 부팅에만 돈다. 템플릿을 고치면 `user_data_replace_on_change`로 **인스턴스가 교체**되고, 보관 중인 로그는 사라진다(7일치라 감수한다). 컨테이너만 다시 올리려면:

```bash
sudo /opt/wes-monitoring/start.sh    # SSM에서 비밀번호 다시 읽고 compose pull && up
```

인스턴스가 교체되면 프라이빗 IP가 바뀌어 `app.logging.loki-url`도 바뀐다. **앱을 재시작**해야 새 주소로 보낸다.

### # 문제 해결

| 증상 | 원인 |
|---|---|
| `monitoring.easyselect.kr` 인증서 오류 (apply 직후) | Caddy가 DNS 전파를 기다리며 재시도 중. 1-3분 뒤 재확인. 계속되면 `docker compose logs caddy` |
| 컨테이너가 하나도 없다 | user_data가 Grafana 비밀번호를 못 읽고 멈췄다 — `/wes/monitoring/grafana.admin-password` 등록 후 `sudo /opt/wes-monitoring/start.sh`. `cloud-init` 로그 : `/var/log/cloud-init-output.log` |
| `admin` 로그인 실패 | Grafana DB가 이미 만들어진 뒤 SSM 값을 바꿨다 — 위 비밀번호 변경 절차로 맞춘다 |
| 로그가 한 줄도 안 들어온다 | (1) 앱 appender 미설정(서버 저장소) (2) 앱이 `app.logging.loki-url`을 읽기 전에 떴다 → 앱 재시작 (3) 앱 EC2에서 `curl -s <loki-url 호스트>:3100/ready`가 타임아웃이면 SG — 앱이 퍼블릭 주소로 보내고 있지 않은지 확인 |
| 오래된 로그가 안 지워진다 | compactor는 `retention_delete_delay`(2h) 뒤에 지운다. 7일 + 2시간까지는 정상 |
| Grafana가 느리거나 OOM | `free -m`으로 스왑 사용량 확인. 계속되면 `monitoring_instance_type`을 `t4g.small`로 |

---

## # 검증 체크리스트

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
| 9 | `POST /embeddings/run` 후 잠시 뒤 같은 집계 | `embedded` 수가 올라간다 (Lambda 호출·DB 접속·S3 엔드포인트 확인) |
| 10 | `dig monitoring.easyselect.kr +short` | `terraform output -raw monitoring_public_ip`와 같은 IP 1개 |
| 11 | `curl -sI https://monitoring.easyselect.kr` | 인증서 유효, `302`(Grafana 로그인) |
| 12 | Grafana → Explore → Loki | 앱 배포 후 로그가 조회된다 (appender는 서버 저장소 쪽 작업) |

5번 DB 연결 확인 (EC2에서):

```bash
sudo apt-get install -y postgresql-client
DB_PASSWORD=$(aws ssm get-parameter --name /wes/prod/spring.datasource.password \
  --with-decryption --query Parameter.Value --output text --region ap-northeast-2)
PGPASSWORD="$DB_PASSWORD" psql -h <rds_address> -U wes_admin -d wes_db -c 'select 1;'
```

---

## # 폐기

```bash
terraform destroy   # 앱 스택 (루트에서)
```

- 스냅샷 없이 전부 삭제된다(테스트 데이터 포함). 사진 버킷은 `force_destroy`라 원본까지 함께 지워진다. 모니터링 EC2의 로그와 EIP도 함께 사라진다.
- 호스팅 존은 dns 스택 소유라 **그대로 남는다** — NS 재위임 없이 나중에 apply만 다시 하면 된다 (존 유지 비용 월 $0.50).
- 존까지 완전히 없애려면(프로젝트 종료 시에만):

  ```bash
  terraform -chdir=dns destroy
  ```
