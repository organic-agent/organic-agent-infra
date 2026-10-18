terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # CloudFront 인증서는 us-east-1 에만 만들 수 있다 — 부르는 쪽이 그 리전 프로바이더를 넘긴다.
      configuration_aliases = [aws.us_east_1]
    }
  }
}
