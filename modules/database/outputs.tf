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

output "resource_id" {
  description = <<-EOT
    RDS 리소스 ID(db-XXXX). IAM 인증 정책의 ARN이 인스턴스 식별자가 아니라 이 값을 쓴다:
    arn:aws:rds-db:<리전>:<계정>:dbuser:<resource_id>/<db_user>
  EOT
  value       = aws_db_instance.this.resource_id
}
