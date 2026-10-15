output "autoscaling_group_name" {
  description = "앱 서버 ASG 이름"
  value       = aws_autoscaling_group.app.name
}
