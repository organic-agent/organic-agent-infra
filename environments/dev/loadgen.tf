# 부하 발생기 — k6로 가상 사용자 트래픽을 dev API(ALB)에 보낸다(wes #286 R-3).
#
# 노트북에서 돌리면 집 회선 지연이 응답 시간에 섞이고, 수백 명에서는 노트북이 먼저 병목이 된다. 그래서 dev와 같은 리전·VPC의
# 공개 서브넷에 한 대 둔다. 들어오는 포트는 없고 SSM으로만 접속한다. 평소에는 꺼 두고 측정 스크립트(wes `scripts/load/user-traffic/`)가
# 켜고 끈다 — 꺼진 동안은 EBS 값만 든다. Terraform은 켜짐·꺼짐 상태를 관리하지 않는다.
#
# 결과(k6 요약 JSON)는 dev 사진 버킷의 `load-results/` 아래에만 쓸 수 있다.

variable "loadgen_enabled" {
  description = "부하 발생기 EC2를 둘지. 지우려면 false"
  type        = bool
  default     = true
}

variable "loadgen_instance_type" {
  description = "부하 발생기 크기. k6 400 VU + 응답 본문(사진 목록 200장 페이지)을 감당하는 arm64"
  type        = string
  default     = "c7g.large"
}

variable "loadgen_k6_version" {
  description = "첫 부팅에 설치할 k6 버전 — 회차끼리 같은 도구로 재려고 고정한다"
  type        = string
  default     = "v0.54.0"
}

# Amazon Linux 2023은 SSM 에이전트가 기본으로 들어 있다.
data "aws_ssm_parameter" "loadgen_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_iam_policy_document" "loadgen_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "loadgen" {
  count = var.loadgen_enabled ? 1 : 0

  name_prefix        = "${local.name_prefix}-loadgen-"
  assume_role_policy = data.aws_iam_policy_document.loadgen_assume.json
}

resource "aws_iam_role_policy_attachment" "loadgen_ssm" {
  count = var.loadgen_enabled ? 1 : 0

  role       = aws_iam_role.loadgen[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "loadgen_results" {
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${module.storage.bucket_arn}/load-results/*"]
  }
}

resource "aws_iam_role_policy" "loadgen_results" {
  count = var.loadgen_enabled ? 1 : 0

  name   = "put-load-results"
  role   = aws_iam_role.loadgen[0].id
  policy = data.aws_iam_policy_document.loadgen_results.json
}

resource "aws_iam_instance_profile" "loadgen" {
  count = var.loadgen_enabled ? 1 : 0

  name_prefix = "${local.name_prefix}-loadgen-"
  role        = aws_iam_role.loadgen[0].name
}

resource "aws_security_group" "loadgen" {
  count = var.loadgen_enabled ? 1 : 0

  name_prefix = "${local.name_prefix}-loadgen-"
  description = "k6 load generator: no inbound, outbound HTTPS to the API and package downloads"
  vpc_id      = data.aws_vpc.shared.id
}

resource "aws_vpc_security_group_egress_rule" "loadgen_all" {
  count = var.loadgen_enabled ? 1 : 0

  security_group_id = aws_security_group.loadgen[0].id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_instance" "loadgen" {
  count = var.loadgen_enabled ? 1 : 0

  ami                         = data.aws_ssm_parameter.loadgen_ami.value
  instance_type               = var.loadgen_instance_type
  subnet_id                   = local.public_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.loadgen[0].id]
  iam_instance_profile        = aws_iam_instance_profile.loadgen[0].name
  associate_public_ip_address = true

  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    cd /tmp
    curl -fsSL -o k6.tgz "https://github.com/grafana/k6/releases/download/${var.loadgen_k6_version}/k6-${var.loadgen_k6_version}-linux-arm64.tar.gz"
    tar -xzf k6.tgz
    install -m 0755 "k6-${var.loadgen_k6_version}-linux-arm64/k6" /usr/local/bin/k6
    # 400 VU가 각자 연결을 연다 — 기본 1024 파일 한도를 올린다.
    echo "* soft nofile 65535" >> /etc/security/limits.conf
    echo "* hard nofile 65535" >> /etc/security/limits.conf
  EOT

  metadata_options {
    http_tokens = "required"
  }

  tags = {
    Name = "${local.name_prefix}-loadgen"
  }

  lifecycle {
    # AMI 파라미터가 새 이미지를 가리켜도 발생기를 다시 만들지 않는다 — 도구가 같아야 회차끼리 비교된다.
    ignore_changes = [ami]
  }
}

output "loadgen_instance_id" {
  description = "부하 발생기 인스턴스 id — wes `scripts/load/user-traffic/`가 켜고 끄고 SSM으로 k6를 돌린다"
  value       = var.loadgen_enabled ? aws_instance.loadgen[0].id : null
}
