# 로그 수집·조회 서버. Loki(수집) + Grafana(조회) + Caddy(TLS)를 docker compose로 한 인스턴스에 띄운다.
#
# ALB 뒤에 두지 않고 EIP로 직결한다. 앱 ALB와 운명을 같이하지 않게 하고, 호스트 라우팅·타깃
# 그룹·ACM 확장을 들이지 않기 위해서다. TLS는 인스턴스 위 Caddy가 Let's Encrypt로 받는다.

locals {
  fqdn = "${var.subdomain}.${var.zone_name}"

  # 앱은 퍼블릭 도메인이 아니라 프라이빗 IP로 보낸다. 3100 인그레스가 앱 SG 참조 규칙인데,
  # SG 참조는 VPC 안 프라이빗 경로에서만 매칭된다 — 퍼블릭 IP로 나가면 IGW를 돌아 들어와 막힌다.
  loki_push_url = "http://${aws_instance.this.private_ip}:${var.loki_port}/loki/api/v1/push"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# arm64 필터 필수: x86_64 AMI는 t4g에서 부팅 안 됨. (modules/compute와 같은 필터)
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

# --- IAM ---

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
  name_prefix        = "${var.name_prefix}-monitoring-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# SSH 대신 Session Manager로 접속.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Grafana admin 비밀번호만 읽는다. 앱 프리픽스(/wes/prod)는 읽지 않는다 — 이 서버가 뚫려도
# DB 비밀번호·OAuth 시크릿까지 같이 새지 않게 경계를 분리해 둔다.
data "aws_iam_policy_document" "read_monitoring_parameters" {
  statement {
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${var.monitoring_parameter_prefix}",
      "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${var.monitoring_parameter_prefix}/*",
    ]
  }
}

resource "aws_iam_role_policy" "read_monitoring_parameters" {
  name   = "read-monitoring-parameters"
  role   = aws_iam_role.this.name
  policy = data.aws_iam_policy_document.read_monitoring_parameters.json
}

resource "aws_iam_instance_profile" "this" {
  name_prefix = "${var.name_prefix}-monitoring-"
  role        = aws_iam_role.this.name
}

# --- 인스턴스 ---

resource "aws_instance" "this" {
  ami                    = data.aws_ami.ubuntu_arm64.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.this.name

  # 부팅 즉시 인터넷이 필요하다(apt, 이미지 풀). EIP는 인스턴스가 뜬 뒤에야 붙일 수 있어서
  # 자동 퍼블릭 IP를 켜두고, EIP 연결이 그 IP를 대체한다.
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    fqdn                   = local.fqdn
    aws_region             = data.aws_region.current.name
    grafana_password_param = "${var.monitoring_parameter_prefix}/grafana.admin-password"
    loki_port              = var.loki_port
    loki_retention         = var.loki_retention
    loki_image             = var.loki_image
    grafana_image          = var.grafana_image
    caddy_image            = var.caddy_image
  })

  # user_data는 첫 부팅에만 돈다. 스크립트를 고쳐도 기존 인스턴스는 모르니,
  # 반영하려면 인스턴스를 교체해야 한다(보관 중인 로그는 retention 안쪽이면 사라진다).
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required" # IMDSv2 전용
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20 # 로그는 retention(기본 7일)으로 묶여 있어 이 안에서 돈다
  }

  tags = {
    Name = "${var.name_prefix}-monitoring"
  }
}

# Let's Encrypt가 A 레코드로 찾아오는 대상이라 IP가 바뀌면 안 된다. 앱 EC2와 달리 EIP를 쓴다.
resource "aws_eip" "this" {
  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-monitoring"
  }
}

resource "aws_eip_association" "this" {
  instance_id   = aws_instance.this.id
  allocation_id = aws_eip.this.id
}

# --- DNS ---

resource "aws_route53_record" "this" {
  zone_id = var.zone_id
  name    = local.fqdn
  type    = "A"
  ttl     = 60
  records = [aws_eip.this.public_ip]
}

# --- 앱에 알려줄 값 ---

# 앱(logback Loki appender)이 부팅 시 다른 설정과 함께 읽는다. 인스턴스가 재생성돼 프라이빗 IP가
# 바뀌면 apply가 이 값을 갱신하지만, 이미 떠 있는 앱은 재시작해야 새 주소를 본다.
resource "aws_ssm_parameter" "loki_push_url" {
  name  = "${var.app_parameter_prefix}/app.logging.loki-url"
  type  = "String"
  value = local.loki_push_url
}
