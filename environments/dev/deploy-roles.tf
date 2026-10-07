# dev CD용 GitHub OIDC 롤 둘. 운영 롤(modules/github-actions)을 넓히지 않고 따로 둔다 — 운영 롤은 main만 신뢰하고, 이 롤들은
# var.dev_branch만 신뢰하며 대상도 dev 리소스뿐이다. OIDC 프로바이더는 계정에 하나라 운영 스택 것을 읽기만 한다.
#
#   deploy        서버 저장소 dev CD — public API를 wes-dev-app에 SSM Run Command로 배포 (운영 cd.yml과 같은 흐름)
#   worker_deploy AI 저장소 dev CD   — wes-dev-* ECR에 push 하고 dev Lambda 코드 갱신. GPU 워커 이미지도 wes-dev-score에 민다
#   admin_api_deploy 서버 저장소 dev CD — 관리자 API를 wes-dev-admin에 배포 (운영 cd-prod.yml의 deploy-admin과 같은 흐름)
#   admin_deploy  백오피스 저장소 dev CD — 백오피스를 wes-dev-admin에 배포
#
# 이름이 `wes-dev-`로 시작해 운영 tf_apply의 IAM 울타리(`wes-*`) 안이므로 CI apply로 만들어진다(로컬 apply 불필요).

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  github_trust = {
    # 서버 저장소는 sub가 이름 기반이라 immutable repository_id·owner_id 조건을 함께 건다(운영 deploy 롤과 같은 규칙).
    deploy = {
      subject       = "repo:${var.server_repository}:ref:refs/heads/${var.dev_branch}"
      repository_id = var.server_repository_id
    }
    worker_deploy = {
      subject       = "${var.ai_oidc_subject_prefix}:ref:refs/heads/${var.dev_branch}"
      repository_id = var.ai_repository_id
    }
    admin_api_deploy = {
      subject       = "repo:${var.server_repository}:ref:refs/heads/${var.dev_branch}"
      repository_id = var.server_repository_id
    }
    admin_deploy = {
      subject       = "${var.backoffice_oidc_subject_prefix}:ref:refs/heads/${var.dev_branch}"
      repository_id = var.backoffice_repository_id
    }
  }
}

data "aws_iam_policy_document" "assume" {
  for_each = local.github_trust

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [each.value.subject]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:repository_owner_id"
      values   = [var.github_repository_owner_id]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:repository_id"
      values   = [each.value.repository_id]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:ref"
      values   = ["refs/heads/${var.dev_branch}"]
    }
  }
}

# --- deploy: 서버 저장소 dev CD ---

resource "aws_iam_role" "deploy" {
  name_prefix        = "${local.name_prefix}-deploy-"
  assume_role_policy = data.aws_iam_policy_document.assume["deploy"].json
}

data "aws_iam_policy_document" "deploy" {
  # CD가 Name 태그로 인스턴스 ID를 찾는다. Describe*는 리소스 단위 제한이 안 됨.
  statement {
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript"]
  }

  # dev 앱 인스턴스(Name=wes-dev-app)에만 명령을 보낼 수 있다 — 운영 wes-app에는 닿지 않는다.
  statement {
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Name"
      values   = ["${local.name_prefix}-app"]
    }
  }

  statement {
    actions   = ["ssm:GetCommandInvocation"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy-via-ssm"
  role   = aws_iam_role.deploy.name
  policy = data.aws_iam_policy_document.deploy.json
}

# --- worker_deploy: AI 저장소 dev CD ---

resource "aws_iam_role" "worker_deploy" {
  name_prefix        = "${local.name_prefix}-worker-deploy-"
  assume_role_policy = data.aws_iam_policy_document.assume["worker_deploy"].json
}

data "aws_iam_policy_document" "worker_deploy" {
  statement {
    sid       = "GetEcrAuthorizationToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # dev 리포지토리(wes-dev-*)만. 운영 wes-* 리포지토리의 이동 태그에는 닿지 않는다.
  statement {
    sid = "PushOnlyDevWorkerRepositories"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImageScanFindings",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = values(module.analysis.repository_arns)
  }

  statement {
    sid = "UpdateAndInspectOnlyDevFunctions"
    actions = [
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:UpdateFunctionCode",
    ]
    resources = values(module.analysis.function_arns)
  }
}

resource "aws_iam_role_policy" "worker_deploy" {
  name   = "deploy-ai-lambdas"
  role   = aws_iam_role.worker_deploy.name
  policy = data.aws_iam_policy_document.worker_deploy.json
}

# --- admin_api_deploy · admin_deploy: 서버·백오피스 저장소 dev CD → wes-dev-admin ---
# 운영과 같이 두 저장소가 롤을 따로 쓰고 정책은 같다(Name=wes-dev-admin 한 대). 호스트의 공통 flock이 둘을 직렬화한다.

data "aws_iam_policy_document" "admin_deploy" {
  statement {
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript"]
  }

  # dev 관리자 인스턴스(Name=wes-dev-admin)에만 — 운영 wes-admin에는 닿지 않는다.
  statement {
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Name"
      values   = [local.admin_instance_name]
    }
  }

  statement {
    actions   = ["ssm:GetCommandInvocation"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "admin_api_deploy" {
  name_prefix        = "${local.name_prefix}-admin-api-deploy-"
  assume_role_policy = data.aws_iam_policy_document.assume["admin_api_deploy"].json
}

resource "aws_iam_role_policy" "admin_api_deploy" {
  name   = "deploy-via-ssm"
  role   = aws_iam_role.admin_api_deploy.name
  policy = data.aws_iam_policy_document.admin_deploy.json
}

resource "aws_iam_role" "admin_deploy" {
  name_prefix        = "${local.name_prefix}-admin-deploy-"
  assume_role_policy = data.aws_iam_policy_document.assume["admin_deploy"].json
}

resource "aws_iam_role_policy" "admin_deploy" {
  name   = "deploy-via-ssm"
  role   = aws_iam_role.admin_deploy.name
  policy = data.aws_iam_policy_document.admin_deploy.json
}
