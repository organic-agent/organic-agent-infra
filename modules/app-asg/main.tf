# 공개 API 앱 서버 묶음 — ASG(서버 저장소 #313 ADR-0001). 고정 서버 한 대(modules/compute 의 aws_instance) 대신 쓴다.
#
#   대수      min 2(배포·한 대 장애에도 다른 서버가 받음) · max 3(DB 연결 예산) · CPU 목표 추적으로 늘리고 줄인다
#   새 서버    user_data 가 CD 가 올려 둔 배포 묶음(S3)·이미지 태그(SSM)로 지금 버전을 띄운다 — CD 를 기다리지 않는다
#   배포      CD(rolling-deploy.sh)가 서버마다 standby → 교체 → 복귀. 그 권한을 여기서 CD 역할에 붙인다
#   크레딧    t4g 는 버스트형이다. 표준 모드는 크레딧이 떨어지면 CPU 를 기본선(10%)에 묶어 늘리기 판단이 멈춘다 → 무제한
#
# Name 태그는 고정 서버와 같은 `<prefix>-app` 이다 — CD·측정 도구·SSM 권한 조건이 이 이름으로 서버를 찾는다.

data "aws_caller_identity" "current" {}

locals {
  name = "${var.name_prefix}-app"
}

resource "aws_launch_template" "app" {
  name_prefix            = "${local.name}-"
  image_id               = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  update_default_version = true

  iam_instance_profile {
    name = var.instance_profile_name
  }

  # 퍼블릭 IP — NAT 가 없어 나가는 길(SSM·ECR·SQS·Bedrock)이 이것뿐이다(서버 저장소 #313 03 §0-1).
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [var.security_group_id]
    delete_on_termination       = true
  }

  credit_specification {
    cpu_credits = "unlimited"
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 전용
    # 앱이 도커 브리지 네트워크의 컨테이너에서 인스턴스 프로파일 자격증명을 읽는다(compute 와 같은 이유).
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_type           = "gp3"
      volume_size           = 20
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    bundle_bucket       = var.bundle_bucket
    image_tag_parameter = var.image_tag_parameter
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = local.name }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = local.name }
  }
}

resource "aws_autoscaling_group" "app" {
  name                = local.name
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.min_size
  vpc_zone_identifier = var.subnet_ids
  target_group_arns   = [var.target_group_arn]

  # 앱이 죽은 서버도 교체한다. 첫 부팅(도커 설치 · 이미지 받기 · JVM)이 끝나기 전에 빼지 않게 유예를 길게 둔다.
  health_check_type         = "ELB"
  health_check_grace_period = var.health_check_grace_seconds
  # 막 뜬 서버의 높은 CPU 를 늘리기 판단에 넣지 않는다.
  default_instance_warmup = var.instance_warmup_seconds

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = local.name
    propagate_at_launch = true
  }

  lifecycle {
    # 대수는 목표 추적·CD 가 움직인다. apply 가 되돌리지 않게.
    ignore_changes = [desired_capacity]
  }
}

resource "aws_autoscaling_policy" "cpu" {
  name                   = "${local.name}-cpu"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.target_cpu_percent
  }
}

# --- CD(rolling-deploy.sh)가 서버를 한 대씩 빼고 넣는 권한 ---

data "aws_iam_policy_document" "deploy" {
  statement {
    sid = "DescribeForRollingDeploy"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "elasticloadbalancing:DescribeTargetHealth",
    ]
    resources = ["*"]
  }

  statement {
    sid = "RollThroughThisGroup"
    actions = [
      "autoscaling:EnterStandby",
      "autoscaling:ExitStandby",
      "autoscaling:UpdateAutoScalingGroup",
      # 배포 동안 CPU 줄이기 알람을 멈춘다 — min 을 1 낮추는 순간 ALARM 인 줄이기가 desired 를 1 로 내려 standby 가 거절된다(wes #313, 10-16).
      "autoscaling:SuspendProcesses",
      "autoscaling:ResumeProcesses",
    ]
    resources = [aws_autoscaling_group.app.arn]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "roll-app-asg"
  role   = var.deploy_role_name
  policy = data.aws_iam_policy_document.deploy.json
}
