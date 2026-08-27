mock_provider "aws" {
  mock_data "aws_ami" {
    defaults = {
      id = "ami-0123456789abcdef0"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  name_prefix                   = "wes-admin"
  aws_region                    = "ap-northeast-2"
  vpc_id                        = "vpc-0123456789abcdef0"
  subnet_id                     = "subnet-0123456789abcdef0"
  instance_type                 = "t4g.small"
  zone_id                       = "Z0123456789ABC"
  fqdn                          = "admin.easyselect.kr"
  tailscale_hostname            = "wes-admin"
  tailscale_auth_parameter_name = "/wes/admin/tailscale-auth-key"
  tailscale_auth_parameter_arn  = "arn:aws:ssm:ap-northeast-2:233927217926:parameter/wes/admin/tailscale-auth-key"
  tailscale_auth_kms_key_arn    = null
  runtime_parameter_prefix_arn  = "arn:aws:ssm:ap-northeast-2:233927217926:parameter/wes/admin-api/prod"
  runtime_kms_key_arn           = null
  photo_bucket_arn              = "arn:aws:s3:::wes-photos-test"
  embedding_function_arn        = "arn:aws:lambda:ap-northeast-2:233927217926:function:wes-embedder-test"
  app_port                      = 8080
}

run "plan_before_tailnet_join" {
  command = plan

  assert {
    condition     = length(aws_route53_record.admin) == 0
    error_message = "Tailscale IP를 확인하기 전에는 DNS 레코드를 만들면 안 됩니다."
  }

  assert {
    condition     = aws_instance.this.metadata_options[0].http_tokens == "required" && aws_instance.this.metadata_options[0].http_put_response_hop_limit == 2 && aws_instance.this.metadata_options[0].http_protocol_ipv6 == "disabled"
    error_message = "관리자 API 컨테이너용 IMDSv2 hop 2와 IPv6 metadata 차단을 강제해야 합니다."
  }

  assert {
    condition     = aws_instance.this.root_block_device[0].encrypted
    error_message = "인증서와 Tailscale 노드 상태가 저장되는 루트 볼륨은 암호화해야 합니다."
  }

  assert {
    condition     = aws_ssm_association.runtime_host.name == "AWS-RunShellScript"
    error_message = "기존 인스턴스에도 Docker network·IMDS firewall·flock 계약을 적용해야 합니다."
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "docker-compose-v2") && strcontains(local.runtime_host_script, "docker-compose-v2") && strcontains(local.runtime_host_script, "docker compose version")
    error_message = "신규·기존 관리자 인스턴스 모두 Docker Compose v2 실행 계약을 보장해야 합니다."
  }

  assert {
    condition     = local.backoffice_internal_ip == "172.30.0.10" && strcontains(local.caddyfile, "reverse_proxy 172.30.0.10:8080") && strcontains(local.runtime_host_script, "flock -w 600 9") && strcontains(local.runtime_host_script, "[ -x /usr/local/bin/caddy ]") && strcontains(local.runtime_host_script, "systemctl reload-or-restart caddy.service")
    error_message = "BackOffice는 internal 고정 IP를 사용하고 기존 Caddy도 Association으로 갱신해야 합니다."
  }
}

run "plan_after_tailnet_join" {
  command = plan

  variables {
    tailscale_ipv4 = "100.100.100.100"
  }

  assert {
    condition     = one(aws_route53_record.admin[*].records) == toset(["100.100.100.100"])
    error_message = "admin A 레코드는 확인된 Tailscale IPv4 하나만 가리켜야 합니다."
  }
}

run "reject_public_ipv4" {
  command = plan

  variables {
    tailscale_ipv4 = "203.0.113.10"
  }

  expect_failures = [var.tailscale_ipv4]
}
