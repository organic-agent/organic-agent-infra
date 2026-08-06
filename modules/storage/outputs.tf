output "bucket_name" {
  description = "원본 사진 버킷 이름 (이미 /wes/prod/app.storage.bucket에 기록됨)"
  value       = aws_s3_bucket.photos.bucket
}

output "bucket_arn" {
  description = "원본 사진 버킷 ARN"
  value       = aws_s3_bucket.photos.arn
}
