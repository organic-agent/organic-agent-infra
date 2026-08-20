# GitHub Actions가 AWS에 들어올 때 쓰는 OIDC 프로바이더와 롤 세 개.
#
#   deploy   서버 저장소 CD  — main 머지 → SSM Run Command로 앱 EC2에 docker compose 배포
#   tf_plan  이 저장소 PR    — terraform plan (읽기 전용)
#   tf_apply 이 저장소 main  — terraform apply
#
# 장기 액세스 키를 발급·보관하지 않고, 각 롤은 특정 저장소의 특정 브랜치/이벤트 토큰만 받는다.
# 닭과 달걀: tf_* 롤은 이 스택이 만든다. 최초 apply와 이 모듈을 고치는 apply는 로컬에서 하고,
# output의 ARN을 저장소 시크릿에 넣으면 CI/CD가 돈다 (docs/runbook.md '인프라 CI/CD').

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS는 GitHub OIDC를 자체 신뢰 체계로 검증하므로 thumbprint는 형식상 필요할 뿐임.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# 세 롤의 신뢰 정책은 sub 조건만 다르다.
data "aws_iam_policy_document" "assume" {
  for_each = {
    deploy   = "repo:${var.server_repository}:ref:refs/heads/main"
    tf_plan  = "repo:${var.infra_repository}:pull_request"
    tf_apply = "repo:${var.infra_repository}:ref:refs/heads/main"
  }

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

    # main 브랜치 sub는 push와 main에서의 workflow_dispatch 둘 다 해당. pull_request sub는
    # 이 저장소의 PR 이벤트만 — 포크 PR은 시크릿을 못 받아 여기까지 오지 못한다.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [each.value]
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
