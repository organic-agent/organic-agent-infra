output "instance_id" {
  description = "EC2 인스턴스 ID"
  value       = aws_instance.this.id
}

output "public_ip" {
  description = "인스턴스의 현재 퍼블릭 IP (stop/start 하면 바뀜)"
  value       = aws_instance.this.public_ip
}
