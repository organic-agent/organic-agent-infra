output "image_pipeline_arn" {
  description = "AMI 파이프라인 ARN — `aws imagebuilder start-image-pipeline-execution --image-pipeline-arn` 대상"
  value       = aws_imagebuilder_image_pipeline.this.arn
}

output "image_pipeline_name" {
  description = "AMI 파이프라인 이름(콘솔·CLI 조회용)"
  value       = aws_imagebuilder_image_pipeline.this.name
}

output "image_recipe_arn" {
  description = "현재 레시피 ARN(버전 포함). 빌드 결과 이미지 ARN은 이 레시피 이름·버전 아래 붙는다"
  value       = aws_imagebuilder_image_recipe.this.arn
}

output "component_arn" {
  description = "드라이버·Docker·워커 유닛 컴포넌트 ARN(버전 포함)"
  value       = aws_imagebuilder_component.nvidia_docker.arn
}

output "builder_role_name" {
  description = "빌드 인스턴스 롤 이름"
  value       = aws_iam_role.builder.name
}

output "score_image" {
  description = "워커가 부팅 때 pull 하는 이미지 참조(리포지토리:이동 태그). AMI의 /etc/wes-score/image.env에 구워진다"
  value       = local.score_image
}

output "gpu_ami_id" {
  description = "워커 인스턴스에 쓰는 AMI ID(변수 그대로)"
  value       = var.gpu_ami_id
}

output "worker_instance_ids" {
  description = "워커 인스턴스 ID (키: AZ). wes는 ID가 아니라 태그 Name=<name_prefix>-score-gpu로 찾는다"
  value       = { for az, inst in aws_instance.this : az => inst.id }
}

output "worker_role_name" {
  description = "워커 인스턴스 롤 이름"
  value       = aws_iam_role.worker.name
}

output "worker_tag_name" {
  description = "워커 인스턴스의 Name 태그 값 — 앱 롤의 Start/Stop 조건과 wes app.analysis.gpu.tag가 같은 값을 써야 한다"
  value       = local.name
}
