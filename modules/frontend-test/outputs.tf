output "instance_id" { value = aws_instance.this.id }
output "public_ip" { value = aws_eip.this.public_ip }
output "url" { value = "https://${var.fqdn}" }
output "artifact_bucket" { value = aws_s3_bucket.artifacts.id }
output "security_group_id" { value = aws_security_group.this.id }
