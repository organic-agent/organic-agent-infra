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

resource "aws_security_group" "this" {
  name_prefix = "${var.name_prefix}-"
  description = "WES admin: no public ingress; tailnet access terminates in tailscaled"
  vpc_id      = var.vpc_id

  tags = {
    Name = var.name_prefix
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Tailscale control/DERP, SSM, 패키지 설치, 컨테이너 pull, ACME API에 필요하다.
# 인바운드는 한 줄도 만들지 않아 퍼블릭 IP에 서비스가 열리지 않는다.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  description       = "Outbound for Tailscale, SSM, package repositories and ACME"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
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
  name_prefix        = "${var.name_prefix}-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "bootstrap_secret" {
  statement {
    sid       = "ReadOnlyTailscaleBootstrapKey"
    actions   = ["ssm:GetParameter"]
    resources = [var.tailscale_auth_parameter_arn]
  }

  dynamic "statement" {
    for_each = var.tailscale_auth_kms_key_arn == null ? [] : [var.tailscale_auth_kms_key_arn]

    content {
      sid       = "DecryptTailscaleBootstrapKey"
      actions   = ["kms:Decrypt"]
      resources = [statement.value]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["ssm.${var.aws_region}.amazonaws.com"]
      }

      condition {
        test     = "StringEquals"
        variable = "kms:EncryptionContext:PARAMETER_ARN"
        values   = [var.tailscale_auth_parameter_arn]
      }
    }
  }
}

resource "aws_iam_role_policy" "bootstrap_secret" {
  name   = "read-tailscale-bootstrap-key"
  role   = aws_iam_role.this.name
  policy = data.aws_iam_policy_document.bootstrap_secret.json
}

# Spring Cloud AWS와 SDK가 관리자 전용 prefix, 사진 객체, 임베딩 함수에만 접근한다.
# 공개 앱의 /wes/prod OAuth/JWT 설정이나 다른 S3/Lambda에는 권한이 없다.
data "aws_iam_policy_document" "admin_api_runtime" {
  statement {
    sid = "ReadAdminRuntimeParameters"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [
      var.runtime_parameter_prefix_arn,
      "${var.runtime_parameter_prefix_arn}/*",
    ]
  }

  statement {
    sid = "ManagePhotoObjects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${var.photo_bucket_arn}/*"]
  }

  statement {
    sid       = "InvokeEmbedder"
    actions   = ["lambda:InvokeFunction"]
    resources = [var.embedding_function_arn]
  }

  dynamic "statement" {
    for_each = var.runtime_kms_key_arn == null ? [] : [var.runtime_kms_key_arn]

    content {
      sid       = "DecryptAdminRuntimeParameters"
      actions   = ["kms:Decrypt"]
      resources = [statement.value]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["ssm.${var.aws_region}.amazonaws.com"]
      }

      condition {
        test     = "StringLike"
        variable = "kms:EncryptionContext:PARAMETER_ARN"
        values   = ["${var.runtime_parameter_prefix_arn}/*"]
      }
    }
  }
}

resource "aws_iam_role_policy" "admin_api_runtime" {
  name   = "admin-api-runtime"
  role   = aws_iam_role.this.name
  policy = data.aws_iam_policy_document.admin_api_runtime.json
}

# Caddy에는 ACME DNS-01에 필요한 단일 TXT 이름 변경만 허용한다. hosted zone ID를
# Caddyfile에 직접 주입하므로 계정 전체 hosted zone 목록 권한은 필요 없다.
data "aws_iam_policy_document" "dns01" {
  statement {
    sid       = "ReadZoneRecords"
    actions   = ["route53:ListResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${var.zone_id}"]
  }

  statement {
    sid       = "ReadDnsChangeStatus"
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }

  statement {
    sid       = "ChangeOnlyAdminAcmeTxt"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${var.zone_id}"]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["TXT"]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsActions"
      values   = ["CREATE", "UPSERT", "DELETE"]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = ["_acme-challenge.${var.fqdn}"]
    }
  }
}

resource "aws_iam_role_policy" "dns01" {
  name   = "manage-admin-acme-dns01"
  role   = aws_iam_role.this.name
  policy = data.aws_iam_policy_document.dns01.json
}

resource "aws_iam_instance_profile" "this" {
  name_prefix = "${var.name_prefix}-"
  role        = aws_iam_role.this.name
}

locals {
  # Docker 29는 --internal network의 published host port를 실제로 만들지 않는다.
  # BackOffice는 외부 route를 얻지 않은 채 고정 internal IP만 사용하고, host Caddy가
  # 이 주소로 직접 reverse proxy한다.
  backoffice_internal_ip = cidrhost(var.internal_network_subnet, 10)

  caddyfile = templatefile("${path.module}/templates/Caddyfile.tftpl", {
    app_host         = local.backoffice_internal_ip
    app_port         = var.app_port
    fqdn             = var.fqdn
    proxy_https_port = var.proxy_https_port
    zone_id          = var.zone_id
  })

  caddy_service = templatefile("${path.module}/templates/caddy.service.tftpl", {
    aws_region = var.aws_region
  })

  runtime_host_script = templatefile("${path.module}/templates/runtime_host.sh.tftpl", {
    caddyfile_base64        = base64encode(local.caddyfile)
    deploy_lock_path        = var.deploy_lock_path
    internal_network_name   = var.internal_network_name
    internal_network_subnet = var.internal_network_subnet
    runtime_network_name    = var.runtime_network_name
    runtime_network_subnet  = var.runtime_network_subnet
  })
}

resource "aws_instance" "this" {
  ami                         = data.aws_ami.ubuntu_arm64.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    aws_region                    = var.aws_region
    caddy_route53_version         = var.caddy_route53_version
    caddy_service_base64          = base64encode(local.caddy_service)
    caddy_version                 = var.caddy_version
    caddyfile_base64              = base64encode(local.caddyfile)
    runtime_host_script_base64    = base64encode(local.runtime_host_script)
    proxy_https_port              = var.proxy_https_port
    tailscale_auth_parameter_name = var.tailscale_auth_parameter_name
    tailscale_hostname            = var.tailscale_hostname
  })

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
    # 관리자 API 컨테이너의 SDK가 인스턴스 역할을 사용한다. BackOffice는 external routing이
    # 없는 internal network에만 붙이고 IMDS 목적지를 host firewall에서도 차단한다.
    http_put_response_hop_limit = 2
    http_protocol_ipv6          = "disabled"
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 20
  }

  tags = {
    Name  = var.name_prefix
    Issue = "WES-253"
  }

  # 이 노드의 Tailscale identity와 IP는 루트 볼륨에 있다. Canonical이 새 AMI를 공개하거나
  # bootstrap 템플릿이 바뀌었다는 이유로 교체·재시작하면 일회용 auth key와 DNS가 동시에
  # 깨질 수 있다. AMI와 bootstrap 변경은 새 키를 준비한 명시적 교체 작업에서만 반영한다.
  # OS 보안 업데이트는 unattended-upgrades가 처리한다.
  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

# 기존 인스턴스는 Tailscale identity 보존을 위해 user_data 변경을 무시한다. 따라서 같은
# idempotent 스크립트를 SSM Association으로도 적용해 network·firewall·flock 계약을 갱신한다.
resource "aws_ssm_association" "runtime_host" {
  name             = "AWS-RunShellScript"
  association_name = "${var.name_prefix}-runtime-host"

  parameters = {
    commands = "printf '%s' '${base64encode(local.runtime_host_script)}' | base64 -d > /usr/local/sbin/configure-wes-admin-runtime && chmod 0755 /usr/local/sbin/configure-wes-admin-runtime && /usr/local/sbin/configure-wes-admin-runtime"
  }

  targets {
    key    = "InstanceIds"
    values = [aws_instance.this.id]
  }

  depends_on = [aws_iam_role_policy_attachment.ssm_core]
}

# 첫 apply에서 서버를 tailnet에 가입시킨 뒤 tailscale ip -4 결과를 입력하고 두 번째
# apply에서 만든다. 공개 DNS에 CGNAT 주소가 보여도 인터넷에서는 라우팅되지 않는다.
resource "aws_route53_record" "admin" {
  count = var.tailscale_ipv4 == null ? 0 : 1

  zone_id = var.zone_id
  name    = var.fqdn
  type    = "A"
  ttl     = 60
  records = [var.tailscale_ipv4]
}
