# 원본 사진이 사는 버킷.
#
# 이미지 바이트는 앱을 거치지 않는다. 앱은 서명 URL만 만들어 주고, 브라우저가 S3에 직접
# PUT/GET 한다. 수천 장 원본이 1GB짜리 EC2를 통과하면 버티지 못한다.

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "${var.name_prefix}-photos-${data.aws_caller_identity.current.account_id}"

  # 아래 두 버킷 중 하나만 만들어진다. 나머지 리소스는 이 값 하나만 본다.
  photos = one(concat(aws_s3_bucket.photos[*], aws_s3_bucket.photos_protected[*]))
}

# 테스트 데이터 버킷(로컬·dev). 언제든 폐기하는 스택이라 비어 있지 않아도 지운다.
# 이게 없으면 사진을 한 장이라도 올린 순간부터 destroy가 BucketNotEmpty로 실패하고,
# 손으로 비우기 전에는 스택을 접을 수 없다. RDS의 skip_final_snapshot과 같은 판단이다.
resource "aws_s3_bucket" "photos" {
  count = var.protect_from_destroy ? 0 : 1

  # 버킷 이름은 AWS 전체에서 유일해야 한다. 계정 번호를 붙여 다른 계정과 겹치지 않게 한다.
  bucket        = local.bucket_name
  force_destroy = true
}

# 고객 원본 버킷(운영). 결혼식 원본은 다시 받을 수 없다.
# - force_destroy = false: 비어 있지 않으면 Terraform이 지우지 못한다.
# - prevent_destroy: destroy나 교체가 plan에 잡히면 plan부터 실패한다.
# lifecycle 안은 변수를 쓸 수 없어(Terraform 제약) 버킷을 두 리소스로 나눴다.
# 객체 삭제(계정 삭제 · 휴지통 비우기의 DeleteObject)는 이 설정과 상관없이 그대로 된다.
resource "aws_s3_bucket" "photos_protected" {
  count = var.protect_from_destroy ? 1 : 0

  bucket        = local.bucket_name
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }
}

# 서명 URL 말고 다른 통로를 남기지 않는다. 갤러리 사진은 결혼식 원본이라,
# 키를 아는 사람이 URL을 조립해 받아갈 수 있으면 안 된다.
resource "aws_s3_bucket_public_access_block" "photos" {
  bucket                  = local.photos.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "photos" {
  bucket = local.photos.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 브라우저가 S3와 직접 이야기하므로 프리플라이트에 답하는 것도 S3다. 이 규칙이 없으면
# 업로드가 OPTIONS 요청에서 죽고, 앱 쪽 CORS 설정을 아무리 만져도 소용이 없다 —
# 그 요청 경로에 앱이 아예 없다.
resource "aws_s3_bucket_cors_configuration" "photos" {
  bucket = local.photos.id

  cors_rule {
    allowed_origins = var.web_origins

    # PUT은 업로드, GET/HEAD는 화면에 그리기. POST(폼 업로드)도 DELETE도 없다 —
    # 삭제는 앱이 인스턴스 롤로 하지 브라우저가 하지 않는다.
    allowed_methods = ["PUT", "GET", "HEAD"]

    # 서명된 PUT은 Content-Type을 서명에 포함하므로 그 헤더가 프리플라이트를 통과해야 한다.
    # 목록을 좁히면 앱이 새 헤더에 서명할 때마다 여기를 다시 감사해야 한다.
    allowed_headers = ["*"]

    # 없으면 JS에서 읽을 수 없다. 프론트가 S3가 저장한 내용을 확인하는 데 쓴다.
    expose_headers = ["ETag"]

    max_age_seconds = 3000
  }
}

# 업로드 URL만 받고 실제로 올리지 않은 사진은 S3에 객체가 없다. 반대로 올리다 끊긴
# 멀티파트 조각은 보이지 않는 채로 과금된다. 7일이면 어떤 업로드 세션보다 길다.
resource "aws_s3_bucket_lifecycle_configuration" "photos" {
  bucket = local.photos.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# 앱은 이 버킷의 객체를 서명하고, 지우고, 필요하면 직접 올린다.
#
# 서명 자체는 AWS를 부르지 않는 로컬 계산이지만, 서명한 자격증명에 권한이 없으면 S3가
# 그 URL을 거절한다. 즉 이 정책이 없으면 앱은 아무 오류 없이 "쓸 수 없는 URL"을 계속 발급한다.
#
# 로컬 버킷(attach_app_role_policy = false)에는 붙이지 않는다. 그 버킷을 서명하는 것은 EC2가 아니라
# 개발자 노트북의 자격증명이고, 운영 인스턴스 롤이 로컬 버킷까지 만질 이유가 없다.
data "aws_iam_policy_document" "app_photos" {
  statement {
    sid = "PhotoObjects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${local.photos.arn}/*"]
  }

  statement {
    sid       = "PhotoBucket"
    actions   = ["s3:ListBucket"]
    resources = [local.photos.arn]
  }
}

resource "aws_iam_role_policy" "app_photos" {
  # 롤 이름이 아니라 별도 bool로 센다. 롤을 같은 apply에서 만드는 스택(environments/dev 첫 apply)에서는 이름이 apply 전까지
  # 정해지지 않아(name_prefix) count가 plan에서 막힌다.
  count = var.attach_app_role_policy ? 1 : 0

  name   = "photo-bucket"
  role   = var.app_role_name
  policy = data.aws_iam_policy_document.app_photos.json
}

# 앱이 부팅할 때 다른 설정과 함께 읽는다(app.storage.bucket). /wes/prod는 EC2의 앱이,
# /wes/local은 노트북의 bootRun(local 프로필)이 읽으므로 로컬 버킷도 같은 키로 알려 준다.
# 버킷 이름은 인프라가 정하는 값이라 저장소의 yml에 박지 않는다.
resource "aws_ssm_parameter" "photo_bucket" {
  name  = "${var.parameter_prefix}/app.storage.bucket"
  type  = "String"
  value = local.photos.bucket
}
