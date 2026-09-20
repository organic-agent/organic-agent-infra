# score GPU 워커 풀 — 2단계: 워커 인스턴스·롤·유휴 정지 알람(계획 docs/plans/pipeline-v2-infra-plan.md §4.1 아래쪽 절반·§4.2·§4.5, PR-3c).
#
# 인스턴스는 main.tf의 파이프라인이 만든 AMI(var.gpu_ami_id)로 AZ마다 한 대씩 만들고 생성 직후 정지시킨다. 그 뒤 켜고
# 끄는 것은 코드의 몫이다 — wes GpuController(태그 Name=<local.name>로 탐색, backlog 있으면 Start, 무진행 안전망 Stop)와
# 워커의 유휴 자기 정지(WORKER_IDLE_STOP_SECONDS). 인프라는 둘이 다 죽었을 때를 위한 CloudWatch 정지 알람만 소유한다(결정 L).
#
# 정지된 인스턴스는 루트 볼륨을 그대로 가지므로 Start 경로는 AMI와 무관하다. AMI를 바꾸면(gpu_ami_id) 인스턴스가 replace
# 되고, aws_ec2_instance_state가 함께 다시 만들어져 새 인스턴스도 정지 상태로 시작한다. 워커는 상태가 없어 안전하다.

locals {
  ssm_parameter_arn_prefix = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${var.parameter_prefix}"

  # env 스크립트(files/wes-score-env.sh)가 읽는 파라미터 그대로. 프리픽스 와일드카드는 열지 않는다(결정 J) — 같은 프리픽스에
  # JWT·OAuth 시크릿이 있다.
  worker_parameter_arns = [
    "${local.ssm_parameter_arn_prefix}/spring.datasource.url",
    "${local.ssm_parameter_arn_prefix}/photoselect.db.password",
    "${local.ssm_parameter_arn_prefix}/app.storage.bucket",
  ]
}

# --- 워커 롤 (§4.2) ---

resource "aws_iam_role" "worker" {
  name_prefix        = "${local.name}-worker-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = {
    Name = "${local.name}-worker"
  }
}

resource "aws_iam_role_policy_attachment" "worker_ssm_core" {
  role       = aws_iam_role.worker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "worker" {
  # score Lambda와 같은 범위 — 미리보기만. 원본은 볼 이유가 없다.
  statement {
    sid       = "ReadPreviews"
    actions   = ["s3:GetObject"]
    resources = ["${var.photo_bucket_arn}/previews/*"]
  }

  # 부팅 때 files/wes-score-pull.sh가 ECR 로그인 뒤 wes-score:gpu를 pull 한다. GetAuthorizationToken은 리소스 조건이 없다.
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "PullScoreImage"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
    ]
    resources = [var.score_repository_arn]
  }

  statement {
    sid       = "ReadRuntimeParameters"
    actions   = ["ssm:GetParameter"]
    resources = local.worker_parameter_arns
  }

  # 파라미터가 기본 alias/aws/ssm 키라 엄밀히는 불필요하지만, 고객 관리형 키로 바꿔도 깨지지 않게 SSM 경유로만 허용한다.
  statement {
    sid       = "DecryptViaSsm"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.name}.amazonaws.com"]
    }
  }

  # 유휴 자기 정지와 failsafe. IAM으로 "자기 자신만"은 표현할 수 없어 풀 태그로 좁힌다 — 같은 태그는 이 풀뿐이다.
  statement {
    sid       = "StopSelf"
    actions   = ["ec2:StopInstances"]
    resources = ["arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/Name"
      values   = [local.name]
    }
  }
}

resource "aws_iam_role_policy" "worker" {
  name   = "score-gpu-worker"
  role   = aws_iam_role.worker.name
  policy = data.aws_iam_policy_document.worker.json
}

resource "aws_iam_instance_profile" "worker" {
  name_prefix = "${local.name}-worker-"
  role        = aws_iam_role.worker.name
}

# --- 워커 인스턴스 (결정 A) ---

resource "aws_instance" "this" {
  for_each = var.worker_subnet_ids

  ami                         = var.gpu_ami_id
  instance_type               = var.worker_instance_type
  subnet_id                   = each.value
  vpc_security_group_ids      = [var.worker_security_group_id]
  iam_instance_profile        = aws_iam_instance_profile.worker.name
  associate_public_ip_address = true
  # key_name 없음 — 접속은 SSM만.

  # 컨테이너 안의 워커가 IMDSv2로 롤 자격증명과 자기 인스턴스 ID를 얻는다(도커 브리지 한 홉 더).
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    throughput  = var.gpu_root_throughput
    encrypted   = true
  }

  # 유닛은 AMI에 있다 — user_data 없음.

  tags = {
    Name = local.name
    Role = "score-gpu-worker"
  }

  lifecycle {
    # 정지된 인스턴스는 퍼블릭 IP가 회수돼 API가 "없음"으로 답하고, 프로바이더는 그걸 associate_public_ip_address =
    # false로 읽어 **매 plan마다 replace**를 만든다(#57에서 발견 — 첫 apply 뒤 두 대가 정지되자마자 드리프트).
    # 서브넷이 map_public_ip_on_launch라 켜질 때마다 새 퍼블릭 IP를 받으므로 이 속성의 드리프트는 무시해도 된다.
    ignore_changes = [associate_public_ip_address]
  }
}

# 생성 직후 한 번 정지시킨다. 그 뒤 start/stop은 wes와 워커가 소유하므로 state 드리프트는 무시한다 — 이게 없으면 첫 apply
# 뒤 두 대가 running으로 남아 시간당 요금을 그냥 쓴다.
resource "aws_ec2_instance_state" "stopped" {
  for_each = aws_instance.this

  instance_id = each.value.id
  state       = "stopped"

  lifecycle {
    ignore_changes = [state]
  }
}

# --- 최후 안전장치: 인스턴스별 유휴 정지 알람 (결정 L, §4.5) ---
#
# CPU 평균이 30분(5분 × 6) 연속 5% 아래면 그 인스턴스를 정지한다. 대상은 dimension InstanceId — 이 모듈의 인스턴스 하나씩만
# 가리키고, 태그나 계정 전체 규칙이 아니다(앱 서버 t4g.micro는 평상시 CPU가 5% 아래라 태그 기준이면 꺼졌을 것이다).
# 정지 중엔 지표가 없으므로 notBreaching — 헛방으로 알람이 울리지 않는다. 정지 액션은 CloudWatch Events 서비스 연결 역할
# (main.tf)이 수행한다.
resource "aws_cloudwatch_metric_alarm" "idle_stop" {
  for_each = aws_instance.this

  alarm_name          = "${local.name}-idle-stop-${each.key}"
  alarm_description   = "Stop the score GPU worker in ${each.key} after 30 minutes below 5% CPU (last-resort idle stop)"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 6
  datapoints_to_alarm = 6
  threshold           = 5
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = each.value.id
  }

  alarm_actions = ["arn:aws:automate:${data.aws_region.current.name}:ec2:stop"]

  depends_on = [aws_iam_service_linked_role.cloudwatch_events]
}
