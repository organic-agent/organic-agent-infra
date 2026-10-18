provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "wes"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

# 미리보기 CDN 인증서(CloudFront 는 us-east-1 인증서만 받는다, #336).
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "wes"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}
