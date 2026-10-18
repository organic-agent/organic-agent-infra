# 운영 RDS(db.t4g.micro) 경보 — 서버 저장소 #313 10-17 결정 "DB 그대로 + 경보"(안건 5).
#
# 근거: 운영 DB 322MB·사진 2.7만 장인데 스왑 375MB·남은 메모리 ≈ 63MB(10-17). dev 는 10-17 디스크 버스트(EBSByteBalance%)가 0 이 되자
# 읽기 1 → 65ms 로 무너졌다(A-4b-10g 무효). 셋 중 하나가 울리면 small 로 올릴 때다(위험 구간 ≈ 사진 10만~20만 장).
# 알림 대상은 아직 없다 — 상태만 콘솔·Grafana 에서 본다(디스코드 연결은 따로).

locals {
  rds_alarms = {
    free-memory = {
      metric      = "FreeableMemory"
      statistic   = "Minimum"
      comparison  = "LessThanThreshold"
      threshold   = 40 * 1024 * 1024
      description = "RDS 남은 메모리 < 40MB (10분) — small 로 올릴 신호"
    }
    swap = {
      metric      = "SwapUsage"
      statistic   = "Maximum"
      comparison  = "GreaterThanThreshold"
      threshold   = 500 * 1024 * 1024
      description = "RDS 스왑 > 500MB (10분) — 메모리 부족"
    }
    disk-burst = {
      metric      = "EBSByteBalance%"
      statistic   = "Minimum"
      comparison  = "LessThanThreshold"
      threshold   = 20
      description = "RDS 디스크 버스트 < 20% (10분) — 0 이 되면 읽기가 수십 배 느려진다"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "rds" {
  for_each = local.rds_alarms

  alarm_name          = "${local.name_prefix}-db-${each.key}"
  alarm_description   = each.value.description
  namespace           = "AWS/RDS"
  metric_name         = each.value.metric
  dimensions          = { DBInstanceIdentifier = "${local.name_prefix}-db" }
  statistic           = each.value.statistic
  period              = 300
  evaluation_periods  = 2
  comparison_operator = each.value.comparison
  threshold           = each.value.threshold
  treat_missing_data  = "missing"
}
