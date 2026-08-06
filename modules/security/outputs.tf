output "alb_security_group_id" {
  description = "ALB용 보안 그룹 ID"
  value       = aws_security_group.alb.id
}

output "ec2_security_group_id" {
  description = "EC2 앱 서버용 보안 그룹 ID"
  value       = aws_security_group.ec2.id
}

output "rds_security_group_id" {
  description = "RDS용 보안 그룹 ID"
  value       = aws_security_group.rds.id
}

output "embedder_security_group_id" {
  description = "임베딩 Lambda의 ENI에 붙일 보안 그룹 ID"
  value       = aws_security_group.embedder.id
}
