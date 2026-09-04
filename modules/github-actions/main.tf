# GitHub Actions가 AWS에 들어올 때 쓰는 OIDC 프로바이더와 롤 여섯 개.
#
#   deploy           서버 저장소 CD     — public API를 wes-app에 배포
#   admin_api_deploy 서버 저장소 CD     — public 배포 성공 후 admin API를 wes-admin에 배포
#   worker_deploy    AI 저장소 CD       — embedder·score·categorize 이미지를 ECR에 푸시하고 Lambda 코드 갱신
#   admin_deploy     백오피스 저장소 CD — BackOffice를 wes-admin에 배포
#   tf_plan          이 저장소 PR       — terraform plan (읽기 전용)
#   tf_apply         이 저장소 main     — terraform apply
#
# 장기 액세스 키를 발급·보관하지 않고, 각 롤은 특정 저장소의 특정 브랜치/이벤트 토큰만 받는다.
# 닭과 달걀: tf_* 롤은 이 스택이 만든다. 최초 apply와 이 모듈을 고치는 apply는 로컬에서 하고,
# output의 ARN을 저장소 시크릿에 넣으면 CI/CD가 돈다 (docs/runbook.md '인프라 CI/CD').

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  # Server와 Infra는 2026-07-15 이전 생성 저장소라 현재 GitHub 기본 sub가 이름 기반이다.
  # sub를 실제 토큰 형식과 정확히 맞추면서 repository_id/owner_id 조건을 함께 검사해,
  # 저장소 rename·namespace 재사용으로 다른 저장소가 같은 역할을 assume하지 못하게 한다.
  # BackOffice와 AI 저장소는 신규 저장소라 immutable 기본 sub 자체에 두 ID가 포함된다
  # (GET /repos/{owner}/{repo}/actions/oidc/customization/sub 의 sub_claim_prefix로 확인).
  github_trust = {
    deploy = {
      subject       = "repo:${var.server_repository}:ref:refs/heads/main"
      repository_id = var.server_repository_id
      ref           = "refs/heads/main"
      environment   = null
    }
    admin_api_deploy = {
      subject       = "repo:${var.server_repository}:ref:refs/heads/main"
      repository_id = var.server_repository_id
      ref           = "refs/heads/main"
      environment   = null
    }
    worker_deploy = {
      subject       = var.worker_oidc_subject
      repository_id = var.worker_repository_id
      ref           = "refs/heads/main"
      environment   = null
    }
    admin_deploy = {
      subject       = var.admin_oidc_subject
      repository_id = var.admin_repository_id
      ref           = "refs/heads/main"
      environment   = null
    }
    tf_plan = {
      subject       = "repo:${var.infra_repository}:pull_request"
      repository_id = var.infra_repository_id
      ref           = null
      environment   = null
    }
    tf_apply = {
      # apply jobs use GitHub environment=production, so their sub is not the main ref form.
      subject       = "repo:${var.infra_repository}:environment:production"
      repository_id = var.infra_repository_id
      ref           = "refs/heads/main"
      environment   = "production"
    }
  }
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS는 GitHub OIDC를 자체 신뢰 체계로 검증하므로 thumbprint는 형식상 필요할 뿐임.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# 여섯 롤은 역할별 exact sub에 더해 immutable repository/owner ID를 함께 검사한다.
# 서버의 두 배포 역할은 같은 main 주체를 신뢰하지만 권한 대상이 달라 서로 넓히지 않는다.
data "aws_iam_policy_document" "assume" {
  for_each = local.github_trust

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

    # 서버/BackOffice main과 Infra PR은 exact sub로, Infra apply는 production environment
    # sub로 제한한다. 아래 immutable ID와 선택적 ref/environment 조건도 모두 만족해야 한다.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [each.value.subject]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:repository_owner_id"
      values   = [var.repository_owner_id]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:repository_id"
      values   = [each.value.repository_id]
    }

    dynamic "condition" {
      for_each = each.value.ref == null ? [] : [each.value.ref]

      content {
        test     = "StringEquals"
        variable = "token.actions.githubusercontent.com:ref"
        values   = [condition.value]
      }
    }

    dynamic "condition" {
      for_each = each.value.environment == null ? [] : [each.value.environment]

      content {
        test     = "StringEquals"
        variable = "token.actions.githubusercontent.com:environment"
        values   = [condition.value]
      }
    }
  }
}

# =============================================================================
# deploy — 서버 저장소 CD
# =============================================================================

resource "aws_iam_role" "deploy" {
  name_prefix        = "${var.name_prefix}-deploy-"
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

  # 앱 인스턴스(Name 태그 기준)에만 명령을 보낼 수 있다.
  statement {
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${var.aws_region}:${local.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Name"
      values   = [var.app_instance_name]
    }
  }

  # 명령 결과(성공/실패, stdout/stderr) 폴링용.
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

# =============================================================================
# admin_api_deploy — 서버 저장소 CD, wes-admin 전용
# =============================================================================

resource "aws_iam_role" "admin_api_deploy" {
  name_prefix        = "${var.name_prefix}-admin-api-deploy-"
  assume_role_policy = data.aws_iam_policy_document.assume["admin_api_deploy"].json
}

# =============================================================================
# admin_deploy — 백오피스 저장소 CD
# =============================================================================

# 기존 서버 배포 롤을 넓히지 않는다. 별도 역할이 백오피스 저장소 main의 immutable
# OIDC subject만 신뢰하며, 아래 인라인 정책도 Name=wes-admin 인스턴스만 대상으로 제한한다.
resource "aws_iam_role" "admin_deploy" {
  name_prefix        = "${var.name_prefix}-admin-deploy-"
  assume_role_policy = data.aws_iam_policy_document.assume["admin_deploy"].json
}

data "aws_iam_policy_document" "admin_deploy" {
  # CD가 Name 태그로 인스턴스 ID를 찾는다. Describe*는 리소스 단위 제한이 안 됨.
  statement {
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript"]
  }

  statement {
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${var.aws_region}:${local.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Name"
      values   = [var.admin_instance_name]
    }
  }

  # 명령 결과(성공/실패, stdout/stderr) 폴링용.
  statement {
    actions   = ["ssm:GetCommandInvocation"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "admin_deploy" {
  name   = "deploy-via-ssm"
  role   = aws_iam_role.admin_deploy.name
  policy = data.aws_iam_policy_document.admin_deploy.json
}

# 관리자 API와 BackOffice는 같은 호스트에 배포되지만 서로 다른 저장소 주체와 역할을 쓴다.
# 두 역할 모두 Name=wes-admin 한 대로 제한되며, 호스트의 공통 flock이 실행을 직렬화한다.
resource "aws_iam_role_policy" "admin_api_deploy" {
  name   = "deploy-via-ssm"
  role   = aws_iam_role.admin_api_deploy.name
  policy = data.aws_iam_policy_document.admin_deploy.json
}

# =============================================================================
# worker_deploy — AI 저장소 CD, Lambda 셋(embedder · score · categorize)의 ECR/Lambda 전용
# =============================================================================

# 공개/관리자 EC2 배포 역할에 ECR·Lambda 쓰기 권한을 섞지 않는다. 이 역할은 AI 저장소 main의
# deploy-lambda.yml만 assume하며(바뀐 모듈의 `<모듈>/deploy.sh`를 그대로 돌린다), 아래 정책의
# 정확한 repository/function 목록 이외에는 변경할 수 없다. embedder 코드가 서버 저장소에서
# AI 저장소로 이관되어(organic-agent-ai #20) 서버 CD에는 더 이상 embedder 잡이 없다.
resource "aws_iam_role" "worker_deploy" {
  name_prefix        = "${var.name_prefix}-worker-deploy-"
  assume_role_policy = data.aws_iam_policy_document.assume["worker_deploy"].json
}

data "aws_iam_policy_document" "worker_deploy" {
  # ECR Docker login은 리포지토리 ARN으로 제한할 수 없는 계정 단위 토큰 발급 API다.
  statement {
    sid       = "GetEcrAuthorizationToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # DescribeRepositories: deploy.sh가 리포지토리 URI를 terraform output이 아니라 이 API로 찾는다.
  statement {
    sid = "PushOnlyWorkerRepositories"
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
    resources = var.worker_repository_arns
  }

  statement {
    sid = "UpdateAndInspectOnlyWorkerFunctions"
    actions = [
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:UpdateFunctionCode",
    ]
    resources = var.worker_function_arns
  }
}

resource "aws_iam_role_policy" "worker_deploy" {
  name   = "deploy-ai-lambdas"
  role   = aws_iam_role.worker_deploy.name
  policy = data.aws_iam_policy_document.worker_deploy.json
}

# =============================================================================
# tf_plan — 이 저장소 PR
# =============================================================================

resource "aws_iam_role" "tf_plan" {
  name_prefix        = "${var.name_prefix}-tf-plan-"
  assume_role_policy = data.aws_iam_policy_document.assume["tf_plan"].json
}

# plan은 모든 리소스를 Describe 한다. 목록을 손으로 유지하면 모듈이 늘 때마다 깨지므로 ReadOnlyAccess.
resource "aws_iam_role_policy_attachment" "tf_plan_readonly" {
  role       = aws_iam_role.tf_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess에 없는 것: SecureString 복호화. database 모듈의 ephemeral 파라미터가 plan 단계에서 열린다.
# 쓰기 권한은 없다 — state 잠금 파일도 못 만들므로 워크플로우가 plan에 -lock=false를 준다.
data "aws_iam_policy_document" "tf_plan_extra" {
  statement {
    sid       = "DecryptSsmSecureString"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "tf_plan_extra" {
  name   = "plan-extra"
  role   = aws_iam_role.tf_plan.name
  policy = data.aws_iam_policy_document.tf_plan_extra.json
}

# =============================================================================
# tf_apply — 이 저장소 main
# =============================================================================

resource "aws_iam_role" "tf_apply" {
  name_prefix        = "${var.name_prefix}-tf-apply-"
  assume_role_policy = data.aws_iam_policy_document.assume["tf_apply"].json
}

# PowerUserAccess = IAM/Organizations/Account을 뺀 전부. 이 스택이 만드는 VPC·EC2·RDS·S3·Lambda·
# Route53·ACM·SSM·ECR이 모두 여기 들어간다. IAM은 아래에서 <prefix>-* 이름으로만 따로 연다.
resource "aws_iam_role_policy_attachment" "tf_apply_poweruser" {
  role       = aws_iam_role.tf_apply.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# IAM은 이름으로 울타리를 친다. 이 스택의 롤·인스턴스 프로파일은 전부 같은 접두사라,
# CD가 뚫려도 계정의 다른 롤(관리자 등)은 건드릴 수 없다.
data "aws_iam_policy_document" "tf_apply_iam" {
  # plan/refresh가 읽는 것. PowerUserAccess는 iam:ListRoles 외의 읽기도 막는다.
  statement {
    sid       = "IamRead"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }

  statement {
    sid = "IamWritePrefixedOnly"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/${var.name_prefix}-*",
      "arn:aws:iam::${local.account_id}:instance-profile/${var.name_prefix}-*",
    ]
  }

  # EC2·Lambda에 롤을 붙일 때 필요. 역시 접두사 롤만.
  statement {
    sid       = "PassPrefixedRoles"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.name_prefix}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com", "lambda.amazonaws.com"]
    }
  }

  # 위 OIDC 프로바이더(thumbprint·client id 변경).
  statement {
    sid = "OidcProvider"
    actions = [
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:AddClientIDToOpenIDConnectProvider",
      "iam:RemoveClientIDFromOpenIDConnectProvider",
      "iam:TagOpenIDConnectProvider",
      "iam:UntagOpenIDConnectProvider",
    ]
    resources = ["arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"]
  }
}

resource "aws_iam_role_policy" "tf_apply_iam" {
  name   = "iam-prefixed-only"
  role   = aws_iam_role.tf_apply.name
  policy = data.aws_iam_policy_document.tf_apply_iam.json
}
