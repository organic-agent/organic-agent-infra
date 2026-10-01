provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "wes"
      ManagedBy = "terraform"
    }
  }
}

# Bedrock을 부르는 리전. 조직 SCP가 `global.` 프로필을 막아 `us.` 프로필을 쓰고, 그 프로필은 미국 리전의
# 엔드포인트로만 부를 수 있다(#71). 엔드포인트 전용 VPC와 피어링 수락 쪽이 이 프로바이더로 만들어진다.
provider "aws" {
  alias  = "bedrock"
  region = var.bedrock_region

  default_tags {
    tags = {
      Project   = "wes"
      ManagedBy = "terraform"
    }
  }
}
