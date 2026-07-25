output "endpoint" {
  description = "RDS 엔드포인트 (host:port)"
  value       = aws_db_instance.this.endpoint
}

output "address" {
  description = "RDS 호스트네임"
  value       = aws_db_instance.this.address
}

output "port" {
  description = "RDS 포트"
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "초기 데이터베이스 이름"
  value       = aws_db_instance.this.db_name
}
