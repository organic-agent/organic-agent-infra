# WES-253 백오피스 내부 접근

`https://admin.easyselect.kr`을 tailnet에 직접 등록된 모든 기기에서 이용하도록 구성한다. 기존 공개 API(`api.easyselect.kr` → ALB)는 변경하지 않는다.

## 구성과 보안 경계

```text
tailnet 등록 기기 (사용자 소유 기기 + tag 기반 노드)
  → Tailscale grant (autogroup:member + autogroup:tagged → tag:wes-admin, tcp:443만)
  → admin.easyselect.kr A 레코드 (100.64.0.0/10의 서버 Tailscale IP)
  → tailscale serve raw TCP :443 → 127.0.0.1:8443
  → Caddy TLS + Route53 DNS-01 → 172.30.0.10:8080 백오피스 앱
```

- Funnel은 사용하지 않는다. `tailscale serve --https`의 `*.ts.net` 자동 인증서도 사용하지 않는다.
- 전용 EC2는 패키지·Tailscale·SSM·ACME 아웃바운드를 위해 기존 public subnet과 임시 public IP를 사용하지만 보안 그룹 인바운드 규칙은 0개다. 인터넷에서 public IP의 22/80/443으로 들어오는 경로는 없다.
- Caddy는 `127.0.0.1:8443`에만 바인딩한다. BackOffice는 host port를 publish하지 않고 `wes-admin-internal`의 고정 IP `172.30.0.10:8080`에서만 수신한다. tailnet에서 직접 열리는 포트는 Tailscale Serve의 TCP 443 하나다.
- Caddy는 EC2 역할로 `_acme-challenge.admin.easyselect.kr` TXT만 변경한다. 계정 전체 hosted zone 목록이나 다른 레코드 변경 권한은 없다.
- 인증서는 암호화된 EBS에 저장되고 Caddy가 자동 갱신한다. Tailscale auth key는 앱이 읽는 `/wes/prod/*` 밖의 수동 생성 SSM SecureString에서 부팅 시 한 번 읽으며 Terraform 구성과 state에는 값이 들어가지 않는다.
- 관리자 API 컨테이너의 AWS SDK를 위해 IMDSv2 hop limit은 2다. 대신 BackOffice는 외부 라우팅이 없는 `wes-admin-internal`에만 붙이고 해당 CIDR의 IMDS 접근을 host `DOCKER-USER` 방화벽에서 다시 차단한다. 관리자 API만 `wes-admin-runtime`을 함께 사용한다.
- BackOffice·Spring Boot 관리자 API·Caddy·Tailscale을 함께 실행하므로 기본 인스턴스는 2GiB의 `t4g.small`이다. `t4g.nano/micro`는 변수 검증에서 거부한다.

2026-08-24 읽기 전용 확인 결과, AWS 계정 `233927217926`에 Terraform이 관리하는 public hosted zone `easyselect.kr`(`Z0872123WEAR8P32SI06`)이 있고 외부 NS 조회도 Route53 네임서버 4개와 일치했다. `api.easyselect.kr` 레코드는 존재하고 `admin.easyselect.kr` 레코드는 아직 없다.

## 외부 선행 조건

### 1. tailnet policy 병합

[`tailscale/wes-admin-policy.hujson.example`](../tailscale/wes-admin-policy.hujson.example)의 `tagOwners`, `grants`, `tests` 항목을 기존 tailnet policy에 병합한다. `autogroup:member`는 tailnet에 직접 가입한 사용자의 기기를, `autogroup:tagged`는 사용자 대신 tag로 등록된 노드를 포함한다. 둘을 함께 사용해 tailnet 등록 기기는 모두 백오피스 443에 접근할 수 있게 하고, 다른 tailnet에서 공유받은 기기와 subnet route 뒤의 미등록 기기는 포함하지 않는다.

Tailscale 정책은 허용 규칙의 합집합이다. 기존 `* → *:*`, `* → tag:wes-admin:*` 같은 더 넓은 ACL/grant가 남아 있으면 이번 443 grant가 접근을 좁히지 못한다. policy editor의 테스트가 다음을 모두 통과해야 저장한다.

- tailnet 직접 가입 사용자의 기기 → `tag:wes-admin:443` 허용
- tag 기반 기기 → `tag:wes-admin:443` 허용
- tailnet 등록 기기 → 22, 8080, 8443 거부

### 2. 일회용 서버 auth key 저장

Tailscale admin console에서 다음 속성으로 auth key를 만든다.

- one-off
- pre-approved(디바이스 승인을 쓰는 tailnet인 경우)
- non-ephemeral
- tag: `tag:wes-admin`

값을 표시하거나 셸 기록에 남기지 말고 AWS 콘솔에서 `/wes/admin/tailscale-auth-key` SecureString으로 저장한다. `/wes/prod/*`는 공개 앱 EC2 역할이 읽을 수 있으므로 그 아래에는 두지 않는다. 고객 관리형 KMS 키를 사용하면 그 ARN을 `admin_tailscale_auth_kms_key_arn`에 지정한다. 키는 한 번 사용되면 재사용할 수 없으므로 인스턴스를 교체하기 전에 새 키로 SecureString을 갱신한다.

## 비파괴 plan과 2단계 적용

먼저 원격 state가 기존 리소스를 추적하는지 확인한다. 기존 리소스가 state에 없다면 apply하지 말고 import/reconciliation을 먼저 한다.

```sh
terraform init
terraform state list
terraform plan -out=wes-253.tfplan
terraform show wes-253.tfplan
```

첫 plan에서 `module.admin_access` 아래 EC2 1대, 인바운드 없는 SG, IAM 역할/프로파일/정책이 생성되고 `aws_route53_record.admin`은 0개여야 한다. 교체·삭제나 기존 공개 ALB 변경이 있으면 적용하지 않는다.

이 저장소는 PR에서 plan하고 `main` 머지 시 자동 apply한다. 그러므로 tailnet policy와 SecureString 준비를 마친 뒤 첫 PR을 머지하는 것이 첫 단계 배포 승인이다. CI/CD 자체를 고치는 경우에만 검토한 로컬 plan 파일을 직접 적용한다.

```sh
# 로컬 bootstrap이 명시적으로 승인된 경우에만:
terraform apply wes-253.tfplan
```

부트스트랩 완료와 Tailscale IP를 SSM으로 확인한다.

```sh
INSTANCE_ID="$(terraform output -raw admin_instance_id)"

aws ssm send-command --region ap-northeast-2 \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["cloud-init status --wait","tailscale status","tailscale serve status","tailscale ip -4"]'
```

출력된 IP가 `100.64.0.0/10`인지 확인하고 `variables.tf`의 `admin_tailscale_ipv4` 기본값에 커밋해 두 번째 PR을 만든다. 두 번째 plan은 `admin.easyselect.kr` A 레코드 1개만 추가하는지 확인하고 머지한다. IP가 없는 첫 apply에서 DNS 레코드를 미리 만들지 않는 것은 고장 난 주소나 public IP 노출을 막기 위한 의도된 동작이다.

`most_recent` AMI 조회 결과가 바뀌어도 이 인스턴스는 자동 교체하지 않는다. OS 보안 업데이트는 Ubuntu의 unattended-upgrades로 받고, AMI 교체가 필요하면 새 one-off auth key 준비 → 인스턴스 명시적 교체 → 새 Tailscale IP 확인 → DNS 갱신 순서로 수행한다.

## 앱 배포 계약

이 저장소는 전용 서버와 TLS/Tailscale 진입점, 두 Docker network, IMDS 방화벽, 공통 배포 lock을 준비한다. 애플리케이션 artifact와 registry credential은 각 배포 저장소가 관리한다.

```text
wes-admin-internal (Docker --internal, 외부 route 없음)
├─ wes-backoffice:8080
└─ wes-admin-api:8081

wes-admin-runtime (관리자 API 전용 egress)
└─ wes-admin-api → IMDSv2 / RDS / SSM / S3 / Lambda
```

BackOffice는 host port를 publish하지 않고 `wes-admin-internal`의 `172.30.0.10`만 사용한다. Caddy는 host에서 이 고정 internal IP로 프록시한다. 관리자 API는 먼저 `wes-admin-runtime`에서 시작한 뒤 internal network에 `wes-admin-api` alias로 추가 연결한다. 컨테이너의 `127.0.0.1`은 호스트나 다른 컨테이너가 아니므로 BFF upstream은 반드시 Docker DNS 이름을 쓴다.

```sh
docker run -d --name wes-admin-api \
  --network wes-admin-runtime \
  --publish 127.0.0.1:8081:8081 \
  <approved-admin-api-image>
docker network connect --alias wes-admin-api wes-admin-internal wes-admin-api

docker run -d --name wes-backoffice \
  --network wes-admin-internal \
  --ip 172.30.0.10 \
  --env ADMIN_API_BASE_URL=http://wes-admin-api:8081 \
  <approved-backoffice-image>
```

두 저장소의 SSM 명령은 Docker 로그인·컨테이너 교체·image prune 전에 같은 lock을 잡는다. GitHub Actions concurrency group은 저장소를 넘어 직렬화하지 못하므로 host lock이 최종 방어선이다.

```sh
exec 9>/var/lock/wes-admin-deploy.lock
flock -w 600 9 || { echo "다른 관리자 배포가 진행 중입니다" >&2; exit 1; }
```

백오피스가 뜨기 전 Caddy의 `502`는 TLS와 tailnet 경로가 준비됐고 upstream만 없다는 뜻이다.

### 내부 관리자 API 경계

백오피스 Next BFF는 `ADMIN_API_BASE_URL=http://wes-admin-api:8081`로 같은 호스트의 별도 Spring Boot 앱을 호출한다. `wes-admin` SG에서 공개 앱 `:8080`으로 가던 규칙은 제거하고, RDS `:5432`만 source-SG 참조로 허용한다. 관리자 API `:8081`은 public ALB, Caddy, VPC SG 어디에도 열지 않는다.

`https://api.easyselect.kr/internal/admin`과 하위 경로는 public ALB의 HTTPS 리스너 우선순위 1 규칙에서 고정 `404`로 종료한다. 따라서 해당 요청은 공개 앱 타깃에 전달되지 않으며, 실제 관리자 API 호출은 `wes-admin-internal` 안의 BackOffice BFF에서만 발생한다.

### 관리자 API 설정과 AWS 권한

관리자 API는 공개 앱의 `/wes/prod/*`를 읽지 않고 `/wes/admin-api/prod/*`만 읽는다. Terraform은 URL·사용자명·버킷·Lambda 이름과 `server.port=8081`, `spring.flyway.enabled=false`, `ddl-auto=validate`를 만들고, 비밀번호는 state에 남기지 않도록 다음 경로에 수동 SecureString으로 등록한다.

```sh
terraform output -raw admin_db_password_ssm_parameter
# 출력 경로에 관리자 API 전용 DB 계정 비밀번호를 SecureString으로 등록
```

DB의 `wes_admin_api` 사용자는 별도 수동 절차로 만들고 필요한 테이블 DML/sequence 권한만 부여한다. Flyway는 공개 `wes-api` 한 곳만 실행하고 `wes-admin-api`는 `spring.flyway.enabled=false`, Hibernate `validate`로 기동한다. 관리자 스키마 변경이 포함된 배포도 공개 API가 migration과 health를 끝낸 뒤 관리자 API를 교체한다.

관리자 인스턴스 역할은 이 prefix 읽기, 사진 객체 `GetObject/PutObject/DeleteObject`, 임베딩 함수 `InvokeFunction`만 추가로 가진다. 공개 OAuth/JWT parameter, 다른 버킷, 다른 Lambda에는 권한이 없다.

### GitHub Actions OIDC 배포 역할

배포 역할은 네 개로 나눈다. 공개 API 역할은 `wes-app`, 관리자 API 역할은 `wes-admin`,
BackOffice 역할도 `wes-admin`에만 SSM 명령을 보낼 수 있다. worker 역할은 `wes-embedder`
ECR/Lambda 하나만 변경한다. 서버 저장소 역할 하나를 두 인스턴스나 worker까지 넓히지 않는다.
백오피스 저장소는 immutable OIDC subject 한 값만 신뢰한다.

```text
repo:organic-agent@299031009/organic-agent-backoffice@1344578659:ref:refs/heads/main
```

GitHub API에서 `use_default=true`여도 이 신규 저장소에는 위 immutable 기본 subject가 적용된다. 역할은 EC2 조회, `AWS-RunShellScript` 실행, 명령 결과 조회만 할 수 있고 `ssm:resourceTag/Name = wes-admin` 조건 때문에 다른 EC2에는 명령을 보낼 수 없다.
Server와 Infra는 이름 기반 기본 subject를 쓰지만 IAM에서 immutable `repository_owner_id`와
`repository_id`를 추가로 정확히 검사한다. Infra apply는 workflow의 `environment: production`에
맞춘 environment subject와 `ref=refs/heads/main`도 동시에 요구한다.

적용 후 서버 저장소에는 공개/관리자 API 역할을 각각 등록하고, 백오피스 저장소에는 기존 이름으로 등록한다.
Lambda 셋의 worker 역할은 AI 저장소(`organic-agent-ai`)의 변수로 간다 — [deploy-order.md의 [5]](deploy-order.md#-5-배포-롤-시크릿-스택-세울-때마다).

```sh
# WES-Server
terraform output -raw github_deploy_role_arn           # AWS_DEPLOY_ROLE_ARN
terraform output -raw github_admin_api_deploy_role_arn # AWS_ADMIN_API_DEPLOY_ROLE_ARN

# WES-BackOffice
terraform output -raw github_admin_deploy_role_arn     # AWS_DEPLOY_ROLE_ARN

# organic-agent-ai (시크릿이 아니라 변수)
terraform output -raw github_worker_deploy_role_arn    # AWS_LAMBDA_DEPLOY_ROLE_ARN
```

WES-Server workflow는 공개 `wes-app` 배포와 health가 성공한 뒤에만 관리자 API job을 실행한다. 둘은 같은 커밋 SHA 이미지 태그를 사용하고 관리자 job은 별도 역할을 assume한다. 장기 AWS 액세스 키는 만들거나 저장하지 않는다.

### 전환 순서

최종 Terraform은 기존 `wes-admin → wes-app:8080` 규칙을 제거한다. 현재 BackOffice가 그 경로를
사용 중이므로 첫 인프라 PR은 이 rule을 `admin_to_public_api_transition` 주소로 state move하고
동일한 권한을 유지한다. 첫 plan의 destroy는 0이어야 한다. 무중단 전환은 다음 순서다.

1. 관리자 API runtime IAM, RDS ingress, OIDC 역할과 host network/lock을 먼저 적용한다. 기존
   `wes-admin → wes-app:8080` rule은 그대로 유지한다.
2. 관리자 API를 배포하고 `127.0.0.1:8081/actuator/health`를 확인한다.
3. BackOffice upstream을 `http://wes-admin-api:8081`로 바꾸고 세션 API `401` smoke를 확인한다.
4. 별도 cleanup PR에서 `admin_to_public_api_transition` resource와 moved block을 제거한다.
   마지막 plan에 이 SG rule 삭제 하나만 남았는지 확인하고 적용한다.

첫 전환 plan에서 기존 관리자 EC2·DNS·Tailscale 리소스의 교체/삭제가 없는지 확인한다.

기존 운영 인스턴스가 `t4g.micro`라면 기본값 변경으로 `t4g.small` 전환 시 EC2 stop/start가 발생한다. 루트 EBS와 Tailscale identity는 유지되지만 짧은 관리자 화면 중단과 public IP 변경이 있으므로 별도 점검 시간에 적용한다. `admin.easyselect.kr`은 Tailscale IP를 사용하므로 public IP 변경은 DNS에 반영하지 않는다.

## 검증

서버 안에서 다음을 확인한다.

```sh
cloud-init status --wait
systemctl is-active tailscaled caddy amazon-ssm-agent || systemctl is-active snap.amazon-ssm-agent.amazon-ssm-agent
tailscale status
tailscale serve status
docker network inspect wes-admin-internal --format '{{.Internal}} {{range .IPAM.Config}}{{.Subnet}}{{end}}'
docker network inspect wes-admin-runtime --format '{{.Internal}} {{range .IPAM.Config}}{{.Subnet}}{{end}}'
iptables -C DOCKER-USER -s 172.30.0.0/24 -d 169.254.169.254/32 -j REJECT --reject-with icmp-port-unreachable
ss -ltnp | grep -E '127\.0\.0\.1:(8081|8443)'
curl http://172.30.0.10:8080/health
curl --fail http://127.0.0.1:8081/actuator/health
curl --resolve admin.easyselect.kr:8443:127.0.0.1 https://admin.easyselect.kr:8443/
```

클라이언트와 AWS에서는 다음을 확인한다.

1. `dig admin.easyselect.kr +short`가 서버의 Tailscale IPv4 하나를 반환한다.
2. tailnet에 직접 가입한 모든 사용자의 연결 기기에서 `curl -I https://admin.easyselect.kr`가 유효한 공개 인증서와 앱 응답을 반환한다.
3. tag 기반 기기에서도 같은 요청이 앱 응답을 반환한다.
4. 다른 tailnet에서 공유받은 기기나 Tailscale을 끈 기기에서는 같은 요청이 연결되지 않는다.
5. `aws ec2 describe-security-groups --group-ids <admin SG>`의 `IpPermissions`가 빈 배열이다.
6. 서버의 public IP에 대한 외부 22/80/443 연결이 모두 실패한다.

인프라 정적 회귀 검증은 다음과 같다.

```sh
terraform fmt -check -recursive
terraform validate
terraform -chdir=modules/admin-access test
./tests/admin_access_static_test.sh
./tests/admin_api_network_boundary_static_test.sh
./tests/admin_deploy_oidc_static_test.sh
./tests/admin_runtime_parameters_static_test.sh
```
