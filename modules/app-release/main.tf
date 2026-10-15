# 앱 서버가 스스로 새 버전을 받아 뜨는 데 필요한 것(서버 저장소 #313 ADR-0001 Q7) — ASG 가 새로 만든 서버는 CD 를 거치지 않는다.
#
#   ECR 저장소        공개 API 이미지. 서버가 인스턴스 역할로 받는다 — GHCR 은 비공개라 CD 의 단기 토큰 없이는 못 받는다.
#   배포 묶음 버킷     CD 가 올리는 배포 스크립트·compose·alloy 설정. 새 서버의 user_data 가 받아 같은 스크립트를 돌린다.
#   이미지 태그 파라미터 지금 배포된 커밋. CD 가 서버를 바꾸기 **전에** 갱신한다 — 배포 도중 늘어난 서버도 새 버전으로 뜨게.

data "aws_caller_identity" "current" {}

locals {
  repository_name = "${var.name_prefix}-api"
  image_tag_name  = "${var.parameter_prefix}/app.deploy.image-tag"
  image_tag_arn   = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.image_tag_name}"
}

resource "aws_ecr_repository" "api" {
  name                 = local.repository_name
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# 롤백은 서버에 남은 직전 이미지로 하고, 새 서버는 지금 태그만 받는다 — 최근 몇 개면 된다.
resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.keep_images
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_s3_bucket" "bundle" {
  # 버킷 이름은 AWS 전체에서 유일해야 한다. 계정 번호를 붙인다.
  bucket = "${var.name_prefix}-deploy-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "bundle" {
  bucket                  = aws_s3_bucket.bundle.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bundle" {
  bucket = aws_s3_bucket.bundle.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# --- 앱 서버(인스턴스 역할): 이미지 받기 · 배포 묶음 읽기 ---

data "aws_iam_policy_document" "instance" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "PullApiImage"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [aws_ecr_repository.api.arn]
  }

  statement {
    sid       = "ReadBundle"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.bundle.arn}/*"]
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "read-app-release"
  role   = var.instance_role_name
  policy = data.aws_iam_policy_document.instance.json
}

# --- CD(배포 역할): 이미지 올리기 · 배포 묶음 올리기 · 이미지 태그 갱신 ---

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "PushApiImage"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.api.arn]
  }

  statement {
    sid       = "WriteBundle"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.bundle.arn}/*"]
  }

  statement {
    sid       = "PublishImageTag"
    actions   = ["ssm:PutParameter", "ssm:GetParameter"]
    resources = [local.image_tag_arn]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "publish-app-release"
  role   = var.deploy_role_name
  policy = data.aws_iam_policy_document.deploy.json
}
