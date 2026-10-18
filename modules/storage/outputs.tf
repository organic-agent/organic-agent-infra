output "bucket_name" {
  description = "사진 버킷 이름 (이미 {parameter_prefix}/app.storage.bucket에 기록됨)"
  value       = aws_s3_bucket.photos.bucket
}

output "bucket_arn" {
  description = "원본 사진 버킷 ARN"
  value       = aws_s3_bucket.photos.arn
}

output "bucket_regional_domain_name" {
  description = "사진 버킷의 리전 도메인 — 미리보기 CDN(modules/image-cdn)의 원점"
  value       = aws_s3_bucket.photos.bucket_regional_domain_name
}
