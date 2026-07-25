# WES-Server의 CD(GitHub Actions)가 OIDC로 이 롤을 assume 한 뒤 SSM Run Command로
# EC2에 배포한다. 장기 액세스 키를 발급/보관할 필요가 없고, 22번 포트도 열지 않는다.
# 롤 ARN(output github_deploy_role_arn)을 서버 저장소의 AWS_DEPLOY_ROLE_ARN 시크릿에 넣는다.

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS는 GitHub OIDC를 자체 신뢰 체계로 검증하므로 thumbprint는 형식상 필요할 뿐임.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_deploy_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # main 브랜치에서 도는 워크플로우만 허용 (push, main에서의 workflow_dispatch 둘 다 이 sub).
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name_prefix        = "${local.name_prefix}-deploy-"
  assume_role_policy = data.aws_iam_policy_document.github_deploy_assume.json
}

data "aws_iam_policy_document" "github_deploy" {
  # CD가 Name 태그로 인스턴스 ID를 찾는다. Describe*는 리소스 단위 제한이 안 됨.
  statement {
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript"]
  }

  # 앱 인스턴스(Name 태그 기준)에만 명령을 보낼 수 있다.
  statement {
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Name"
      values   = ["${local.name_prefix}-app"]
    }
  }

  # 명령 결과(성공/실패, stdout/stderr) 폴링용.
  statement {
    actions   = ["ssm:GetCommandInvocation"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "deploy-via-ssm"
  role   = aws_iam_role.github_deploy.name
  policy = data.aws_iam_policy_document.github_deploy.json
}
