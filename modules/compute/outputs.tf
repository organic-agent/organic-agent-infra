output "instance_id" {
  description = "EC2 인스턴스 ID"
  value       = aws_instance.this.id
}

output "public_ip" {
  description = "인스턴스의 현재 퍼블릭 IP (stop/start 하면 바뀜)"
  value       = aws_instance.this.public_ip
}

output "instance_role_name" {
  description = "앱 인스턴스 프로파일의 롤 이름. S3·Lambda 권한을 이 롤에 덧붙인다."
  value       = aws_iam_role.this.name
}

output "key_name" {
  description = "앱 서버에 등록한 키 페어 이름. 모니터링 서버도 같은 비상용 키를 쓴다."
  value       = aws_key_pair.this.key_name
}
