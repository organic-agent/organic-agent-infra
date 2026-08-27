output "instance_id" {
  description = "백오피스 전용 EC2 인스턴스 ID"
  value       = aws_instance.this.id
}

output "public_ip" {
  description = "아웃바운드 전용 퍼블릭 IP. 보안 그룹 인바운드는 비어 있다."
  value       = aws_instance.this.public_ip
}

output "fqdn" {
  description = "백오피스 커스텀 도메인"
  value       = var.fqdn
}

output "dns_configured" {
  description = "Tailscale IPv4 A 레코드 생성 여부"
  value       = var.tailscale_ipv4 != null
}

output "security_group_id" {
  description = "인바운드 규칙이 없는 백오피스 서버 보안 그룹 ID"
  value       = aws_security_group.this.id
}

output "instance_role_arn" {
  description = "SSM bootstrap key 읽기와 제한된 DNS-01 권한을 가진 인스턴스 역할 ARN"
  value       = aws_iam_role.this.arn
}

output "instance_role_name" {
  description = "관리자 API 전용 SSM·S3·Lambda 권한을 가진 인스턴스 역할 이름"
  value       = aws_iam_role.this.name
}

output "internal_network_name" {
  description = "BackOffice와 관리자 API가 서비스 통신에 사용할 Docker network 이름"
  value       = var.internal_network_name
}

output "runtime_network_name" {
  description = "관리자 API만 AWS/RDS egress에 사용할 Docker network 이름"
  value       = var.runtime_network_name
}

output "deploy_lock_path" {
  description = "wes-admin 호스트의 두 CD가 공유할 flock 경로"
  value       = var.deploy_lock_path
}
