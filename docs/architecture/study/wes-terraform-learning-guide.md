# 테라폼을 배우면서 만드는 WES 인증 인프라 — 학습형 가이드

> WES-107~115를 진행하며 Terraform을 처음부터 익히는 것을 목표로 합니다.
> 각 단계마다 **"📚 여기서 배우는 것"** 을 먼저 읽고 작업하면, 프로젝트가 끝날 때쯤
> Terraform의 핵심 개념을 한 바퀴 다 돌게 됩니다.

---

## 0장. 시작하기 전에 — 테라폼이란?

### 테라폼의 한 문장 요약

> "AWS 콘솔에서 마우스로 클릭해서 만들던 것을, **코드로 선언**하고 **명령 한 번**으로 만들고 고치고 지운다."

이걸 IaC(Infrastructure as Code)라고 부릅니다. 코드로 관리하면 좋은 점:

- 지금 인프라가 어떤 모양인지 **코드만 보면** 알 수 있다 (콘솔 뒤지기 X)
- 같은 환경을 **몇 번이든 똑같이** 다시 만들 수 있다
- 변경 전에 **"뭐가 바뀔지" 미리 보고**(plan) 승인 후 반영한다(apply)
- Git으로 이력·리뷰·롤백이 된다

### 꼭 알아야 할 용어 6개

| 용어 | 뜻 | 비유 |
|---|---|---|
| **HCL** | 테라폼 설정 언어 (`.tf` 파일) | 설계도를 쓰는 언어 |
| **Provider** | AWS·GCP 등과 통신하는 플러그인 | AWS API를 대신 호출해주는 통역사 |
| **Resource** | 만들 대상 하나 (EC2 1대, 버킷 1개…) | 설계도 위의 부품 하나 |
| **State** | "테라폼이 지금까지 만든 것" 장부 (`terraform.tfstate`) | 재고 대장 |
| **Plan** | 코드와 실제(State)를 비교해 "이렇게 바꿀 예정" 미리보기 | 견적서 |
| **Apply** | Plan대로 실제 AWS에 반영 | 시공 |

### 기본 워크플로우 — 앞으로 수백 번 반복할 것

```bash
terraform init      # 처음 1회(또는 설정 바뀔 때): provider 다운로드, backend 연결
terraform fmt       # 코드 자동 정렬 (들여쓰기 등)
terraform validate  # 문법 검사
terraform plan      # 미리보기 ← 여기까지는 아무것도 안 바뀜, 마음껏 실행
terraform apply     # 실제 반영 ← 이것만 조심!
```

> 💡 **초보 팁**: `plan`은 공짜입니다. 코드를 조금 고칠 때마다 plan을 돌려서
> "테라폼이 내 코드를 어떻게 이해했는지" 확인하는 습관을 들이세요.
> plan 출력에서 `+`는 생성, `-`는 삭제, `~`는 수정, `-/+`는 **삭제 후 재생성**(주의!)입니다.

### HCL 30초 문법

```hcl
# resource "리소스타입" "내가_붙인_이름" { 설정... }
resource "aws_s3_bucket" "state" {
  bucket = "wes-terraform-state"       # 인자 = 값
}

# 다른 리소스 참조: 타입.이름.속성
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id     # ← 위 버킷의 id를 참조. 테라폼이 순서도 알아서 정함
  versioning_configuration { status = "Enabled" }
}

variable "region" {                    # 입력값 (함수의 파라미터 같은 것)
  type    = string
  default = "ap-northeast-2"
}

output "bucket_name" {                 # 출력값 (apply 후 터미널에 보여줌)
  value = aws_s3_bucket.state.bucket
}
```

참조가 있으면 테라폼이 **의존성 그래프**를 만들어 생성 순서를 스스로 결정합니다.
"A 먼저 만들고 B 만들어야지"를 우리가 신경 쓸 필요가 거의 없어요.

### 사전 준비 체크리스트

- [ ] `terraform` 설치 (`brew install terraform` 또는 tfenv 권장 — 버전 고정에 유리)
- [ ] `aws` CLI 설치 + 자격 증명 설정 (`aws sts get-caller-identity`로 확인)
- [ ] SSM Session Manager 플러그인 설치 (`brew install --cask session-manager-plugin`)
- [ ] Route 53에 서비스 도메인 hosted zone 준비
- [ ] 연습: 빈 폴더에서 S3 버킷 하나 만들고 지워보기 (아래 5분 실습)

```bash
mkdir /tmp/tf-hello && cd /tmp/tf-hello
cat > main.tf <<'EOF'
provider "aws" { region = "ap-northeast-2" }
resource "aws_s3_bucket" "hello" { bucket = "wes-tf-hello-<본인이니셜-랜덤숫자>" }
EOF
terraform init && terraform plan   # 뭐가 만들어질지 읽어보기
terraform apply                    # yes 입력 → 콘솔에서 버킷 확인
terraform destroy                  # 정리. destroy도 plan을 먼저 보여줌
```

이 5분 실습이 끝났다면 이미 테라폼의 80%를 경험한 겁니다. 나머지는 규모와 안전장치예요.

---

## 진행 순서 한눈에

```
1단계 WES-108  State 원격 저장 + 레포 골격     ← 배우는 것: backend, state, lockfile
2단계 WES-109  VPC·서브넷·보안 그룹            ← 배우는 것: module, variable, SG 참조
3단계 WES-110  EC2 + IAM                       ← 배우는 것: data source, IAM policy, user_data
4단계 WES-111  RDS PostgreSQL                  ← 배우는 것: 민감값 다루기, lifecycle
5단계 WES-112  ALB·도메인·HTTPS                ← 배우는 것: output 활용, DNS 검증 패턴
6단계 WES-113  Parameter Store·KMS             ← 배우는 것: ignore_changes, 시크릿 설계
7단계 WES-114  CI/CD                           ← 배우는 것: OIDC, plan/apply 분리 운영
8단계 WES-115  CloudWatch + 스모크 테스트       ← 배우는 것: 알람 코드화, 운영 마무리
```

각 이슈마다: Linear에서 In Progress → 이슈의 `gitBranchName`으로 브랜치 →
작업 → PR(plan 결과 요약 첨부) → 승인 후 apply → 완료 조건 확인 → Done.

### 레포 공통 규칙 (AGENTS.md — 외우세요)

1. 시크릿 값은 코드·`tfvars`·output·State 출력·로그·커밋 **어디에도** 넣지 않기
2. Plan 파일, 로컬 State, `.terraform/` 캐시 커밋 금지 (`.gitignore`)
3. 커밋: Conventional Commit (`feat(network): add private subnets`)
4. `apply`는 Makefile 기본 타깃·자동화에 절대 넣지 않기
5. 변수·output은 `snake_case`, 모듈명은 capability 기준 (`network`, `database`)

---

## 1단계. WES-108 — State 원격 저장 + 레포 골격

### 📚 여기서 배우는 것: State와 Backend

테라폼은 apply할 때마다 "내가 만든 것"을 **State 파일**에 기록합니다.
기본은 내 컴퓨터의 `terraform.tfstate`인데, 이러면 두 가지 문제가 생겨요:

1. 노트북이 날아가면 장부도 날아감 → 테라폼이 "아무것도 안 만든 줄" 알게 됨
2. CI와 내가 동시에 apply하면 장부가 꼬임

해결책이 **원격 backend**: State를 S3에 두고, DynamoDB로 "한 번에 한 명만 수정" 잠금을 겁니다.

> 🐣 닭과 달걀 문제: "State를 담을 S3"를 테라폼으로 만들려면 그 작업의 State는 어디에?
> → 그래서 **bootstrap 스택**을 분리합니다. bootstrap만 예외적으로 로컬 State로 1회 apply하고,
> 이후 본 스택은 그 S3를 backend로 씁니다. 업계 표준 패턴이에요.

### 실습 절차

1. 레포 골격 만들기:

   ```
   WES-Infra/
   ├── bootstrap/           # State 저장소 만드는 미니 스택 (로컬 state, 딱 1회)
   ├── modules/             # 2단계부터 채워짐
   ├── environments/prod/   # 우리의 "진짜" 스택
   ├── tests/
   ├── docs/
   ├── Makefile
   └── .gitignore
   ```

   `.gitignore` 필수 내용:

   ```gitignore
   *.tfstate
   *.tfstate.*
   .terraform/
   *.tfplan
   *.auto.tfvars      # 민감값이 들어갈 수 있는 파일
   ```

2. `bootstrap/main.tf` — 첫 진짜 테라폼 코드:

   ```hcl
   provider "aws" { region = "ap-northeast-2" }

   resource "aws_s3_bucket" "tf_state" {
     bucket = "wes-prod-tf-state-<계정ID 등 유니크값>"
   }

   resource "aws_s3_bucket_versioning" "tf_state" {
     bucket = aws_s3_bucket.tf_state.id
     versioning_configuration { status = "Enabled" }   # 실수로 State 망가뜨려도 복구 가능
   }

   resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
     bucket = aws_s3_bucket.tf_state.id
     rule { apply_server_side_encryption_by_default { sse_algorithm = "aws:kms" } }
   }

   resource "aws_s3_bucket_public_access_block" "tf_state" {
     bucket                  = aws_s3_bucket.tf_state.id
     block_public_acls       = true
     block_public_policy     = true
     ignore_public_acls      = true
     restrict_public_buckets = true
   }

   resource "aws_dynamodb_table" "tf_lock" {
     name         = "wes-prod-tf-lock"
     billing_mode = "PAY_PER_REQUEST"
     hash_key     = "LockID"
     attribute { name = "LockID"  type = "S" }
   }
   ```

   `cd bootstrap && terraform init && terraform plan` → 출력을 **한 줄씩 읽어보고** apply.

3. `environments/prod/versions.tf` — 본 스택이 그 S3를 쓰도록:

   ```hcl
   terraform {
     required_version = "1.9.x"          # 정확히 고정 (팀원·CI와 버전 통일)
     backend "s3" {
       bucket         = "wes-prod-tf-state-..."
       key            = "prod/terraform.tfstate"
       region         = "ap-northeast-2"
       dynamodb_table = "wes-prod-tf-lock"
       encrypt        = true
     }
     required_providers {
       aws = { source = "hashicorp/aws", version = "~> 5.0" }
     }
   }

   provider "aws" {
     region = var.region
     default_tags {                       # 모든 리소스에 자동으로 붙는 태그
       tags = { Project = "wes", Environment = "prod", ManagedBy = "terraform" }
     }
   }
   ```

   > 📚 `~> 5.0`은 "5.x까지 허용, 6.0 금지"라는 뜻. `terraform init`을 하면
   > `.terraform.lock.hcl`이 생기는데 이건 **커밋합니다** — npm의 lockfile과 같은 역할로,
   > 팀원과 CI가 정확히 같은 provider 버전을 쓰게 보장해요.

4. Makefile:

   ```makefile
   .PHONY: fmt validate test plan
   fmt:      ; terraform fmt -recursive
   validate: ; cd environments/$(ENV) && terraform validate
   test:     ; @echo "tests: TODO"
   plan:     ; cd environments/$(ENV) && terraform plan
   # apply 타깃은 일부러 없음 — AGENTS.md 규칙. apply는 항상 의식적으로.
   ```

### ✅ 완료 조건 (Linear WES-108)

- [ ] `make fmt` / `make validate` / `make plan ENV=prod` 동작
- [ ] 터미널 2개에서 동시에 plan 실행 → 한쪽이 "state lock" 에러를 내는 것 확인 (잠금 학습!)
- [ ] `git status`에 tfstate·plan·자격 증명이 안 보임

---

## 2단계. WES-109 — VPC·서브넷·보안 그룹

### 📚 여기서 배우는 것: 모듈(module)과 변수(variable)

모듈은 **테라폼의 함수**입니다. 리소스 묶음을 `modules/network`에 정의하고,
`environments/prod`에서 변수를 넣어 호출해요:

```hcl
# environments/prod/main.tf
module "network" {
  source   = "../../modules/network"    # 함수 호출
  vpc_cidr = "10.0.0.0/16"              # 파라미터 전달
  az_count = 2
}
# 모듈의 output 사용: module.network.vpc_id
```

모듈 폴더의 관례: `main.tf`(리소스), `variables.tf`(입력), `outputs.tf`(출력).

그리고 이번 단계의 네트워크 개념 최소한만:

- **VPC** = AWS 안의 우리 전용 사설망. **서브넷** = 그 안의 구역.
- **public subnet** = 인터넷과 직접 통신 가능(IGW 라우트 있음), **private** = 불가능.
- **Security Group(SG)** = 리소스에 붙는 방화벽. 핵심 기술: 소스에 IP 대신
  **다른 SG를 지정**할 수 있어요. "ALB가 붙어있는 것들만 EC2에 접근 가능" 같은
  규칙이 IP 하드코딩 없이 표현됩니다.

### 실습 절차

1. `modules/network` 작성: VPC, 2개 AZ의 public/private subnet, IGW, route table.
   CIDR·AZ 수는 `variables.tf`로. **NAT Gateway는 만들지 않습니다**
   (EC2가 public에 있어서 불필요 — 시간당 과금되는 비싼 리소스라 비용 절감.
   나중에 EC2를 private로 옮기면 필요해진다는 메모를 `docs/`에 남기기).

2. SG 3종 — 사슬처럼 연결:

   ```hcl
   resource "aws_security_group_rule" "ec2_from_alb" {
     type                     = "ingress"
     from_port                = var.app_port
     to_port                  = var.app_port
     protocol                 = "tcp"
     security_group_id        = aws_security_group.ec2.id
     source_security_group_id = aws_security_group.alb.id   # ← SG 참조!
   }
   ```

   | SG | 인바운드 | 아웃바운드 |
   |---|---|---|
   | `alb-sg` | 80, 443 ← 인터넷 | 앱 포트 → ec2-sg |
   | `ec2-sg` | 앱 포트 ← alb-sg만 | 443(OAuth API 호출용), 5432 → rds-sg |
   | `rds-sg` | 5432 ← ec2-sg만 | 없음 |

3. **SSH(22)는 어디에도 열지 않기.** 접속은 3단계의 SSM으로 해결됩니다.

### ✅ 완료 조건 (WES-109)

- [ ] plan에서 VPC·subnet·route·SG 구성 검토 가능
- [ ] RDS로 가는 길이 `ec2-sg` 경유뿐임을 SG 규칙으로 설명할 수 있음 (스스로에게 테스트!)

---

## 3단계. WES-110 — EC2 + IAM 인스턴스 프로파일

### 📚 여기서 배우는 것: data source와 IAM 최소 권한

`resource`가 "만드는 것"이라면 **`data`는 "이미 있는 것을 조회"**하는 문법입니다:

```hcl
# 최신 Amazon Linux 2023 AMI ID를 AWS가 관리하는 SSM 파라미터에서 조회
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
# 사용: data.aws_ssm_parameter.al2023.value
```

AMI ID를 하드코딩하지 않는 이유: 리전마다 다르고 계속 갱신되기 때문.

**IAM 최소 권한**: EC2에 역할(Role)을 붙이면 그 안의 앱이 Access Key 없이 AWS API를
쓸 수 있습니다. 이때 권한을 "필요한 경로만"으로 좁히는 게 핵심이에요:

```hcl
data "aws_iam_policy_document" "param_read" {
  statement {
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:*:*:parameter/wes/prod/auth/*"]   # 이 경로만!
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = [var.secrets_kms_key_arn]                        # 이 키만!
  }
}
```

### 실습 절차

1. `modules/compute`: EC2 선언. 인스턴스 타입·볼륨 크기는 변수화, 루트 볼륨 `encrypted = true`.
2. IAM Role + 인스턴스 프로파일:
   - `AmazonSSMManagedInstanceCore` 관리형 정책 (SSM 접속용)
   - 위의 Parameter Store 경로 제한 정책 + KMS Decrypt
   - CloudWatch Logs 쓰기, ECR pull(읽기 계열)
3. **key_name 없이** 생성 (SSH 키 페어 X). 접속은:

   ```bash
   aws ssm start-session --target i-0123456789abcdef
   ```

   > 💡 SSM 접속은 IAM 권한 + CloudTrail 로그로 통제·기록됩니다.
   > SSH 포트를 여는 것보다 안전하고, 키 관리도 필요 없어요.

4. `user_data`(첫 부팅 스크립트)로 Docker·CloudWatch Agent 설치까지만.
   앱 컨테이너 기동은 7단계 CI/CD가 담당.
5. ALB target group 자동 재등록: 크기 1짜리 Auto Scaling Group으로 감싸면
   인스턴스가 교체돼도 ALB에 자동으로 다시 붙습니다.

### ✅ 완료 조건 (WES-110)

- [ ] SSM Session Manager 접속 성공
- [ ] 인스턴스 안에서 `curl -sI https://accounts.google.com` 성공 (아웃바운드 443)
- [ ] `aws ssm get-parameter --name /other/path` → AccessDenied 확인 (최소 권한 검증!)

---

## 4단계. WES-111 — RDS PostgreSQL

### 📚 여기서 배우는 것: 민감값을 테라폼에서 다루는 법

DB 비밀번호를 코드에 쓰면 Git에 영원히 남습니다. 테라폼의 답:

- `manage_master_user_password = true` → **AWS가 비밀번호를 만들어 Secrets Manager에 보관**.
  테라폼 코드에도, State에도 평문이 남지 않는 가장 깔끔한 방법 (권장).
- 변수에 `sensitive = true`를 붙이면 plan 출력에서 값이 `(sensitive value)`로 가려짐.
- 단, **State 파일 자체에는 많은 값이 평문으로 저장**됩니다. 그래서 1단계에서
  State 버킷을 암호화하고 접근 권한을 제한한 거예요. (연결되죠!)

또 하나, **삭제 방지 3종 세트**:

```hcl
deletion_protection = true    # 콘솔/테라폼에서 삭제 시도 자체를 차단
skip_final_snapshot = false   # 지워지더라도 마지막 스냅샷은 남김
# + terraform plan에서 "-/+" (재생성) 표시가 뜨면 반드시 멈추고 원인 확인!
```

### 실습 절차

1. `modules/database`: RDS PostgreSQL 선언. 엔진 버전·클래스·스토리지 변수화,
   `multi_az`는 변수(기본 false — 단일 인스턴스로 시작).
2. private subnet의 DB subnet group 배치, `publicly_accessible = false`,
   접근은 `rds-sg`만.
3. `storage_encrypted = true`, parameter group도 코드로.
4. 백업: `backup_retention_period`(예: 7), 유지보수 창, 위의 삭제 방지 세트.
5. 마스터 자격 증명은 `manage_master_user_password = true`.
6. 스키마 마이그레이션(BE의 WES-88)은 "EC2에서 실행"으로 경로를 정하고
   실패 시 롤백 절차를 `docs/db-migration.md`에.

### ✅ 완료 조건 (WES-111)

- [ ] apply 후 EC2에서만 5432 접속 가능 (로컬에서 `psql` 시도 → 실패해야 정상)
- [ ] 자동 백업 동작, deletion_protection on
- [ ] DB 자격 증명이 저장소·plan 출력 어디에도 없음

---

## 5단계. WES-112 — ALB·Route 53·ACM + OAuth 콜백 URL 확정

### 📚 여기서 배우는 것: output의 진짜 쓸모, DNS 검증 패턴

**output**은 단순 출력이 아니라 "인프라가 다른 팀에게 주는 인터페이스"입니다.
이번 단계의 output(콜백 URL)은 BE 팀과 Provider 콘솔 등록의 **기준값**이 돼요.

**ACM DNS 검증 패턴** — 테라폼에서 자주 보는 3단 콤보:

```hcl
resource "aws_acm_certificate" "api" {
  domain_name       = "api.${var.domain}"
  validation_method = "DNS"
}
# ACM이 "이 레코드 만들면 소유권 인정해줄게"라고 준 값을 Route 53에 자동 등록
resource "aws_route53_record" "cert_validation" {
  for_each = { for dvo in aws_acm_certificate.api.domain_validation_options :
               dvo.domain_name => dvo }
  zone_id = var.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 60
}
resource "aws_acm_certificate_validation" "api" {   # 검증 완료까지 대기
  certificate_arn         = aws_acm_certificate.api.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}
```

> 📚 `for_each`는 테라폼의 반복문입니다. "비슷한 리소스 여러 개"를 복붙 없이 만들어요.

### 실습 절차

1. 위 패턴으로 ACM 인증서 + DNS 검증.
2. `api.<도메인>` ALIAS 레코드 → ALB.
3. ALB listener: 443(최신 TLS 정책, 예: `ELBSecurityPolicy-TLS13-1-2-2021-06`),
   80은 443으로 redirect action.
4. Target group 헬스체크(경로 `/health`, 간격·임계값)를 변수화.
5. `X-Forwarded-Proto`·`Host` 헤더 전달 확인 — 백엔드(Spring)가 콜백 URL을
   `https://`로 생성하려면 필요. BE의 forward-headers 설정과 맞춰야 해요.
6. output 선언:

   ```hcl
   output "api_base_url" { value = "https://api.${var.domain}" }
   output "oauth_callback_urls" {
     value = { for p in ["google", "naver", "kakao"] :
               p => "https://api.${var.domain}/login/oauth2/code/${p}" }
   }
   ```

7. Vercel 도메인은 `allowed_origins` 변수로만 받기 (프론트 배포는 범위 외).
8. apply 후 `terraform output oauth_callback_urls` 값을
   Google/Naver/Kakao 개발자 콘솔에 등록.

### ✅ 완료 조건 (WES-112)

- [ ] `curl -I https://api.<도메인>/health` 정상, `curl -I http://...` → 301/308
- [ ] 3사 콜백 URL output 확정 + 콘솔 등록 완료

---

## 6단계. WES-113 — Parameter Store·KMS 시크릿 저장소

### 📚 여기서 배우는 것: lifecycle과 "그릇과 내용물 분리" 패턴

이번 단계의 철학: **테라폼은 시크릿의 "그릇"(경로·타입·권한)만 관리하고,
"내용물"(실제 값)은 절대 모르게 한다.** 이를 가능하게 하는 게 `lifecycle`:

```hcl
resource "aws_ssm_parameter" "google_client_secret" {
  name   = "/wes/prod/auth/oauth/google/client-secret"
  type   = "SecureString"                 # KMS로 암호화 저장
  key_id = aws_kms_key.secrets.arn
  value  = "PLACEHOLDER"                  # 자리만 잡음
  lifecycle { ignore_changes = [value] }  # ★ 값이 바뀌어도 테라폼은 모른 척
}
```

`ignore_changes = [value]` 덕분에: 실제 값을 CLI로 주입해도 다음 plan에서
"되돌리겠다"고 하지 않고, State에도 실제 값이 안 들어갑니다.

실제 값 주입은 테라폼 밖에서:

```bash
aws ssm put-parameter --name /wes/prod/auth/oauth/google/client-secret \
  --type SecureString --value '실제값' --overwrite
```

### 실습 절차

1. KMS key + alias 선언 (`aws_kms_key`, `aws_kms_alias`).
2. 경로 규약 확정:

   ```
   /wes/prod/auth/oauth/{google|naver|kakao}/client-id
   /wes/prod/auth/oauth/{google|naver|kakao}/client-secret
   /wes/prod/auth/jwt/signing-key
   /wes/prod/auth/db/url
   ```

   > 💡 6개 파라미터가 거의 같은 모양이죠? 5단계에서 배운 `for_each`로 깔끔하게:
   > `for_each = toset(["google", "naver", "kakao"])`

3. 위 패턴대로 SecureString + `ignore_changes` 선언.
4. EC2 역할(3단계)에 이 경로 읽기 + KMS Decrypt가 연결돼 있는지 확인.
5. `terraform plan` 출력을 훑어 시크릿 값이 어디에도 안 보이는지 확인.
6. 경로 규약을 `docs/secrets.md`로 문서화 — **실제 값 이관(WES-15/94)은 kang hj 담당**,
   이 문서가 인수인계 기준입니다.

### ✅ 완료 조건 (WES-113)

- [ ] EC2에서 지정 경로 조회 성공, 다른 경로는 AccessDenied
- [ ] 시크릿 값이 저장소·plan·output 어디에도 없음

---

## 7단계. WES-114 — CI/CD (GitHub Actions)

### 📚 여기서 배우는 것: OIDC와 plan/apply 분리 운영

지금까지는 내 로컬 자격 증명으로 apply했지만, 팀 운영은 CI가 합니다.
이때 CI에 장기 Access Key를 넣는 건 금물 — 대신 **OIDC**:

> GitHub Actions가 "나 WES-Infra 레포의 main 브랜치 워크플로우야"라고
> 증명서(OIDC 토큰)를 제시하면, AWS가 **몇 분짜리 임시 자격 증명**을 발급.
> 훔쳐갈 장기 키 자체가 존재하지 않게 됩니다.

역할도 둘로 나눕니다:

- `plan-role`: 읽기 중심 권한 → 모든 PR에서 자동 실행돼도 안전
- `apply-role`: 쓰기 권한 → GitHub **environment protection rule**(승인 버튼)을
  통과해야만 사용 가능

이게 AGENTS.md의 "승인된 Plan만 apply한다"를 기술적으로 강제하는 방법이에요.

### 실습 절차

1. AWS에 GitHub OIDC provider + `plan-role`/`apply-role` 선언 (이것도 테라폼으로!).
   trust policy의 조건을 `repo:<org>/WES-Infra:*` 등으로 좁히기.
2. PR 워크플로우: `terraform fmt -check` → `validate` → `plan`
   → 보안 정적 검사(tfsec/trivy/checkov 중 1) → plan 요약을 PR 코멘트로.
3. Apply 워크플로우: main 병합 후, environment 승인을 거쳐 apply.
   State 잠금(1단계 DynamoDB)이 동시 실행을 막아줌.
4. 백엔드 배포 파이프라인: 이미지 빌드 → ECR push(태그는 **커밋 SHA**)
   → SSM Run Command로 EC2에서 pull·컨테이너 교체 → 헬스체크
   → 실패 시 직전 정상 태그로 롤백.
5. DB 마이그레이션은 배포 전 하위 호환성 확인 단계와 연계.

### ✅ 완료 조건 (WES-114)

- [ ] PR → plan 검토 → 승인 → apply 흐름 1회 이상 동작
- [ ] 배포 1회 + **롤백 1회** 실제로 해보기 (롤백은 장애 때 처음 하면 안 됩니다!)
- [ ] CI 로그에 자격 증명·시크릿 미출력

---

## 8단계. WES-115 — CloudWatch 관측성 + 인증 흐름 스모크 테스트

### 📚 여기서 배우는 것: 알람도 코드다, 그리고 "끝났다"의 정의

Log Group·알람·대시보드도 전부 리소스입니다. 코드로 관리하면
"prod에 어떤 알람이 있더라?"를 코드 리뷰로 확인할 수 있어요.

```hcl
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "wes-prod-alb-5xx-rate"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.alb_5xx_threshold    # 임계값은 변수로
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
```

### 실습 절차

1. Log Group(앱·시스템) + 보존 기간 선언, CloudWatch Agent 수집 구성.
2. **로그 마스킹 확인** (BE와 함께): Access/Refresh Token, OAuth 인가 코드,
   시크릿, 개인정보가 로그에 안 남는지.
3. 알람: ALB 5xx·헬스체크 실패 / EC2 CPU·메모리·디스크 / RDS CPU·연결 수·스토리지.
4. SNS → 이메일/슬랙. 수신자는 변수로 (저장소에 직접 X).
   알람 테스트 팁: 임계값을 일시적으로 낮춰 실제 통지가 오는지 1회 확인.
5. 런북 `docs/runbooks/runbook.md`: 로그 조회, 재배포, 롤백, DB 복구, State 복구 절차.
6. **최종 스모크 테스트** — 5단계 output의 URL 기준:

   | # | 시나리오 | Google | Naver | Kakao |
   |---|---|---|---|---|
   | 1 | 로그인 시작 → Provider 리다이렉트 | ☐ | ☐ | ☐ |
   | 2 | 콜백 → 인가 코드 교환 | ☐ | ☐ | ☐ |
   | 3 | 최초 로그인 자동 가입 | ☐ | ☐ | ☐ |
   | 4 | JWT(Access/Refresh) 발급 | ☐ | ☐ | ☐ |
   | 5 | Access 만료 → Refresh 재발급 | ☐ | ☐ | ☐ |

   - Vercel Origin에서 CORS(preflight 포함) + Authorization/쿠키 전달 확인
   - 실패 응답·로그·plan·CI 로그에 토큰/코드/시크릿 노출 최종 점검

### ✅ 완료 조건 (WES-115)

- [ ] 주요 알람 실제 통지 1회 이상 확인
- [ ] 3사 스모크 테스트 전부 통과, 결과를 Linear 이슈에 기록

---

## 부록 A. 초보자가 꼭 빠지는 함정 7가지

1. **plan의 `-/+`(재생성)를 안 읽고 apply** → DB가 지워졌다 다시 생김.
   plan에서 `must be replaced`가 보이면 무조건 멈추고 이유 확인.
2. **State 파일을 직접 수정** → 절대 금지. 필요하면 `terraform state mv/rm` 명령으로.
3. **콘솔에서 손으로 리소스 수정** → 다음 plan에서 테라폼이 되돌려버림(드리프트).
   급했다면 반드시 코드에 반영하거나 `terraform apply -refresh-only`로 정합화.
4. **`terraform destroy`를 잘못된 디렉터리에서 실행** → 실행 전 `pwd`와
   `terraform workspace show` 확인 습관.
5. **시크릿을 변수 default에 넣기** → default는 코드입니다. 커밋됩니다.
6. **`.terraform.lock.hcl`을 .gitignore에 넣기** → 이건 커밋하는 파일입니다.
   (`.terraform/` 디렉터리와 헷갈리기 쉬움)
7. **에러 메시지를 안 읽기** → 테라폼 에러는 친절한 편입니다. 리소스 타입 문서
   (registry.terraform.io/providers/hashicorp/aws)와 함께 읽으면 대부분 해결돼요.

## 부록 B. 하루를 시작할 때 / 막혔을 때

```bash
# 오늘 작업 시작 루틴
git pull && terraform init -upgrade=false
make fmt && make validate && make plan ENV=prod   # 드리프트 없는지 확인

# 특정 리소스 상태 들여다보기
terraform state list                  # 테라폼이 아는 모든 리소스
terraform state show module.network.aws_vpc.main

# output 다시 보기
terraform output
```

막히면: ① 에러 전문을 읽는다 → ② 해당 리소스의 registry 문서 예제와 비교한다
→ ③ plan을 다시 돌려 테라폼의 "이해"를 확인한다. 이 순서면 대부분 풀립니다.

## 부록 C. 마무리 체크리스트

- [ ] WES-108~115 완료 조건 충족 + Linear Done 처리
- [ ] `docs/`: state-bootstrap / db-migration / secrets / runbook 존재
- [ ] WES-113 경로 문서를 kang hj에게 공유 (WES-15/94 착수 가능)
- [ ] 3사 콜백 URL 콘솔 등록 완료
- [ ] 저장소에 State·plan·자격 증명·시크릿 값 커밋 이력 없음
