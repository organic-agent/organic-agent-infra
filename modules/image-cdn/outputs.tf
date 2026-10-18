output "distribution_id" {
  description = "미리보기 CloudFront 배포 ID"
  value       = aws_cloudfront_distribution.preview.id
}

output "domain_name" {
  description = "이미지 전용 주소"
  value       = var.domain_name
}

output "key_pair_id" {
  description = "쿠키 서명 공개키 ID(이미 <parameter_prefix>/app.storage.preview-cdn.key-pair-id에 기록됨)"
  value       = aws_cloudfront_public_key.preview.id
}
