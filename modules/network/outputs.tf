output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "퍼블릭 서브넷 ID 목록 (ALB + EC2)"
  value       = aws_subnet.public[*].id
}

output "db_subnet_ids" {
  description = "데이터베이스 서브넷 ID 목록"
  value       = aws_subnet.db[*].id
}
