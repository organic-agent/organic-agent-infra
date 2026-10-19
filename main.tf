locals {
  name_prefix = "wes"
  # score GPU 워커 인스턴스의 Name 태그 — 앱 롤의 Start/Stop 조건(compute)과 인스턴스 태그(score-gpu)가 같은 값을 쓴다.
  score_gpu_tag_name = "wes-score-gpu"

  # 파라미터 네이밍 컨벤션: /wes/<환경>/<스프링 프로퍼티>, 환경은 local/prod 두 개.
  # url/username은 Terraform이 자동 생성, password는 밖에서 수동 관리 (docs/runbooks/runbook.md 참고).
  parameter_prefix_arn       = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.parameter_prefix}"
  db_password_parameter_name = "${var.parameter_prefix}/spring.datasource.password"
  db_password_parameter_arn  = "${local.parameter_prefix_arn}/spring.datasource.password"

  # S3 버킷의 CORS 허용 오리진. 앱이 읽는 공개 오리진에 관리자 웹 오리진을 합친다.
  #
  # 값을 변수로 또 두지 않는 이유: 브라우저는 API와 S3 양쪽에 요청을 보내고, 두 목록이
  # 어긋나면 로그인은 되는데 업로드만 프리플라이트에서 죽는다. 원인이 CORS라는 걸
  # 알아채기 어려운 종류의 고장이라, 애초에 갈릴 수 없게 한 곳에서 읽는다.
  admin_web_origin   = "https://${local.admin_fqdn}"
  public_web_origins = [for o in split(",", data.aws_ssm_parameter.cors_allowed_origins.value) : trimspace(o) if trimspace(o) != ""]
  web_origins        = distinct(concat(local.public_web_origins, [local.admin_web_origin]))
}

data "aws_caller_identity" "current" {}

# 수동 등록 파라미터다(docs/runbooks/deploy-order.md의 [2]). 없으면 여기서 apply가 멈추는데,
# 그편이 CORS가 반쯤 맞는 스택을 세우는 것보다 낫다.
data "aws_ssm_parameter" "cors_allowed_origins" {
  name = "${var.parameter_prefix}/cors.allowed-origins"
}

# 호스티드 존은 dns/ 스택 소유 (공유 리소스라 이 스택을 destroy 해도 남아있음).
data "aws_route53_zone" "this" {
  name = var.zone_name
}

module "network" {
  source = "./modules/network"

  name_prefix         = local.name_prefix
  vpc_cidr            = var.vpc_cidr
  azs                 = var.azs
  public_subnet_cidrs = var.public_subnet_cidrs
  db_subnet_cidrs     = var.db_subnet_cidrs
  bedrock_vpc_cidr    = var.bedrock_vpc_cidr

  providers = {
    aws         = aws
    aws.bedrock = aws.bedrock
  }
}

module "security" {
  source = "./modules/security"

  name_prefix      = local.name_prefix
  vpc_id           = module.network.vpc_id
  app_port         = var.app_port
  ssh_allowed_cidr = var.ssh_allowed_cidr

  # ALB → 앱 관리 포트(헬스). 지금은 규칙만 더한다 — 대상 그룹 헬스를 8090 으로 바꾸는 것은 서버가 8090 을 연 뒤(서버 저장소 #313 P1b).
  health_check_port = var.health_check_port
}

module "storage" {
  source = "./modules/storage"

  name_prefix      = local.name_prefix
  parameter_prefix = var.parameter_prefix
  app_role_name    = module.compute.instance_role_name
  web_origins      = local.web_origins
}

# 사진 미리보기 CDN(서버 저장소 #336 ADR-0001) — 고정 주소 + 서명 쿠키. dev(img-dev, /d/ 접두)에서 실제 웹으로 검증한 뒤 같은 모듈.
# 운영은 접두 없음: 주소 https://img.easyselect.kr/previews/galleries/{id}/…, 쿠키 경로 /previews/galleries/{id}/.
# 개인키는 Terraform 밖 — SSM SecureString /wes/prod/app.storage.preview-cdn.private-key(CLI). 앱이 쓰는 것은
# app.storage.preview-cdn.enabled=true(CLI, 서버 배포 뒤)일 때뿐이다.
module "image_cdn" {
  source = "./modules/image-cdn"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name_prefix                 = local.name_prefix
  domain_name                 = "img.${var.zone_name}"
  zone_id                     = data.aws_route53_zone.this.zone_id
  cookie_domain               = var.zone_name
  bucket_id                   = module.storage.bucket_name
  bucket_arn                  = module.storage.bucket_arn
  bucket_regional_domain_name = module.storage.bucket_regional_domain_name
  public_key_pem              = file("${path.module}/preview-cdn-public.pem")
  parameter_prefix            = var.parameter_prefix
}

# 로컬 개발용 사진 버킷. 앱은 이미지 바이트를 만지지 않고 브라우저가 S3에 직접 PUT/GET 하므로
# S3만은 로컬 대체물(MinIO 등)이 없다 — 앱의 S3 클라이언트에 엔드포인트 오버라이드가 없기도 하다.
# 운영 버킷을 같이 쓰면 로컬 pg의 갤러리 id가 운영과 겹칠 때 `galleries/{id}/…` 키 공간이 섞이므로
# 버킷을 따로 판다. 임베더·AI CLI를 노트북에서 돌릴 때도 이 버킷을 읽는다.
#
# 같은 모듈의 두 번째 인스턴스다. 이름은 `wes-local-photos-<계정>`이고, /wes/local/app.storage.bucket에
# 기록되어 `bootRun --spring.profiles.active=local`이 자동으로 집는다. 인스턴스 롤 정책은 없다.
# (EC2에 올라가는 dev 서버 환경은 버킷을 따로 쓴다 — wes-dev-photos-*.)
module "storage_local" {
  source = "./modules/storage"

  name_prefix      = "${local.name_prefix}-local"
  parameter_prefix = var.local_parameter_prefix
  web_origins      = var.local_web_origins

  attach_app_role_policy = false
}

# 로컬 버킷 이름 변경(wes-dev-photos → wes-local-photos). `wes-dev-photos-<계정>`은 dev 서버 환경에 넘긴다.
# 이름이 바뀌어 버킷은 교체된다 — force_destroy라 옛 버킷의 로컬 사진은 같이 지워진다(로컬 테스트 데이터라 버린다).
# moved로 주소를 이어 /wes/local/app.storage.bucket 파라미터는 값만 바뀐다(주소째 바꾸면 같은 이름의 삭제·생성이 겹친다).
# 운영 apply가 한 번 지나가면 지워도 된다.
moved {
  from = module.storage_dev
  to   = module.storage_local
}

# AI 분석 Lambda 셋(embedder → score → categorize). 서버의 analysis 도메인이 단계마다 부른다.
# 코드는 AI 저장소(organic-agent-ai)의 embedder/ · score/ · categorize/ 이고, 셋의 실행 모양
# (DB 서브넷·보안 그룹·DB_*/S3_BUCKET·수동 DB_PASSWORD)이 같아 모듈 하나가 맵으로 만든다.
module "analysis" {
  source = "./modules/analysis"

  name_prefix      = local.name_prefix
  parameter_prefix = var.parameter_prefix

  # RDS와 같은 DB 서브넷에 들어간다. 이 출력이 S3 게이트웨이 엔드포인트와 Bedrock 리전으로 가는 피어링
  # 경로를 기다리므로, 함수가 만들어질 때는 이미 사진·Bedrock에 닿을 경로가 있다.
  # 보안 그룹은 이름이 embedder지만 인그레스 없음 + 이그레스 전부라 셋이 같은 규칙이고, RDS 보안
  # 그룹이 이미 이 그룹을 인그레스 소스로 받는다 — 함수마다 그룹을 나눠 얻는 것이 없다.
  subnet_ids        = module.network.db_subnet_ids
  security_group_id = module.security.embedder_security_group_id
  app_role_name     = module.compute.instance_role_name

  photo_bucket_name = module.storage.bucket_name
  photo_bucket_arn  = module.storage.bucket_arn

  # 비밀번호는 넘기지 않는다. 원래는 RDS IAM 인증이었고, 지금은 apply 밖에서 주입한다
  # (docs/runbooks/runbook.md "비밀번호 주입"·"SCP 차단").
  db_host              = module.database.address
  db_port              = module.database.port
  db_name              = module.database.db_name
  db_resource_id       = module.database.resource_id
  embedder_db_username = var.embedder_db_username
  analysis_db_username = var.analysis_db_username

  image_tag = var.lambda_image_tag

  embedder_memory_mb                      = var.embedder_memory_mb
  embedder_batch_size                     = var.embedder_batch_size
  embedder_reserved_concurrent_executions = var.embedder_reserved_concurrent_executions
  embedding_dimension                     = var.embedding_dimension

  score_memory_mb                           = var.score_memory_mb
  score_ephemeral_storage_mb                = var.score_ephemeral_storage_mb
  score_reserved_concurrent_executions      = var.score_reserved_concurrent_executions
  categorize_memory_mb                      = var.categorize_memory_mb
  categorize_reserved_concurrent_executions = var.categorize_reserved_concurrent_executions
  categorize_naming_parallel                = var.categorize_naming_parallel
  bedrock_model_id                          = var.bedrock_model_id
  bedrock_region                            = var.bedrock_region

  # wes가 읽는 GPU 워커 스위치(SSM app.analysis.gpu.enabled). 워커 풀(PR-3c) 뒤 true로.
  gpu_score_enabled = var.gpu_score_enabled

  # 끝내 실패한 비동기 호출을 SQS 실패 큐로 — wes가 바로 다시 보낸다(wes #286 (c), dev #100).
  failure_queue_enabled = var.analysis_failure_queue_enabled

  # 임베더 결과 큐(wes #286 (m), dev #104·#105) — 1단계(큐·DLQ·writer ECR·embedder-admin) 뒤 writer 이미지를 밀고
  # 2단계(writer·트리거·임베더 전환)를 켠다.
  embed_result_queue_enabled = var.embed_result_queue_enabled
  embedwriter_deployed       = var.embedwriter_deployed
}

# score GPU 워커 풀 — AMI 파이프라인(Image Builder, PR-3b) + 워커 인스턴스 2대·롤·유휴 정지 알람(PR-3c).
# 계획 docs/plans/pipeline-v2-infra-plan.md §4. 코드 이미지는 AMI에 굽지 않고 부팅 때 ECR wes-score:gpu(이동 태그)를 pull 한다 —
# 그래서 analysis 모듈의 리포지토리 URL·ARN을 받는다. 워커 SG는 RDS SG가 참조해야 해서 security 모듈에 있다.
# 켜고 끄는 것은 wes(GpuController, 태그 Name=wes-score-gpu)와 워커 자기 정지의 몫이고, 인프라는 생성 직후 정지와
# 최후 안전장치 알람만 소유한다.
module "score_gpu" {
  source = "./modules/score-gpu"

  name_prefix          = local.name_prefix
  vpc_id               = module.network.vpc_id
  subnet_id            = module.network.public_subnet_ids[0]
  score_repository_url = module.analysis.repository_urls["score"]
  score_repository_arn = module.analysis.repository_arns["score"]
  photo_bucket_arn     = module.storage.bucket_arn
  parameter_prefix     = var.parameter_prefix

  worker_idle_stop_seconds = var.gpu_worker_idle_stop_seconds
  gpu_ami_id               = var.gpu_ami_id
  worker_instance_type     = var.gpu_instance_type
  worker_subnet_ids        = zipmap(var.azs, module.network.public_subnet_ids)
  worker_security_group_id = module.security.score_gpu_security_group_id
}

module "database" {
  source = "./modules/database"

  name_prefix                = local.name_prefix
  subnet_ids                 = module.network.db_subnet_ids
  security_group_id          = module.security.rds_security_group_id
  db_name                    = var.db_name
  db_username                = var.db_username
  parameter_prefix           = var.parameter_prefix
  password_ssm_parameter_arn = local.db_password_parameter_arn
  password_wo_version        = var.db_password_version
}

module "compute" {
  source = "./modules/compute"

  name_prefix              = local.name_prefix
  subnet_id                = module.network.public_subnet_ids[0]
  security_group_id        = module.security.ec2_security_group_id
  instance_type            = var.instance_type
  ssh_public_key           = var.ssh_public_key
  app_parameter_prefix_arn = local.parameter_prefix_arn
  bedrock_model_id         = var.bedrock_model_id
  bedrock_region           = var.bedrock_region
  # score_gpu 모듈의 worker_tag_name과 같은 값. 모듈 출력을 참조하면 storage → compute → score_gpu 순환이라 문자열로 맞춘다.
  score_gpu_tag_name = local.score_gpu_tag_name

  # 앱 서버는 module.app_asg 가 맡는다(서버 저장소 #313 P1c). 이 모듈은 역할·인스턴스 프로파일·AMI·키만 준다.
  create_instance = false
}

# ASG 새 서버가 CD 없이 스스로 뜨는 데 필요한 것 — ECR wes-api · 배포 묶음 버킷 · 이미지 태그 파라미터와 그 권한(서버 저장소 #313 ADR-0001 Q7).
# 서버 저장소 cd-prod 가 이미지를 ECR 로 복사하고 묶음·태그를 올린 뒤 서버를 바꾼다. 옛 서버도 같은 역할이라 ECR 에서 받는다.
module "app_release" {
  source = "./modules/app-release"

  name_prefix        = local.name_prefix
  aws_region         = var.aws_region
  parameter_prefix   = var.parameter_prefix
  instance_role_name = module.compute.instance_role_name
  deploy_role_name   = module.github_actions.deploy_role_name
}

# 앱이 Bedrock을 부를 리전과 모델. 앱 기본값(application-variable.yml)은 서울 + `global.`이라, 여기서 덮지
# 않으면 IAM은 `us.` 프로필만 허용하는데 앱은 `global.`을 불러 호출마다 AccessDenied가 난다. 값이 IAM·Lambda와
# 같은 변수에서 나오므로 갈릴 수 없다. 앱은 부팅 때 읽으므로 값이 바뀌면 재시작해야 한다.
resource "aws_ssm_parameter" "llm_region" {
  name  = "${var.parameter_prefix}/app.llm.region"
  type  = "String"
  value = var.bedrock_region
}

resource "aws_ssm_parameter" "llm_model_id" {
  name  = "${var.parameter_prefix}/app.llm.model-id"
  type  = "String"
  value = var.bedrock_model_id
}

module "ingress" {
  source = "./modules/ingress"

  name_prefix       = local.name_prefix
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  security_group_id = module.security.alb_security_group_id
  zone_id           = data.aws_route53_zone.this.zone_id
  zone_name         = var.zone_name
  subdomain         = var.subdomain
  # 서버는 ASG 가 스스로 등록한다(서버 저장소 #313 P1c — 옛 서버 한 대를 뗐다).
  app_port          = var.app_port
  health_check_path = var.health_check_path
  health_check_port = tostring(var.health_check_port)

  # 서버 2대(ASG 가 스스로 등록)의 한 대 장애·배포 무중단 — dev(environments/dev)와 같은 값(서버 저장소 #313 ADR-0001 Q2·Q3).
  # 감지 90~95초 → 10~13초 · 새 서버 몫을 60초에 걸쳐 0에서 올림 · 빼는 서버는 진행 중 요청을 30초까지 기다림.
  health_check_interval        = 5
  health_check_timeout         = 3
  healthy_threshold            = 2
  unhealthy_threshold          = 2
  slow_start_seconds           = 60
  deregistration_delay_seconds = 30
}

# 공개 API 앱 서버 2대 — 서버 저장소 #313 ADR-0001 · 10-17 결정(small on-demand 1 + spot 1, 늘리기 끔 max 2). dev 에서 검증한 모듈 그대로.
# 처음부터 혼합으로 만든다 — 이미 있는 ASG 를 혼합으로 바꾸면 on-demand 한 대가 새 서버 준비 전에 빠진다(dev 10-18).
# 새 서버는 user_data 가 서버 저장소 cd-prod 가 올린 배포 묶음·이미지 태그로 스스로 뜬다(wes #328). Name 태그는 옛 서버와 같은 wes-app.
module "app_asg" {
  source = "./modules/app-asg"

  name_prefix           = local.name_prefix
  ami_id                = module.compute.ami_id
  instance_type         = var.instance_type
  key_name              = module.compute.key_name
  instance_profile_name = module.compute.instance_profile_name
  security_group_id     = module.security.ec2_security_group_id
  subnet_ids            = module.network.public_subnet_ids
  target_group_arn      = module.ingress.target_group_arn
  bundle_bucket         = module.app_release.bundle_bucket
  image_tag_parameter   = module.app_release.image_tag_parameter
  deploy_role_name      = module.github_actions.deploy_role_name

  spot_enabled = true
}

module "monitoring" {
  source = "./modules/monitoring"

  name_prefix       = local.name_prefix
  subnet_id         = module.network.public_subnet_ids[0]
  security_group_id = module.security.monitoring_security_group_id
  instance_type     = var.monitoring_instance_type
  key_name          = module.compute.key_name

  zone_id   = data.aws_route53_zone.this.zone_id
  zone_name = var.zone_name
  subdomain = var.monitoring_subdomain

  # Loki push URL은 앱 프리픽스에 쓰고, Grafana 비밀번호는 별도 프리픽스에서 읽는다.
  # 앱이 /wes/prod/를 통째로 읽기 때문에 Grafana 비밀번호를 거기 두면 앱 컨테이너에 노출된다.
  app_parameter_prefix        = var.parameter_prefix
  monitoring_parameter_prefix = var.monitoring_parameter_prefix
  loki_retention              = var.loki_retention
}

# GitHub Actions용 OIDC 롤 (서버/백오피스/AI CD + 이 저장소의 plan/apply). 장기 키 없음.
module "github_actions" {
  source = "./modules/github-actions"

  name_prefix          = local.name_prefix
  aws_region           = var.aws_region
  repository_owner_id  = var.github_repository_owner_id
  server_repository    = var.github_repository
  server_repository_id = var.github_repository_id
  admin_oidc_subject   = var.admin_github_oidc_subject
  admin_repository_id  = var.admin_github_repository_id
  infra_repository     = var.infra_repository
  infra_repository_id  = var.infra_github_repository_id
  app_instance_name    = "${local.name_prefix}-app"
  admin_instance_name  = "${local.name_prefix}-admin"

  # 테스트 프론트 전용 역할은 기존 서버/관리자 역할의 권한을 확장하지 않는다.
  frontend_test_oidc_subject        = var.frontend_test_github_oidc_subject
  frontend_test_repository_id       = var.frontend_test_github_repository_id
  frontend_test_instance_id         = module.frontend_test.instance_id
  frontend_test_artifact_bucket_arn = module.frontend_test.artifact_bucket_arn
  frontend_test_deploy_document_arn = module.frontend_test.deploy_document_arn

  # Lambda 셋의 배포 역할. AI 저장소 main의 deploy-lambda.yml이 assume해 바뀐 모듈만 밀고 갱신한다.
  worker_oidc_subject  = var.ai_github_oidc_subject
  worker_repository_id = var.ai_github_repository_id
  # 결과 큐(wes #286 (m))가 켜지면 writer ECR·함수와 embedder-admin 도 같은 역할이 민다(AI deploy-lambda.yml).
  worker_repository_arns = compact(concat(values(module.analysis.repository_arns), [module.analysis.embedwriter_repository_arn]))
  worker_function_arns = compact(concat(
    values(module.analysis.function_arns),
    [module.analysis.embedder_admin_function_arn, module.analysis.embedwriter_function_arn],
  ))
}

# deploy.tf에 루트 리소스로 있던 것을 모듈로 옮겼다. 주소만 바뀌고 재생성되지 않는다 —
# 배포 롤 ARN은 서버 저장소 시크릿에 박혀 있어서 재생성되면 CD가 깨진다.
moved {
  from = aws_iam_openid_connect_provider.github
  to   = module.github_actions.aws_iam_openid_connect_provider.github
}

moved {
  from = aws_iam_role.github_deploy
  to   = module.github_actions.aws_iam_role.deploy
}

moved {
  from = aws_iam_role_policy.github_deploy
  to   = module.github_actions.aws_iam_role_policy.deploy
}

# modules/embedding(임베더 하나)이 modules/analysis(Lambda 셋의 맵)로 합쳐졌다(#18). 주소만 바뀌고
# 재생성되지 않는다 — 임베더 함수는 apply 밖에서 넣은 DB_PASSWORD를 들고 운영 중이라, 재생성되면
# 그 값이 사라지고 사진 처리가 접속 단계에서 멈춘다.
moved {
  from = module.embedding.aws_ecr_repository.this
  to   = module.analysis.aws_ecr_repository.this["embedder"]
}

moved {
  from = module.embedding.aws_ecr_lifecycle_policy.this
  to   = module.analysis.aws_ecr_lifecycle_policy.this["embedder"]
}

moved {
  from = module.embedding.aws_iam_role.this
  to   = module.analysis.aws_iam_role.this["embedder"]
}

moved {
  from = module.embedding.aws_iam_role_policy_attachment.vpc_access
  to   = module.analysis.aws_iam_role_policy_attachment.vpc_access["embedder"]
}

moved {
  from = module.embedding.aws_iam_role_policy.this
  to   = module.analysis.aws_iam_role_policy.this["embedder"]
}

moved {
  from = module.embedding.aws_cloudwatch_log_group.this
  to   = module.analysis.aws_cloudwatch_log_group.this["embedder"]
}

moved {
  from = module.embedding.aws_lambda_function.this
  to   = module.analysis.aws_lambda_function.this["embedder"]
}

moved {
  from = module.embedding.aws_lambda_function_event_invoke_config.this
  to   = module.analysis.aws_lambda_function_event_invoke_config.this["embedder"]
}

moved {
  from = module.embedding.aws_cloudwatch_metric_alarm.async_event_age
  to   = module.analysis.aws_cloudwatch_metric_alarm.async_event_age["embedder"]
}

moved {
  from = module.embedding.aws_cloudwatch_metric_alarm.async_events_dropped
  to   = module.analysis.aws_cloudwatch_metric_alarm.async_events_dropped["embedder"]
}

moved {
  from = module.embedding.aws_ssm_parameter.function_name
  to   = module.analysis.aws_ssm_parameter.function_name["embedder"]
}

# 앱 롤의 invoke 정책은 이름이 invoke-embedder → invoke-analysis-functions로 바뀌어 인라인 정책이
# 교체된다(삭제 후 생성, 함수 셋 대상). ARN이 어디에도 박혀 있지 않아 영향은 없다.
moved {
  from = module.embedding.aws_iam_role_policy.app_invoke
  to   = module.analysis.aws_iam_role_policy.app_invoke
}
