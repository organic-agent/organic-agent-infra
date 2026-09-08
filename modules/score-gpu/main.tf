# score GPU 워커 풀 — 1단계: AMI 파이프라인(계획 docs/pipeline-v2-infra-plan.md §4.1 위쪽 절반, PR-3b).
#
# EC2 Image Builder가 AL2023 위에 NVIDIA 드라이버 · Docker · nvidia-container-toolkit · 워커 systemd 유닛을 구워
# AMI를 만든다. 코드 이미지(ECR wes-score:gpu)는 굽지 않고 워커가 부팅 때 pull 한다 — 드라이버와 코드의 갱신
# 주기가 다르기 때문이다(결정 B, §4.3). 파이프라인에는 schedule이 없다. 드라이버·베이스를 올릴 때만 사람이
# 돌리고, 나온 AMI ID를 gpu_ami_id에 박는 PR을 낸다(docs/runbook.md "GPU AMI").
#
# 워커 인스턴스 2대 · 워커 롤 · GPU SG · 유휴 정지 알람은 PR-3c — AMI가 있어야 인스턴스를 만들 수 있다.
#
# Packer가 아니라 Image Builder인 이유(결정 I): CI(OIDC 롤)는 plan/apply만 한다는 규칙을 지키려면 빌드 인스턴스를
# 띄우는 권한을 CI에 주지 않아야 하고, Image Builder는 그 일을 서비스 연결 역할이 한다.

locals {
  name        = "${var.name_prefix}-score-gpu"
  score_image = "${var.score_repository_url}:${var.score_image_tag}"

  # 부모 이미지는 Image Builder가 관리하는 AL2023 x86 최신. `x.x.x`는 빌드 시점에 풀리는 와일드카드라 state에 그대로
  # 남고, 베이스 AMI가 갱신돼도 plan에 드리프트가 나지 않는다(data "aws_ami" most_recent였다면 레시피가 매번 replace).
  parent_image = "arn:aws:imagebuilder:${data.aws_region.current.name}:aws:image/amazon-linux-2023-x86/x.x.x"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# --- 서비스 연결 역할 (결정 H) ---
#
# 계정에 둘 다 없다(2026-09-08 확인). 코드로 만들어 destroy 뒤 재배포 때 빠뜨리지 않는다. tf_apply에는 이 두 ARN에
# 한정한 생성·삭제 권한이 있다(#39, modules/github-actions ServiceLinkedRolesForScoreGpu).

# Image Builder가 빌드 인스턴스를 띄우고 AMI를 만들 때 쓴다.
resource "aws_iam_service_linked_role" "imagebuilder" {
  aws_service_name = "imagebuilder.amazonaws.com"
  description      = "wes score GPU AMI pipeline (modules/score-gpu)"
}

# CloudWatch 알람의 EC2 정지 액션(PR-3c의 유휴 정지 알람, 결정 L)이 이 역할로 인스턴스를 정지시킨다.
# 권한은 계정 전체 ec2:StopInstances지만 쓰는 주체는 이 모듈의 알람뿐이고, 알람은 InstanceId dimension으로
# GPU 인스턴스 하나씩만 가리킨다(계획 §4.5). 알람보다 먼저 만들어 두면 3c의 첫 apply에서 액션 검증에 걸리지 않는다.
resource "aws_iam_service_linked_role" "cloudwatch_events" {
  aws_service_name = "events.amazonaws.com"
  description      = "EC2 stop action of the wes score GPU idle alarm (modules/score-gpu)"
}

# --- 빌드 인스턴스 롤 ---
#
# 이름이 name_prefix로 시작해야 한다: tf_apply의 IAM 쓰기 울타리가 `wes-*`이고, Image Builder가 이 롤을 EC2에
# 넘길 때의 PassRole 검사(iam:PassedToService = ec2.amazonaws.com)도 같은 접두사 문장으로 통과한다.

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "builder" {
  name_prefix        = "${local.name}-builder-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = {
    Name = "${local.name}-builder"
  }
}

# Image Builder 빌드 인스턴스의 표준 권한(빌드 로그 · 컴포넌트 다운로드) + SSM(AWSTOE가 SSM 에이전트로 명령을 받는다).
resource "aws_iam_role_policy_attachment" "builder_imagebuilder" {
  role       = aws_iam_role.builder.name
  policy_arn = "arn:aws:iam::aws:policy/EC2InstanceProfileForImageBuilder"
}

resource "aws_iam_role_policy_attachment" "builder_ssm_core" {
  role       = aws_iam_role.builder.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "builder" {
  name_prefix = "${local.name}-builder-"
  role        = aws_iam_role.builder.name
}

# 빌드 인스턴스 보안 그룹. 인바운드 0(접속은 SSM), 이그레스 전부(dnf · NVIDIA 저장소 · SSM · Image Builder).
# 워커 풀의 SG는 RDS 규칙이 참조해야 하므로 modules/security에 따로 만든다(PR-3c).
resource "aws_security_group" "builder" {
  name_prefix = "${local.name}-builder-"
  description = "Image Builder build instance for the score GPU AMI: no ingress, all egress"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name}-builder"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# --- 컴포넌트 · 레시피 ---
#
# 컴포넌트와 레시피는 불변이다. 내용이 바뀌면 version을 올려 새 버전을 만들고(create_before_destroy), 파이프라인이
# 새 레시피를 가리키게 된다. 같은 version으로 내용만 바꾸면 apply가 "already exists"로 실패한다.

resource "aws_imagebuilder_component" "nvidia_docker" {
  name                  = "${local.name}-nvidia-docker"
  version               = var.component_version
  platform              = "Linux"
  supported_os_versions = ["Amazon Linux 2023"]
  description           = "NVIDIA driver ${var.nvidia_driver_branch} + Docker + nvidia-container-toolkit + wes-score worker unit"

  data = templatefile("${path.module}/components/nvidia-docker.yaml.tftpl", {
    component_name           = "${local.name}-nvidia-docker"
    nvidia_driver_branch     = var.nvidia_driver_branch
    nvidia_driver_min_major  = var.nvidia_driver_min_major
    score_image              = local.score_image
    aws_region               = data.aws_region.current.name
    parameter_prefix         = var.parameter_prefix
    worker_idle_stop_seconds = var.worker_idle_stop_seconds
    env_script               = file("${path.module}/files/wes-score-env.sh")
    pull_script              = file("${path.module}/files/wes-score-pull.sh")
    failsafe_script          = file("${path.module}/files/wes-score-failsafe.sh")
    service_unit             = file("${path.module}/files/wes-score.service")
    failsafe_unit            = file("${path.module}/files/wes-score-failsafe.service")
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_imagebuilder_image_recipe" "this" {
  name         = local.name
  version      = var.recipe_version
  parent_image = local.parent_image
  description  = "AL2023 + NVIDIA ${var.nvidia_driver_branch} + Docker + nvidia-container-toolkit for wes-score GPU workers"

  component {
    component_arn = aws_imagebuilder_component.nvidia_docker.arn
  }

  # AL2023 x86 루트 디바이스. 드라이버·툴킷·Docker에 4GB 남짓, 워커 이미지(4.2GB) pull 자리까지 30GB.
  block_device_mapping {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  # 워커 인스턴스는 SSM으로만 접속하므로 에이전트를 남긴다(기본값이지만 의도를 적어 둔다).
  systems_manager_agent {
    uninstall_after_build = false
  }

  lifecycle {
    create_before_destroy = true
  }
}

# --- 빌드 환경 · 배포 · 파이프라인 ---

resource "aws_imagebuilder_infrastructure_configuration" "this" {
  name                          = local.name
  description                   = "Build/test instance for the score GPU AMI (${var.build_instance_type}, public subnet, SSM only)"
  instance_profile_name         = aws_iam_instance_profile.builder.name
  instance_types                = [var.build_instance_type]
  subnet_id                     = var.subnet_id
  security_group_ids            = [aws_security_group.builder.id]
  terminate_instance_on_failure = true

  instance_metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # 빌드 인스턴스 태그. `Name`은 Image Builder가 예약해 자기가 붙이므로(#49) 넣으면 400이다.
  resource_tags = {
    Role     = "score-gpu-ami-build"
    Pipeline = local.name
  }

  # 서비스 연결 역할이 없으면 CreateInfrastructureConfiguration이 거부된다. 프로파일에 롤이 붙기 전에
  # 만들어지면 첫 빌드가 PassRole에서 실패하므로 부착도 기다린다.
  depends_on = [
    aws_iam_service_linked_role.imagebuilder,
    aws_iam_role_policy_attachment.builder_imagebuilder,
    aws_iam_role_policy_attachment.builder_ssm_core,
  ]
}

resource "aws_imagebuilder_distribution_configuration" "this" {
  name        = local.name
  description = "score GPU AMI in ${data.aws_region.current.name}"

  distribution {
    region = data.aws_region.current.name

    ami_distribution_configuration {
      name        = "${local.name}-{{ imagebuilder:buildDate }}"
      description = "wes score GPU worker AMI (NVIDIA ${var.nvidia_driver_branch}, Docker, wes-score unit)"

      ami_tags = {
        Name = "${local.name}-ami"
        Role = "score-gpu-ami"
      }
    }
  }
}

# schedule 없음 — 수동 실행. 매 빌드가 g6.xlarge 두 번(빌드·테스트) 30분 안팎이고 인스턴스 replace로 이어지므로
# 사람이 결정한다: `aws imagebuilder start-image-pipeline-execution --image-pipeline-arn <output>`.
resource "aws_imagebuilder_image_pipeline" "this" {
  name                             = local.name
  description                      = "Manual: bake the score GPU worker AMI. Put the resulting AMI ID into gpu_ami_id."
  image_recipe_arn                 = aws_imagebuilder_image_recipe.this.arn
  infrastructure_configuration_arn = aws_imagebuilder_infrastructure_configuration.this.arn
  distribution_configuration_arn   = aws_imagebuilder_distribution_configuration.this.arn
  status                           = "ENABLED"
  enhanced_image_metadata_enabled  = true

  # test 단계: 완성된 AMI로 새 인스턴스를 띄워 컴포넌트의 test phase(드라이버·런타임·유닛)를 돌린다.
  # 빌드 인스턴스에서의 validate와 달리 "재부팅한 새 머신에서도 사는지"를 본다. 비용은 g6.xlarge 10분 남짓.
  image_tests_configuration {
    image_tests_enabled = true
    timeout_minutes     = 60
  }

  tags = {
    Name = local.name
  }
}
