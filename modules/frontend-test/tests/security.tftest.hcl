mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_ami" {
    defaults = { id = "ami-0123456789abcdef0" }
  }
}
variables {
  name_prefix = "wes-frontend-test"
  aws_region  = "ap-northeast-2"
  vpc_id      = "vpc-test"
  subnet_id   = "subnet-test"
  zone_id     = "ZTEST"
  fqdn        = "test.example.com"
}
run "public_web_ports_only" {
  command = plan
  assert {
    condition     = aws_vpc_security_group_ingress_rule.http.from_port == 80 && aws_vpc_security_group_ingress_rule.http.to_port == 80 && aws_vpc_security_group_ingress_rule.https.from_port == 443 && aws_vpc_security_group_ingress_rule.https.to_port == 443
    error_message = "Only web ports may be opened; application and SSH ports must remain closed."
  }
  assert {
    condition     = aws_instance.this.metadata_options[0].http_tokens == "required" && aws_instance.this.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "Require SSM and IMDSv2 with no metadata response hop into app containers."
  }
  assert {
    condition     = aws_instance.this.root_block_device[0].encrypted && aws_instance.this.root_block_device[0].volume_size == 20
    error_message = "The dedicated test disk must be encrypted and bounded to 20 GiB."
  }
}
run "private_artifact_and_secret_boundary" {
  command = apply
  assert {
    condition     = aws_s3_bucket_public_access_block.artifacts.block_public_acls && aws_s3_bucket_public_access_block.artifacts.block_public_policy && aws_s3_bucket_public_access_block.artifacts.ignore_public_acls && aws_s3_bucket_public_access_block.artifacts.restrict_public_buckets
    error_message = "Deployment source archives must never become public."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.artifacts.policy).Statement[0].Action == ["s3:GetObject"] && jsondecode(aws_iam_role_policy.artifacts.policy).Statement[1].Effect == "Deny"
    error_message = "The host may only read releases, and WES application secrets must be explicitly denied."
  }
}
