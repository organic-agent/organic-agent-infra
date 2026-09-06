# GitHub Actions may invoke this document, never AWS-RunShellScript.
# Only validated artifact coordinates enter the fixed host deployment command.
resource "aws_ssm_document" "deploy" {
  name            = "${var.name_prefix}-deploy"
  document_type   = "Command"
  document_format = "JSON"
  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Deploy a verified test frontend archive and validate its runtime"
    parameters = {
      ArtifactKey = {
        type              = "String"
        description       = "Private source archive key for the exact Git commit"
        allowedPattern    = "^releases/[a-f0-9]{40}\\.tar\\.gz$"
        interpolationType = "ENV_VAR"
      }
      ArtifactSha256 = {
        type              = "String"
        description       = "SHA256 of the source archive"
        allowedPattern    = "^[a-f0-9]{64}$"
        interpolationType = "ENV_VAR"
      }
      Revision = {
        type              = "String"
        description       = "Exact source commit SHA"
        allowedPattern    = "^[a-f0-9]{40}$"
        interpolationType = "ENV_VAR"
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "deployVerifiedFrontend"
      inputs = {
        timeoutSeconds = "1800"
        runCommand     = ["bash -s <<'WES_FRONTEND_DEPLOY'\n${file("${path.module}/deploy-command.sh")}\nWES_FRONTEND_DEPLOY"]
      }
    }]
  })
}
