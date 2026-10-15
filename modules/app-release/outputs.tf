output "repository_url" {
  description = "공개 API 이미지 저장소 주소 (<계정>.dkr.ecr.<리전>.amazonaws.com/<이름>)"
  value       = aws_ecr_repository.api.repository_url
}

output "bundle_bucket" {
  description = "배포 묶음 버킷 이름"
  value       = aws_s3_bucket.bundle.bucket
}

output "image_tag_parameter" {
  description = "지금 배포된 이미지 태그 파라미터 이름 (CD 가 갱신)"
  value       = local.image_tag_name
}
