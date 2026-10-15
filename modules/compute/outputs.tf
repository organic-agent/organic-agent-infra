output "instance_id" {
  description = "EC2 인스턴스 ID"
  value       = try(aws_instance.this[0].id, null)
}

output "public_ip" {
  description = "인스턴스의 현재 퍼블릭 IP (stop/start 하면 바뀜)"
  value       = try(aws_instance.this[0].public_ip, null)
}

output "instance_role_name" {
  description = "앱 인스턴스 프로파일의 롤 이름. S3·Lambda 권한을 이 롤에 덧붙인다."
  value       = aws_iam_role.this.name
}

output "key_name" {
  description = "앱 서버에 등록한 키 페어 이름. 모니터링 서버도 같은 비상용 키를 쓴다."
  value       = aws_key_pair.this.key_name
}

output "instance_profile_name" {
  description = "앱 서버 인스턴스 프로파일 — ASG 시작 템플릿이 같은 역할을 쓴다"
  value       = aws_iam_instance_profile.this.name
}

output "ami_id" {
  description = "앱 서버 AMI(Ubuntu 24.04 arm64) — ASG 시작 템플릿이 같은 이미지를 쓴다"
  value       = data.aws_ami.ubuntu_arm64.id
}
