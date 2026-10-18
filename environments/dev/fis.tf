# spot 회수 재현 — AWS FIS 로 dev 앱 spot 서버 한 대에 회수 예고(재조정 권고 → 2분 뒤 회수)를 보낸다(서버 저장소 #313 10-18).
#
# 진짜 회수는 언제 올지 몰라 잴 수 없다. FIS 는 EC2 가 보내는 것과 같은 신호(재조정 권고 · 회수 예고 · 종료)를 보내므로
# capacity rebalance 가 새 서버를 먼저 띄우고 옛 서버를 ALB 에서 빼는지, 그동안 사용자 요청이 실패하지 않는지를 같은 측정 도구로 잰다.
# 템플릿만 둔다 — 실행은 측정 회차가 `aws fis start-experiment --experiment-template-id <출력>` 로 한다. 두기만 하면 비용 없음.

data "aws_iam_policy_document" "fis_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["fis.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fis" {
  name_prefix        = "${local.name_prefix}-fis-"
  assume_role_policy = data.aws_iam_policy_document.fis_assume.json
}

data "aws_iam_policy_document" "fis" {
  statement {
    sid       = "FindTargets"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  # 회수 신호는 dev 앱 서버(Name 태그)에만.
  statement {
    sid       = "InterruptDevAppSpot"
    actions   = ["ec2:SendSpotInstanceInterruptions"]
    resources = ["arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Name"
      values   = ["${local.name_prefix}-app"]
    }
  }
}

resource "aws_iam_role_policy" "fis" {
  name   = "interrupt-dev-app-spot"
  role   = aws_iam_role.fis.id
  policy = data.aws_iam_policy_document.fis.json
}

resource "aws_fis_experiment_template" "app_spot_interruption" {
  description = "dev 앱 spot 서버 1대에 회수 예고 - 2분 뒤 회수"
  role_arn    = aws_iam_role.fis.arn

  stop_condition {
    source = "none"
  }

  action {
    name      = "interrupt-app-spot"
    action_id = "aws:ec2:send-spot-instance-interruptions"

    parameter {
      key   = "durationBeforeInterruption"
      value = "PT2M"
    }

    target {
      key   = "SpotInstances"
      value = "app-spot"
    }
  }

  target {
    name           = "app-spot"
    resource_type  = "aws:ec2:spot-instance"
    selection_mode = "COUNT(1)"

    resource_tag {
      key   = "Name"
      value = "${local.name_prefix}-app"
    }

    filter {
      path   = "State.Name"
      values = ["running"]
    }
  }

  tags = {
    Name = "${local.name_prefix}-app-spot-interruption"
  }
}

output "app_spot_interruption_template_id" {
  description = "spot 회수 재현 FIS 템플릿 — aws fis start-experiment --experiment-template-id <이 값>"
  value       = aws_fis_experiment_template.app_spot_interruption.id
}
