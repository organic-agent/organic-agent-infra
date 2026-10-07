# score GPU 워커 풀 — 2단계(PR-3c). 본문은 modules/score-gpu-workers로 옮겼다 — dev 환경(environments/dev)이 운영 AMI로
# 자기 풀을 만들 때 파이프라인 없이 같은 모듈을 쓰기 때문이다. 운영 풀은 이름·프리픽스가 AMI에 구워진 값과 같아 user_data가 없다.
module "workers" {
  source = "../score-gpu-workers"

  name                     = local.name
  parameter_prefix         = var.parameter_prefix
  gpu_ami_id               = var.gpu_ami_id
  worker_instance_type     = var.worker_instance_type
  gpu_root_throughput      = var.gpu_root_throughput
  worker_subnet_ids        = var.worker_subnet_ids
  worker_security_group_id = var.worker_security_group_id
  photo_bucket_arn         = var.photo_bucket_arn
  score_repository_arn     = var.score_repository_arn

  # 유휴 정지 알람의 EC2 정지 액션은 이 서비스 연결 역할이 수행한다. 알람보다 먼저 있어야 액션 검증에 걸리지 않는다.
  depends_on = [aws_iam_service_linked_role.cloudwatch_events]
}

# 주소만 바뀌고 재생성되지 않는다. 워커 인스턴스가 replace 되면 정지 상태로 다시 생기긴 하지만, 롤·프로파일·알람까지
# 이름이 바뀌어 wes가 켜는 도중의 풀을 깨뜨릴 수 있으니 옮기기만 한다.
moved {
  from = aws_iam_role.worker
  to   = module.workers.aws_iam_role.worker
}

moved {
  from = aws_iam_role_policy_attachment.worker_ssm_core
  to   = module.workers.aws_iam_role_policy_attachment.worker_ssm_core
}

moved {
  from = aws_iam_role_policy.worker
  to   = module.workers.aws_iam_role_policy.worker
}

moved {
  from = aws_iam_instance_profile.worker
  to   = module.workers.aws_iam_instance_profile.worker
}

moved {
  from = aws_instance.this
  to   = module.workers.aws_instance.this
}

moved {
  from = aws_ec2_instance_state.stopped
  to   = module.workers.aws_ec2_instance_state.stopped
}

moved {
  from = aws_cloudwatch_metric_alarm.idle_stop
  to   = module.workers.aws_cloudwatch_metric_alarm.idle_stop
}
