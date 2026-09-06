# One repository, one branch, one test instance, one fixed deployment command.
resource "aws_iam_role" "frontend_test_deploy" {
  name_prefix        = "${var.name_prefix}-frontend-test-deploy-"
  assume_role_policy = data.aws_iam_policy_document.assume["frontend_test_deploy"].json
}

data "aws_iam_policy_document" "frontend_test_deploy" {
  statement {
    sid       = "UploadFrontendReleaseOnly"
    actions   = ["s3:PutObject"]
    resources = ["${var.frontend_test_artifact_bucket_arn}/releases/*"]
  }

  statement {
    sid       = "RunFixedFrontendDeploymentOnly"
    actions   = ["ssm:SendCommand"]
    resources = [var.frontend_test_deploy_document_arn]
  }

  statement {
    sid       = "TargetOnlyFrontendTestInstance"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${var.aws_region}:${local.account_id}:instance/${var.frontend_test_instance_id}"]
  }

  # GetCommandInvocation does not support resource-level permissions.
  statement {
    sid       = "PollDeploymentResult"
    actions   = ["ssm:GetCommandInvocation"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "frontend_test_deploy" {
  name   = "deploy-test-frontend-only"
  role   = aws_iam_role.frontend_test_deploy.name
  policy = data.aws_iam_policy_document.frontend_test_deploy.json
}
