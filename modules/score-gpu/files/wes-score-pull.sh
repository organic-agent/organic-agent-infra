#!/bin/bash
# ECR 로그인 + 이동 태그 pull. systemd 유닛의 ExecStartPre.
#
# AMI에는 코드 이미지를 굽지 않는다(계획 결정 B). AI 저장소 CI가 push마다 `gpu`(이동)·`gpu-<sha>`(불변)를
# 함께 올리므로, 기동 때 `gpu`를 pull 하면 레이어가 같을 땐 수 초, 바뀐 레이어만 내려받는다.
set -euo pipefail

. /etc/wes-score/image.env

registry=${WES_SCORE_IMAGE%%/*}
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$registry" >/dev/null
docker pull --quiet "$WES_SCORE_IMAGE"
