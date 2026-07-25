output "zone_id" {
  description = "호스티드 존 ID"
  value       = aws_route53_zone.this.zone_id
}

output "name_servers" {
  description = "등록기관에서 도메인 네임서버로 설정할 값"
  value       = aws_route53_zone.this.name_servers
}
