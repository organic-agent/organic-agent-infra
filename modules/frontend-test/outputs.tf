output "instance_id" { value = aws_instance.this.id }
output "public_ip" { value = aws_eip.this.public_ip }
output "url" { value = "https://${var.fqdn}" }
output "artifact_bucket" { value = aws_s3_bucket.artifacts.id }
output "security_group_id" { value = aws_security_group.this.id }

output "artifact_bucket_arn" { value = aws_s3_bucket.artifacts.arn }
output "deploy_document_arn" { value = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:document/${aws_ssm_document.deploy.name}" }
output "deploy_document_name" { value = aws_ssm_document.deploy.name }
