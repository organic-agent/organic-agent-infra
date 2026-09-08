#!/bin/bash
# wes-score 유닛이 failed 상태가 되면(OnFailure=) 자기 인스턴스를 정지시킨다.
#
# 워커가 정상이라면 유휴 뒤 스스로 StopInstances 를 부른다. 워커가 아예 못 뜨는 경우(이미지 깨짐·SSM 실패·
# 연속 실패 상한)에는 그 경로가 없어 인스턴스가 g6.xlarge 시간당 요금을 내며 켜져 있게 된다. CloudWatch 유휴
# 알람(계획 결정 L)이 30분 뒤 잡지만, 그 전에 여기서 끈다. 인스턴스 롤에 StopInstances 가 없으면(AMI 테스트
# 인스턴스) 실패하고 끝난다 — 그 경우는 Image Builder 가 인스턴스를 치운다.
set -uo pipefail

. /etc/wes-score/image.env

token=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60") || exit 0
instance_id=$(curl -sf -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/instance-id") || exit 0

echo "wes-score failsafe: 워커 기동 실패 — $instance_id 를 정지시킨다" | systemd-cat -t wes-score-failsafe -p warning
aws ec2 stop-instances --region "$AWS_REGION" --instance-ids "$instance_id" >/dev/null
