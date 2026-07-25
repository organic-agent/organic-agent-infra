output "app_fqdn" {
  description = "앱의 FQDN"
  value       = local.fqdn
}

output "alb_dns_name" {
  description = "ALB의 DNS 이름"
  value       = aws_lb.this.dns_name
}

output "target_group_arn" {
  description = "앱 타깃 그룹의 ARN"
  value       = aws_lb_target_group.app.arn
}
