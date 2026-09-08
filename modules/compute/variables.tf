variable "name_prefix" {
  description = "리소스 이름 접두사"
  type        = string
}

variable "subnet_id" {
  description = "인스턴스를 띄울 퍼블릭 서브넷"
  type        = string
}

variable "security_group_id" {
  description = "인스턴스에 붙일 보안 그룹 ID"
  type        = string
}

variable "instance_type" {
  description = "EC2 인스턴스 타입 (arm64 — AMI 필터가 arm64 전용)"
  type        = string
}

variable "ssh_public_key" {
  description = "EC2 키 페어로 등록할 SSH 퍼블릭 키"
  type        = string
}

variable "app_parameter_prefix_arn" {
  description = "인스턴스(앱)가 읽을 수 있는 SSM 파라미터 경로의 ARN (예: arn:...:parameter/wes/dev)"
  type        = string
}

variable "bedrock_model_id" {
  description = "앱(recommendation 도메인)이 추천 이유·비교샷 판정에 부르는 Bedrock 크로스 리전 추론 프로필 ID. 루트의 bedrock_model_id와 같은 값이며 앱 설정 app.llm.model-id와 일치해야 한다."
  type        = string
}

variable "score_gpu_tag_name" {
  description = "score GPU 워커 인스턴스의 Name 태그 값. 앱 롤의 ec2:StartInstances·StopInstances는 이 태그를 단 인스턴스로만 허용된다(wes app.analysis.gpu.tag와 같은 값)"
  type        = string
}
