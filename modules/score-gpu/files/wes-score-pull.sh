#!/bin/bash
# ECR 로그인 + 이동 태그 pull. systemd 유닛의 ExecStartPre.
#
# AMI에는 코드 이미지를 굽지 않는다(계획 결정 B). AI 저장소 CI가 push마다 `gpu`(이동)·`gpu-<sha>`(불변)를
# 함께 올리므로, 기동 때 `gpu`를 pull 하면 레이어가 같을 땐 수 초, 바뀐 레이어만 내려받는다.
#
# pull 앞뒤로 dangling 이미지(태그를 잃은 옛 `gpu`)를 지운다. 이미지 하나가 풀면 약 7GB라, 지우지 않으면 새 버전이
# 올라올 때마다 30GB 루트 볼륨에 쌓여 pull이 no space left on device로 실패하고 워커가 뜨지 못한다(#67).
# 앞의 prune은 이전 기동이 pull 직후 꺼져 못 지운 것을 치운다. 정리 실패로 기동을 막지는 않는다.
set -euo pipefail

. /etc/wes-score/image.env

registry=${WES_SCORE_IMAGE%%/*}
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$registry" >/dev/null
docker image prune --force >/dev/null || true
docker pull --quiet "$WES_SCORE_IMAGE"
docker image prune --force >/dev/null || true
