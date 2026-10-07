output "worker_instance_ids" {
  description = "워커 인스턴스 ID (키: AZ). wes는 ID가 아니라 태그 Name=<name>으로 찾는다"
  value       = { for az, inst in aws_instance.this : az => inst.id }
}

output "worker_role_name" {
  description = "워커 인스턴스 롤 이름"
  value       = aws_iam_role.worker.name
}

output "worker_tag_name" {
  description = "워커 인스턴스의 Name 태그 값 — 앱 롤의 Start/Stop 조건과 wes app.analysis.gpu.tag가 같은 값을 써야 한다"
  value       = var.name
}
