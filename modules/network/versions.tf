terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
      # aws.bedrock: Bedrock을 부르는 리전(엔드포인트 전용 VPC·피어링 수락 쪽). bedrock.tf 참고.
      configuration_aliases = [aws.bedrock]
    }
  }
}
