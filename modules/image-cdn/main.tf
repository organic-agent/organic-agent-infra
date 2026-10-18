# 사진 미리보기 CDN(서버 저장소 #336 ADR-0001).
#
# 지금 미리보기 주소는 S3 서명 URL이라 10분마다 바뀌고, 브라우저는 주소가 다르면 이미 본 사진도 다시 받는다(실제 웹 측정: 갱신 한 번에
# 499장 · 43.7MB). 이 배포는 주소를 사진 키 그대로 고정하고, 열 수 있는지는 앱이 주는 서명 쿠키(갤러리 미리보기 경로만, 20분)가 정한다.
#
#   주소      https://{domain}/{path_prefix}/previews/galleries/{id}/…   — 만료 없음 · 성공 응답에 1년 immutable 헤더(오류는 no-store)
#   권한      모든 경로에 키 그룹 서명 필수. 쿠키는 미리보기 경로만 열므로 원본(galleries/…)은 이 배포로 열리지 않는다
#   원점      사진 버킷(OAC). 버킷 정책은 이 배포만, 미리보기 접두만 GetObject
#
# 하객·원본·보정 결과는 지금처럼 S3 서명 URL이다(이 배포를 지나지 않음).

locals {
  name = "${var.name_prefix}-preview-cdn"
  # 원점 버킷에서 미리보기 키의 머리. 버킷 정책과 캐시 동작이 이 아래만 다룬다.
  preview_root  = "previews"
  behavior_path = var.path_prefix == "" ? "${local.preview_root}/*" : "${var.path_prefix}/${local.preview_root}/*"
  # CloudFront 관리형 캐시 정책 CachingOptimized — 쿼리·쿠키·헤더를 캐시 키에 넣지 않는다(쿠키는 서명 검사에만 쓰이고 캐시는 사진 키 하나).
  caching_optimized_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
}

resource "aws_cloudfront_origin_access_control" "photos" {
  name                              = local.name
  description                       = "사진 버킷 읽기 — 미리보기 CDN만(#336)"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# 개인키는 상태 파일에 남기지 않는다 — 공개키만 여기, 개인키는 SSM SecureString(앱이 읽음).
# 키를 바꾸면 새 공개키를 먼저 만들고(name_prefix) 키 그룹을 옮긴 뒤 옛 것을 지운다.
resource "aws_cloudfront_public_key" "preview" {
  name_prefix = "${local.name}-"
  encoded_key = var.public_key_pem
  comment     = "미리보기 쿠키 서명(#336)"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudfront_key_group" "preview" {
  name    = local.name
  items   = [aws_cloudfront_public_key.preview.id]
  comment = "미리보기 쿠키 서명(#336)"
}

# 미리보기는 키가 UUID라 한 번 만들면 바뀌지 않는다 — 원점 객체에 헤더가 없어도(기존 2.7만 장) 여기서 붙인다.
# 응답 헤더 정책이 아니라 함수로 붙이는 까닭: 정책은 쿠키가 없어 난 403에도 1년 immutable 을 붙인다(10-19 apply 뒤 확인). 쿠키가 늦게 실리거나
# 만료된 순간의 403 을 브라우저가 1년 캐시하면 그 기기에서 사진이 계속 깨진다 → 성공 응답에만 붙이고 나머지는 no-store.
resource "aws_cloudfront_function" "cache_header" {
  name    = "${local.name}-cache-header"
  runtime = "cloudfront-js-2.0"
  comment = "미리보기 성공 응답만 1년 immutable(#336)"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var response = event.response;
      var ok = response.statusCode === 200 || response.statusCode === 304;
      response.headers['cache-control'] = {
        value: ok ? 'public, max-age=${var.cache_max_age_seconds}, immutable' : 'no-store'
      };
      return response;
    }
  EOT
}

# dev 는 주소에 환경 접두(/d/…)가 붙는다 — 원점 키에는 없으므로 보내기 전에 뗀다.
resource "aws_cloudfront_function" "strip_prefix" {
  count = var.path_prefix == "" ? 0 : 1

  name    = "${local.name}-strip-prefix"
  runtime = "cloudfront-js-2.0"
  comment = "환경 접두 /${var.path_prefix}/ 를 떼고 원점으로(#336)"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var request = event.request;
      var prefix = '/${var.path_prefix}/';
      if (request.uri.indexOf(prefix) === 0) {
        request.uri = request.uri.substring(prefix.length - 1);
      }
      return request;
    }
  EOT
}

resource "aws_cloudfront_distribution" "preview" {
  enabled         = true
  comment         = "사진 미리보기 CDN — 고정 주소 + 서명 쿠키(#336)"
  http_version    = "http2and3"
  is_ipv6_enabled = true
  price_class     = var.price_class
  aliases         = [var.domain_name]

  origin {
    origin_id                = "photos"
    domain_name              = var.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.photos.id
  }

  # 미리보기 경로 밖은 쿠키가 맞지 않아 전부 403이다(키 그룹 필수) — 원본을 이 배포로 열 길을 두지 않는다.
  default_cache_behavior {
    target_origin_id       = "photos"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = local.caching_optimized_policy_id
    compress               = false
    trusted_key_groups     = [aws_cloudfront_key_group.preview.id]
  }

  ordered_cache_behavior {
    path_pattern           = local.behavior_path
    target_origin_id       = "photos"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = local.caching_optimized_policy_id
    # JPEG 는 이미 압축돼 있어 다시 압축해도 이득이 없다.
    compress           = false
    trusted_key_groups = [aws_cloudfront_key_group.preview.id]

    function_association {
      event_type   = "viewer-response"
      function_arn = aws_cloudfront_function.cache_header.arn
    }

    dynamic "function_association" {
      for_each = aws_cloudfront_function.strip_prefix
      content {
        event_type   = "viewer-request"
        function_arn = function_association.value.arn
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.preview.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# --- 인증서 (CloudFront 는 us-east-1 인증서만 받는다) ---

resource "aws_acm_certificate" "preview" {
  provider          = aws.us_east_1
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "certificate_validation" {
  for_each = {
    for option in aws_acm_certificate.preview.domain_validation_options : option.domain_name => {
      name   = option.resource_record_name
      record = option.resource_record_value
      type   = option.resource_record_type
    }
  }

  zone_id         = var.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "preview" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.preview.arn
  validation_record_fqdns = [for record in aws_route53_record.certificate_validation : record.fqdn]
}

resource "aws_route53_record" "preview" {
  for_each = toset(["A", "AAAA"])

  zone_id = var.zone_id
  name    = var.domain_name
  type    = each.value

  alias {
    name                   = aws_cloudfront_distribution.preview.domain_name
    zone_id                = aws_cloudfront_distribution.preview.hosted_zone_id
    evaluate_target_health = false
  }
}

# --- 원점 버킷 정책: 이 배포만, 미리보기 접두만 ---
# 사진 버킷에는 다른 버킷 정책이 없다(modules/storage 는 퍼블릭 차단만). 이 모듈이 버킷 정책의 주인이다 —
# 다른 곳에서 정책을 더하려면 여기로 합친다(버킷 정책은 버킷마다 하나라 둘이면 서로 덮어쓴다).
data "aws_iam_policy_document" "photos_bucket" {
  statement {
    sid       = "PreviewCdnRead"
    actions   = ["s3:GetObject"]
    resources = ["${var.bucket_arn}/${local.preview_root}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.preview.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "photos" {
  bucket = var.bucket_id
  policy = data.aws_iam_policy_document.photos_bucket.json
}

# --- 앱이 읽는 값(app.storage.preview-cdn.*). enabled · private-key 는 Terraform 밖(CLI)에서 —
# 켜기는 웹 배포 뒤 사람이 정하고, 개인키는 상태 파일에 남기지 않는다. ---

resource "aws_ssm_parameter" "base_url" {
  name  = "${var.parameter_prefix}/app.storage.preview-cdn.base-url"
  type  = "String"
  value = "https://${var.domain_name}"
}

resource "aws_ssm_parameter" "key_pair_id" {
  name  = "${var.parameter_prefix}/app.storage.preview-cdn.key-pair-id"
  type  = "String"
  value = aws_cloudfront_public_key.preview.id
}

resource "aws_ssm_parameter" "cookie_domain" {
  name  = "${var.parameter_prefix}/app.storage.preview-cdn.cookie-domain"
  type  = "String"
  value = var.cookie_domain
}

# SSM 은 빈 값을 받지 않는다 — 접두가 없는 운영은 만들지 않고 앱 기본값("")을 쓴다.
resource "aws_ssm_parameter" "path_prefix" {
  count = var.path_prefix == "" ? 0 : 1

  name  = "${var.parameter_prefix}/app.storage.preview-cdn.path-prefix"
  type  = "String"
  value = var.path_prefix
}
