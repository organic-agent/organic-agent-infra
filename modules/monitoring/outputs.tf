output "fqdn" {
  description = "Grafana 접속 도메인"
  value       = local.fqdn
}

output "instance_id" {
  description = "모니터링 EC2 인스턴스 ID (SSM 세션 --target)"
  value       = aws_instance.this.id
}

output "public_ip" {
  description = "모니터링 서버 EIP (stop/start 해도 유지)"
  value       = aws_eip.this.public_ip
}

output "private_ip" {
  description = "앱 서버가 로그를 보내는 프라이빗 IP"
  value       = aws_instance.this.private_ip
}

output "loki_push_url" {
  description = "앱 logback appender가 쓰는 Loki push URL (SSM에도 같은 값이 기록된다)"
  value       = local.loki_push_url
}
