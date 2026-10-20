variable "aws_region" {
  description = "AWS 리전. 운영 스택과 같은 VPC를 쓰므로 운영과 같아야 한다"
  type        = string
  default     = "ap-northeast-2"
}

variable "zone_name" {
  description = "Route53 호스티드 존 도메인 (dns/ 스택 소유)"
  type        = string
  default     = "easyselect.kr"
}

variable "subdomain" {
  description = "dev API 서브도메인(존 이름 앞부분). dev.api.easyselect.kr도 easyselect.kr 존 안의 레코드라 존을 나누지 않는다"
  type        = string
  default     = "dev.api"
}

variable "parameter_prefix" {
  description = "dev 앱이 읽는 SSM 프리픽스. 서버의 dev 프로필이 aws-parameterstore:/wes/dev/ 를 import 한다"
  type        = string
  default     = "/wes/dev"

  validation {
    condition     = var.parameter_prefix != "/wes/prod" && !startswith(var.parameter_prefix, "/wes/prod/")
    error_message = "dev 스택은 운영 프리픽스(/wes/prod)를 쓸 수 없습니다."
  }
}

variable "prod_parameter_prefix" {
  description = "운영 앱 프리픽스. dev는 여기서 Loki push URL(운영 스택이 쓰는 값) 하나만 읽는다"
  type        = string
  default     = "/wes/prod"
}

# --- 공유하는 운영 네트워크 ---

variable "shared_name_prefix" {
  description = "운영 스택의 이름 접두사. VPC·서브넷·모니터링 SG를 이 접두사의 Name 태그로 찾는다"
  type        = string
  default     = "wes"
}

variable "azs" {
  description = "운영 VPC의 가용 영역 (운영 스택 azs와 같아야 서브넷을 찾는다)"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

# --- 앱 계층 (운영과 같은 규격) ---

variable "instance_type" {
  description = "앱 EC2 타입 (arm64). wes #274 ADR 0003: JVM 몸집(≈690MB)이 micro의 RAM(≈600MB)을 넘어 스왑 → Full GC 20초 정지. dev 먼저 small(2GB), 운영은 #274 반영 때 같이 올린다"
  type        = string
  default     = "t4g.small"
}

variable "app_port" {
  description = "Spring Boot 앱이 리슨하는 포트"
  type        = number
  default     = 8080
}

variable "health_check_path" {
  # 앱이 살아 대답하나(liveness)만 본다 — /actuator/health 는 DB 검사를 품어 DB 가 몰리면 두 서버가 같이 빠지고
  # ASG 가 멀쩡한 서버를 갈아 치웠다(10-16 dev). 서버 저장소 #313 ADR-0001 §7 안건 1.
  description = "ALB 헬스체크 경로"
  type        = string
  default     = "/actuator/health/liveness"
}

variable "health_check_port" {
  # 헬스를 관리 포트(별도 Tomcat 스레드)에서 본다 — 본 포트 /livez 는 사용자 요청과 같은 줄에 서서, CPU 가 차자 3초를 넘겨
  # ASG 가 멀쩡한 서버를 3번 갈았다(10-17 A-4a). 서버 저장소 #313 W5b(wes PR #324)의 MANAGEMENT_SERVER_PORT 와 같아야 한다.
  description = "ALB 헬스체크 포트(앱 관리 포트)"
  type        = number
  default     = 8090
}

variable "ssh_allowed_cidr" {
  description = "앱 EC2에 SSH를 허용할 CIDR. null이면 22번 규칙 없음 — 평소엔 SSM Session Manager"
  type        = string
  default     = null
}

# 운영 스택과 같은 키. 퍼블릭 키는 비밀이 아니다.
variable "ssh_public_key" {
  description = "EC2 키 페어(wes-dev-key)로 등록할 SSH 퍼블릭 키 — 운영 wes-aws-key와 같은 키"
  type        = string
  default     = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCtn/PIssH3P2nIznmwHpNJqdLqD8SmQt3NT1qy7+0KgjGM8MDXnv7z+S3UawTCOyow1OdGEkQ3Oe+6P1Ge9S0qcvZjmTVJHpWov/tNmwR42Z4wgc/b5s753zpvtEmvfFtMC6LANoEOHk0mbUQ4dqANQ4ny0kOESAQYK19vr+UCjEIPAaTQLoWr33xayULlV3IJz29jjAnjbG9PTfcD9c3Zm/ihtO42Z7wAeYQrgMzAjnmn7m0MwN/aKS9Q4OQm25rRRhl27kQC9AyxqQM/JpMJxUeUJla/mawhRsLI8+Fxpr/Bj9J2KIpYEMU1ylfcM8QzW8tqEsGqIsZJieAuSHCF wes-aws-key"
}

variable "db_name" {
  description = "초기 PostgreSQL 데이터베이스 이름 (운영과 같은 이름, 인스턴스가 다르다)"
  type        = string
  default     = "wes_db"
}

variable "db_username" {
  description = "PostgreSQL 마스터 계정명"
  type        = string
  default     = "wes_admin"
}

variable "db_password_version" {
  description = "SSM /wes/dev/spring.datasource.password 변경 후 RDS에 반영하려면 이 값을 올릴 것"
  type        = number
  default     = 1
}

variable "db_instance_class" {
  description = "dev RDS 인스턴스 클래스. micro(1GB)는 업로드 10 + 사용자 200명 회차에서 메모리 바닥 — small(2GB)과 같은 회차로 비교한다(#136)"
  type        = string
  default     = "db.t4g.small"
}

variable "db_shared_buffers" {
  description = "dev RDS shared_buffers(8KB 페이지). 5893 = 46MB — 10-18 업로드 기준선 회차와 같은 값으로 고정해 회차끼리 비교한다(#136). 16384 = 128MB(small 2GB, #136 3단계): 46MB 버퍼가 빈 페이지 0 · 사용 횟수 0.2~1.6 으로 계속 교체돼, 자주 쓰는 사진·점수 페이지가 덜 밀려나는지 잰다"
  type        = number
  default     = 16384
}

# --- AI 분석 (Lambda 셋 + GPU 워커) ---

variable "embedder_db_username" {
  description = "임베더 Lambda의 DB 사용자. dev RDS 안에 수동 생성한다(docs/runbooks/dev-environment.md)"
  type        = string
  default     = "embedder"
}

variable "analysis_db_username" {
  description = "score·categorize Lambda와 GPU 워커의 DB 사용자. dev RDS 안에 수동 생성한다"
  type        = string
  default     = "photoselect"
}

variable "lambda_image_tag" {
  description = "dev ECR(wes-dev-*)에서 Lambda가 쓰는 이미지 태그. 첫 apply 전에 세 리포지토리에 있어야 한다(런북의 이미지 복사 단계)"
  type        = string
  default     = "latest"
}

variable "embedder_memory_mb" {
  description = "임베딩 Lambda 메모리 — 운영과 같은 값"
  type        = number
  default     = 3008
}

variable "embedder_reserved_concurrent_executions" {
  description = "임베더 동시 실행 상한. wes #274 E-1: 32 → 48, S-1: 48 → 72(R-2-3 업로드 5:22 끝 vs 임베딩 7:51 끝 — 분당 95호출로는 업로드 속도를 못 따라감). 임베더가 적재 때만 DB 연결을 잡아(AI #147) 동시 실행 수가 연결 수가 아니다. wes app.analysis.embed-max-in-flight와 같은 값. 운영은 #274 반영 때. 72 → 108(서버 저장소 #313 10-17): A-4b-10(업로드 10개)에서 72에 꽉 붙어 임베딩이 12분. 결과는 SQS → embedwriter 라 DB 연결을 늘리지 않는다. 계정 동시성 400 − 예약 합(운영 + dev) ≥ 100 을 지킨다"
  type        = number
  default     = 108
}

variable "embedder_async_retry_attempts" {
  description = "임베더 호출이 죽었을 때 Lambda 자체 재시도 횟수. #274 R-2-3에서 1로 열었다(죽은 배치가 wes 재배정 10분을 기다림). wes #286 (c) P5부터는 실패가 실패 큐로 와 wes가 곧바로 다시 배정하므로 0 — Lambda 재시도(≈ 1분 뒤)가 실패를 그만큼 늦게 알리고 같은 배치를 한 번 더 돌린다. 운영은 #274·#286 반영(I3) 때"
  type        = number
  default     = 0
}

variable "embedder_batch_size" {
  description = "임베더가 모델에 한 번에 넣는 사진 수 — 운영과 같은 값"
  type        = number
  default     = 8
}

variable "embedding_dimension" {
  description = "임베딩 폭. 앱의 vector(n) 컬럼과 같아야 한다 — 운영과 같은 값"
  type        = number
  default     = 768
}

variable "score_memory_mb" {
  description = "score Lambda 메모리 — 운영과 같은 값"
  type        = number
  default     = 8192
}

variable "score_ephemeral_storage_mb" {
  description = "score Lambda의 /tmp — 운영과 같은 값"
  type        = number
  default     = 10240
}

variable "score_reserved_concurrent_executions" {
  description = "score 동시 실행 상한 — 운영과 같은 값. 계정 동시성 400 중 운영 66 + dev 66을 예약해도 비예약 268(하한 100)이 남는다"
  type        = number
  default     = 32
}

variable "categorize_memory_mb" {
  description = "categorize Lambda 메모리 — 운영과 같은 값"
  type        = number
  default     = 3008
}

variable "categorize_reserved_concurrent_executions" {
  description = "categorize 동시 실행 상한. wes #274 C-1: 2 → 3, R-2-2 F-2: 3 → 5(R-2-1에서 5개 갤러리 중 둘이 자리를 1~2분 기다림, 스로틀 13). 하나당 갤러리 전체를 읽으므로 DB 메모리를 R-2-2에서 본다. 운영은 #274 반영 때. 5 → 10(#136, dev RDS small): 업로드 10개 회차에서 10개를 한꺼번에 보내도 5개만 돌고 나머지가 33초 기다림(스로틀 17) — small 은 여유 메모리 618MB · 스왑 0이라 같은 회차로 잰다"
  type        = number
  default     = 10
}

variable "categorize_naming_parallel" {
  description = "categorize 2층 이름 Bedrock 동시 호출. wes #274: 4(코드 기본) → 8 — R-2-2에서 2층 6호출이 두 번에 나뉘어 ≈ 9초. 운영은 #274 반영 때"
  type        = number
  default     = 8
}

variable "bedrock_model_id" {
  description = "categorize와 앱이 부르는 Bedrock 프로필 ID. 운영 스택 bedrock_model_id와 같은 값(#71 — 조직 SCP로 `us.`)"
  type        = string
  default     = "us.anthropic.claude-sonnet-4-6"
}

variable "bedrock_region" {
  description = "Bedrock을 부르는 리전. 운영 스택이 이 리전에 둔 엔드포인트 VPC·피어링을 같은 VPC에 있는 dev도 그대로 탄다"
  type        = string
  default     = "us-east-1"
}

variable "gpu_score_enabled" {
  description = "SSM /wes/dev/app.analysis.gpu.enabled. true면 dev 앱이 점수를 dev GPU 워커에 맡기고 score Lambda는 폴백"
  type        = bool
  default     = true
}

variable "gpu_ami_id" {
  description = "dev GPU 워커 AMI. dev는 AMI를 굽지 않고 운영 파이프라인 산출물을 쓴다 — 운영 스택 gpu_ami_id를 올릴 때 같이 올린다"
  type        = string
  default     = "ami-0f3e867e2ed3964ce"
}

variable "gpu_instance_type" {
  description = "dev GPU 워커 타입. G 쿼터 12 vCPU = 운영 워커 2 × 4 + AMI 빌드 4 — dev 워커(4)는 빌드 몫을 빌려 쓴다. 빌드·운영 2대·dev가 한꺼번에 켜지면 늦게 켜는 쪽이 쿼터에 막힌다"
  type        = string
  default     = "g6.xlarge"
}

variable "gpu_worker_azs" {
  # 2c 추가(서버 저장소 #313 10-17): 동시 업로드가 많으면 wes 가 GPU 를 두 대까지 켠다(app.analysis.gpu.max-workers 2) — 운영과 같은
  # 두 AZ. 한 AZ 에 GPU 재고가 없을 때 다른 AZ 것을 켜는 경로도 dev 에서 확인한다. 꺼져 있는 동안은 디스크 값만(≈ $2.7/월).
  description = "dev GPU 워커를 둘 AZ. 한 AZ에 한 대. 빈 목록이면 워커를 만들지 않는다(그때 gpu_score_enabled도 false로)"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

variable "score_gpu_image_tag" {
  description = "dev GPU 워커가 부팅 때 pull 하는 wes-dev-score 태그. AI 저장소의 dev CD가 이 태그를 민다. `gpu-`로 시작하면 ECR 라이프사이클(최근 3개)에 걸리므로 그 접두사는 쓰지 않는다"
  type        = string
  default     = "gpu"

  validation {
    condition     = !startswith(var.score_gpu_image_tag, "gpu-")
    error_message = "score_gpu_image_tag는 gpu- 로 시작할 수 없습니다 — 불변 태그용 라이프사이클 규칙이 지웁니다."
  }
}

# --- 관리자 호스트 (admin.tf) ---

variable "admin_subdomain" {
  description = "dev 관리자 도메인의 서브도메인(zone_name 앞). 운영은 admin"
  type        = string
  default     = "dev.admin"
}

variable "admin_instance_type" {
  description = "dev 관리자 EC2 타입(arm64). 백오피스·관리자 API·Caddy·Tailscale을 같이 돌려 2GiB 이상이어야 한다 — 2026-10-10 micro(1GiB)로 낮췄다가 디스크 스래싱(5분에 41만 번 읽기)으로 멈춰 되돌림(#87 → #91). 스왑 2GB도 함께 둔다(admin.tf)"
  type        = string
  default     = "t4g.small"

  validation {
    condition     = !contains(["t4g.nano", "t4g.micro"], var.admin_instance_type)
    error_message = "admin_instance_type은 t4g.small 이상이어야 합니다."
  }
}

variable "admin_app_port" {
  description = "백오피스 컨테이너 포트(운영과 같다)"
  type        = number
  default     = 8080
}

variable "admin_api_port" {
  description = "관리자 API 컨테이너 포트(운영과 같다)"
  type        = number
  default     = 8081
}

variable "admin_proxy_https_port" {
  description = "Caddy가 127.0.0.1에 여는 포트(운영과 같다)"
  type        = number
  default     = 8443
}

variable "admin_tailscale_hostname" {
  description = "tailnet에 표시할 dev 관리자 서버 이름. 태그는 운영과 같은 tag:wes-admin"
  type        = string
  default     = "wes-dev-admin"
}

variable "admin_tailscale_ipv4" {
  description = "첫 apply 후 확인한 wes-dev-admin의 Tailscale IPv4. null이면 dev 관리자 DNS A 레코드를 만들지 않는다"
  type        = string
  # 2026-10-07 첫 apply 뒤 SSM `tailscale ip -4`로 확인. 인스턴스를 교체하면 IP가 바뀌므로 다시 확인해 고친다.
  default = "100.87.204.110"
}

variable "admin_tailscale_auth_parameter_name" {
  description = "tag:wes-admin 일회용 auth key를 담을 수동 SecureString. 앱 프리픽스(/wes/dev) 밖, 운영 키(/wes/admin)와도 따로"
  type        = string
  default     = "/wes/dev-admin/tailscale-auth-key"

  validation {
    condition     = startswith(var.admin_tailscale_auth_parameter_name, "/") && !startswith(var.admin_tailscale_auth_parameter_name, "/wes/dev/") && !startswith(var.admin_tailscale_auth_parameter_name, "/wes/admin/")
    error_message = "admin_tailscale_auth_parameter_name은 /wes/dev 와 운영 /wes/admin 밖이어야 합니다."
  }
}

variable "admin_parameter_prefix" {
  description = "dev 관리자 API가 읽는 SSM 프리픽스. 공개 앱(/wes/dev)과 운영 관리자(/wes/admin-api/prod)와 분리"
  type        = string
  default     = "/wes/admin-api/dev"

  validation {
    condition     = var.admin_parameter_prefix != "/wes/admin-api/prod" && !startswith(var.admin_parameter_prefix, "/wes/dev/") && !endswith(var.admin_parameter_prefix, "/")
    error_message = "admin_parameter_prefix는 운영 관리자·dev 앱 프리픽스와 달라야 하고 끝 슬래시가 없어야 합니다."
  }
}

variable "admin_db_username" {
  description = "dev 관리자 API의 DB 사용자(운영과 같은 이름, dev RDS에 따로 만든다)"
  type        = string
  default     = "wes_admin_api"
}

variable "monitoring_subdomain" {
  description = "운영 모니터링 서버(Grafana) 서브도메인. dev 관리자의 관측 링크가 가리킨다"
  type        = string
  default     = "monitoring"
}

variable "backoffice_oidc_subject_prefix" {
  description = "백오피스 저장소 OIDC sub의 immutable 접두사(`:ref:...` 앞까지). 운영 admin_github_oidc_subject와 같은 형식"
  type        = string
  default     = "repo:organic-agent@299031009/organic-agent-backoffice@1344578659"
}

variable "backoffice_repository_id" {
  description = "organic-agent-backoffice의 immutable repository ID"
  type        = string
  default     = "1344578659"
}

# --- CD (GitHub OIDC) ---

variable "dev_branch" {
  description = "dev 배포를 트리거하는 브랜치. 서버·AI 저장소 모두 이 브랜치의 워크플로만 dev 배포 롤을 assume 한다"
  type        = string
  default     = "develop"
}

variable "github_repository_owner_id" {
  description = "organic-agent GitHub organization의 immutable owner ID"
  type        = string
  default     = "299031009"
}

variable "server_repository" {
  description = "서버 저장소 owner/name. 2026-07-15 이전 생성이라 OIDC sub가 이름 기반이다(운영 deploy 롤과 같은 규칙)"
  type        = string
  default     = "organic-agent/organic-agent-server"
}

variable "server_repository_id" {
  description = "organic-agent-server의 immutable repository ID"
  type        = string
  default     = "1297201474"
}

variable "ai_oidc_subject_prefix" {
  description = "AI 저장소 OIDC sub의 immutable 접두사(`:ref:...` 앞까지). 운영 ai_github_oidc_subject와 같은 형식"
  type        = string
  default     = "repo:organic-agent@299031009/organic-agent-ai@1336874708"
}

variable "ai_repository_id" {
  description = "organic-agent-ai의 immutable repository ID"
  type        = string
  default     = "1336874708"
}

variable "analysis_failure_queue_enabled" {
  description = "분석 Lambda(embedder·score·categorize)의 끝내 실패한 비동기 호출을 SQS 실패 큐로 보낼지. wes #286 (c) 2물결 — dev에서 먼저 켠다"
  type        = bool
  default     = true
}

variable "embed_result_queue_enabled" {
  description = "임베더 결과 큐 1단계(wes #286 (m)) — 결과 큐 · DLQ · writer ECR · 관리자 사진 교체 함수(embedder-admin)"
  type        = bool
  default     = true
}

variable "embedwriter_deployed" {
  description = "임베더 결과 큐 2단계 — writer 함수 · SQS 트리거 · 배치 임베더 전환(결과를 큐로, VPC 밖). writer 이미지를 ECR 에 민 뒤 true(2026-10-14 dev 배포)"
  type        = bool
  default     = true
}

variable "app_instance_type" {
  description = "ASG 앱 서버 크기 — 서버 저장소 #313 기준안 E 는 micro 였으나 메모리 관문(H5)에서 막혀 small(10-16: 유휴 GC 멈춤 최대 19.3초 · ALB 이탈로 ASG 교체)"
  type        = string
  default     = "t4g.small"
}
