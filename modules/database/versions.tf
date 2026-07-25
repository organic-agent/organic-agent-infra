terraform {
  # ephemeral 리소스 + write-only 인자 때문에 1.11 이상 필요
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}
