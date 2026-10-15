output "primary_endpoint_address" {
  description = "앱이 붙는 캐시 주소"
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "security_group_id" {
  description = "캐시 보안 그룹 ID"
  value       = aws_security_group.this.id
}
