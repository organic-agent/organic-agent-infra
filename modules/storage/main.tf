# 원본 사진이 사는 버킷.
#
# 이미지 바이트는 앱을 거치지 않는다. 앱은 서명 URL만 만들어 주고, 브라우저가 S3에 직접
# PUT/GET 한다. 수천 장 원본이 1GB짜리 EC2를 통과하면 버티지 못한다.

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "photos" {
  # 버킷 이름은 AWS 전체에서 유일해야 한다. 계정 번호를 붙여 다른 계정과 겹치지 않게 한다.
  bucket = "${var.name_prefix}-photos-${data.aws_caller_identity.current.account_id}"

  # 비어 있지 않은 버킷은 삭제를 거부한다. 이게 없으면 사진을 한 장이라도 올린 순간부터
  # destroy가 BucketNotEmpty로 실패하고, 손으로 비우기 전에는 스택을 접을 수 없다.
  # RDS의 skip_final_snapshot과 같은 판단이다 — 이 스택은 언제든 폐기하는 테스트 환경이다.
  # **실제 고객 사진을 담는 순간 이 줄과 RDS 설정을 함께 뒤집어야 한다.**
  force_destroy = true
}

# 서명 URL 말고 다른 통로를 남기지 않는다. 갤러리 사진은 결혼식 원본이라,
# 키를 아는 사람이 URL을 조립해 받아갈 수 있으면 안 된다.
resource "aws_s3_bucket_public_access_block" "photos" {
  bucket                  = aws_s3_bucket.photos.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "photos" {
  bucket = aws_s3_bucket.photos.id

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
  bucket = aws_s3_bucket.photos.id

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
  bucket = aws_s3_bucket.photos.id

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
data "aws_iam_policy_document" "app_photos" {
  statement {
    sid = "PhotoObjects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.photos.arn}/*"]
  }

  statement {
    sid       = "PhotoBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.photos.arn]
  }
}

resource "aws_iam_role_policy" "app_photos" {
  name   = "photo-bucket"
  role   = var.app_role_name
  policy = data.aws_iam_policy_document.app_photos.json
}

# 앱이 부팅할 때 다른 설정과 함께 읽는다(app.storage.bucket).
# 버킷 이름은 인프라가 정하는 값이라 저장소의 yml에 박지 않는다.
resource "aws_ssm_parameter" "photo_bucket" {
  name  = "${var.parameter_prefix}/app.storage.bucket"
  type  = "String"
  value = aws_s3_bucket.photos.bucket
}
