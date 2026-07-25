terraform {
  backend "s3" {
    bucket       = "wes-tf-state-233927217926"
    key          = "app/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true # S3 네이티브 락 사용
  }
}
