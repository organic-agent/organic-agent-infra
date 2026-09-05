# arm64 필터 필수: x86_64 AMI는 t4g에서 부팅 안 됨.
data "aws_ami" "ubuntu_arm64" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "this" {
  key_name   = "${var.name_prefix}-key"
  public_key = var.ssh_public_key
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name_prefix        = "${var.name_prefix}-ec2-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# SSH 안 될 때 대비용으로 Session Manager 접근 허용.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 앱(Spring Cloud AWS)이 이 환경 프리픽스 아래의 파라미터를 직접 읽음.
# GetParametersByPath는 경로 자체를, GetParameter(s)는 개별 파라미터를 대상으로 함.
data "aws_iam_policy_document" "read_app_parameters" {
  statement {
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [
      var.app_parameter_prefix_arn,
      "${var.app_parameter_prefix_arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "read_app_parameters" {
  name   = "read-app-parameters"
  role   = aws_iam_role.this.name
  policy = data.aws_iam_policy_document.read_app_parameters.json
}

# 앱의 recommendation 도메인이 추천 이유 문장과 비교샷 판정에 Bedrock을 부른다(app.llm.enabled=true일 때).
# 크로스 리전 프로필 호출은 프로필 ARN(이 계정·리전)과 그 프로필이 보내는 기반 모델 ARN(리전 무관) 양쪽에
# InvokeModel이 있어야 한다 — modules/analysis의 categorize와 같은 규칙. 스트리밍은 쓰지 않는다.
# 이 정책이 없으면 앱은 기동은 되지만 호출마다 AccessDenied를 받아 템플릿 문장으로 폴백한다.
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # `global.anthropic.claude-sonnet-4-6` → 기반 모델 `anthropic.claude-sonnet-4-6`. `global.` 프로필의 기반 모델 ARN은
  # 리전 자리가 빈 값이라 `*`로 받는다.
  bedrock_foundation_model_id = replace(var.bedrock_model_id, "/^(global|us|eu|apac|jp|au|ca)\\./", "")
}

data "aws_iam_policy_document" "invoke_llm" {
  statement {
    sid     = "InvokeRecommendationModel"
    actions = ["bedrock:InvokeModel"]
    resources = [
      "arn:aws:bedrock:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.bedrock_model_id}",
      "arn:aws:bedrock:*::foundation-model/${local.bedrock_foundation_model_id}",
    ]
  }
}

resource "aws_iam_role_policy" "invoke_llm" {
  name   = "invoke-llm"
  role   = aws_iam_role.this.name
  policy = data.aws_iam_policy_document.invoke_llm.json
}

resource "aws_iam_instance_profile" "this" {
  name_prefix = "${var.name_prefix}-ec2-"
  role        = aws_iam_role.this.name
}

resource "aws_instance" "this" {
  ami                    = data.aws_ami.ubuntu_arm64.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  key_name               = aws_key_pair.this.key_name
  iam_instance_profile   = aws_iam_instance_profile.this.name

  # 퍼블릭 IP 사용 (EIP 없음) — stop/start 하면 바뀜; ssh 접속 주소만 영향받고
  # OAuth redirect URI는 ALB 도메인으로 리졸브되니까 무관함.
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {})

  metadata_options {
    http_tokens = "required" # IMDSv2 전용
    # 앱이 도커 브리지 네트워크의 컨테이너에서 인스턴스 프로파일 자격증명을 읽는다.
    # 기본값 1이면 브리지에서 홉이 소진돼 IMDS 응답이 컨테이너까지 못 온다.
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
  }

  tags = {
    Name = "${var.name_prefix}-app"
  }
}
