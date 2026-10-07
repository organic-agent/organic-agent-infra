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
