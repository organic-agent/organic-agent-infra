locals {
  name_prefix = "wes"

  # 파라미터 네이밍 컨벤션: /wes/<환경>/<스프링 프로퍼티>, 환경은 local/prod 두 개.
  # url/username은 Terraform이 자동 생성, password는 밖에서 수동 관리 (docs/runbook.md 참고).
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

# 수동 등록 파라미터다(docs/deploy-order.md의 [2]). 없으면 여기서 apply가 멈추는데,
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

  interface_endpoint_subnet_indexes = var.interface_endpoint_subnet_indexes
}

module "security" {
  source = "./modules/security"

  name_prefix      = local.name_prefix
  vpc_id           = module.network.vpc_id
  app_port         = var.app_port
  ssh_allowed_cidr = var.ssh_allowed_cidr
}

module "storage" {
  source = "./modules/storage"

  name_prefix      = local.name_prefix
  parameter_prefix = var.parameter_prefix
  app_role_name    = module.compute.instance_role_name
  web_origins      = local.web_origins
}

# 로컬 개발용 사진 버킷. 앱은 이미지 바이트를 만지지 않고 브라우저가 S3에 직접 PUT/GET 하므로
# S3만은 로컬 대체물(MinIO 등)이 없다 — 앱의 S3 클라이언트에 엔드포인트 오버라이드가 없기도 하다.
# 운영 버킷을 같이 쓰면 로컬 pg의 갤러리 id가 운영과 겹칠 때 `galleries/{id}/…` 키 공간이 섞이므로
# 버킷을 따로 판다. 임베더·AI CLI를 노트북에서 돌릴 때도 이 버킷을 읽는다.
#
# 같은 모듈의 두 번째 인스턴스다. 이름에 환경(dev)이 들어가고, /wes/local/app.storage.bucket에
# 기록되어 `bootRun --spring.profiles.active=local`이 자동으로 집는다. 인스턴스 롤 정책은 없다.
module "storage_dev" {
  source = "./modules/storage"

  name_prefix      = "${local.name_prefix}-dev"
  parameter_prefix = var.local_parameter_prefix
  app_role_name    = null
  web_origins      = var.local_web_origins
}

# AI 분석 Lambda 셋(embedder → score → categorize). 서버의 analysis 도메인이 단계마다 부른다.
# 코드는 AI 저장소(organic-agent-ai)의 embedder/ · score/ · categorize/ 이고, 셋의 실행 모양
# (DB 서브넷·보안 그룹·DB_*/S3_BUCKET·수동 DB_PASSWORD)이 같아 모듈 하나가 맵으로 만든다.
module "analysis" {
  source = "./modules/analysis"

  name_prefix      = local.name_prefix
  parameter_prefix = var.parameter_prefix

  # RDS와 같은 DB 서브넷에 들어간다. 이 출력이 S3 게이트웨이와 lambda·bedrock-runtime 인터페이스
  # 엔드포인트를 기다리므로, 함수가 만들어질 때는 이미 사진·Lambda API·Bedrock에 닿을 경로가 있다.
  # 보안 그룹은 이름이 embedder지만 인그레스 없음 + 이그레스 전부라 셋이 같은 규칙이고, RDS 보안
  # 그룹이 이미 이 그룹을 인그레스 소스로 받는다 — 함수마다 그룹을 나눠 얻는 것이 없다.
  subnet_ids        = module.network.db_subnet_ids
  security_group_id = module.security.embedder_security_group_id
  app_role_name     = module.compute.instance_role_name

  photo_bucket_name = module.storage.bucket_name
  photo_bucket_arn  = module.storage.bucket_arn

  # 비밀번호는 넘기지 않는다. 원래는 RDS IAM 인증이었고, 지금은 apply 밖에서 주입한다
  # (docs/runbook.md "비밀번호 주입"·"SCP 차단").
  db_host              = module.database.address
  db_port              = module.database.port
  db_name              = module.database.db_name
  db_resource_id       = module.database.resource_id
  embedder_db_username = var.embedder_db_username
  analysis_db_username = var.analysis_db_username

  image_tag = var.lambda_image_tag

  embedder_memory_mb  = var.embedder_memory_mb
  embedder_batch_size = var.embedder_batch_size
  embedding_dimension = var.embedding_dimension

  score_memory_mb                           = var.score_memory_mb
  score_ephemeral_storage_mb                = var.score_ephemeral_storage_mb
  score_reserved_concurrent_executions      = var.score_reserved_concurrent_executions
  categorize_memory_mb                      = var.categorize_memory_mb
  categorize_reserved_concurrent_executions = var.categorize_reserved_concurrent_executions
  bedrock_model_id                          = var.bedrock_model_id
}

# score GPU 워커 풀 — 1단계 AMI 파이프라인(Image Builder). 계획 docs/pipeline-v2-infra-plan.md §4, PR-3b.
# 워커 인스턴스·롤·SG·유휴 정지 알람은 AMI가 나온 뒤 PR-3c에서 이 모듈에 더한다. 코드 이미지는 AMI에 굽지 않고
# 부팅 때 ECR wes-score:gpu(이동 태그)를 pull 한다 — 그래서 analysis 모듈의 리포지토리 URL을 받는다.
module "score_gpu" {
  source = "./modules/score-gpu"

  name_prefix          = local.name_prefix
  vpc_id               = module.network.vpc_id
  subnet_id            = module.network.public_subnet_ids[0]
  score_repository_url = module.analysis.repository_urls["score"]
  parameter_prefix     = var.parameter_prefix

  worker_idle_stop_seconds = var.gpu_worker_idle_stop_seconds
  gpu_ami_id               = var.gpu_ami_id
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
  instance_id       = module.compute.instance_id
  app_port          = var.app_port
  health_check_path = var.health_check_path
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
  worker_oidc_subject    = var.ai_github_oidc_subject
  worker_repository_id   = var.ai_github_repository_id
  worker_repository_arns = values(module.analysis.repository_arns)
  worker_function_arns   = values(module.analysis.function_arns)
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
