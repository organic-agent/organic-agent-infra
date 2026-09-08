#!/bin/bash
# wes-score GPU 워커의 실행 환경을 만든다. systemd 유닛의 ExecStartPre — 매 기동마다 다시 읽는다.
#
# 비밀 아닌 설정(DB 주소·버킷)도 AMI에 굽지 않고 SSM에서 읽는다. RDS를 교체하거나 버킷이 바뀌어도
# AMI를 다시 굽지 않기 위해서다(계획 결정 J). 인스턴스 롤은 아래 세 파라미터만 읽을 수 있다 —
# 같은 프리픽스의 JWT·OAuth 시크릿은 보이지 않는다.
#
# 결과는 /run(tmpfs, 0600)에만 쓴다. 디스크에 비밀번호가 남지 않고, 정지 뒤 다시 켜면 사라진다.
set -euo pipefail

# /etc/wes-score/image.env — AMI 빌드 때 Terraform이 넣는다(AWS_REGION · PARAMETER_PREFIX).
. /etc/wes-score/image.env

param() {
  aws ssm get-parameter --region "$AWS_REGION" --name "$1" --with-decryption \
    --query Parameter.Value --output text
}

url=$(param "${PARAMETER_PREFIX}/spring.datasource.url")        # jdbc:postgresql://host:5432/db?sslmode=require
password=$(param "${PARAMETER_PREFIX}/photoselect.db.password")
bucket=$(param "${PARAMETER_PREFIX}/app.storage.bucket")

# JDBC URL에서 host · port · db 를 잘라 낸다. 앱이 읽는 값과 같은 원본이라 어긋날 수 없다.
hostpath=${url#jdbc:postgresql://}
hostpath=${hostpath%%\?*}
hostport=${hostpath%%/*}
db_name=${hostpath#*/}
db_host=${hostport%%:*}
db_port=${hostport#*:}
[ "$db_port" = "$hostport" ] && db_port=5432

if [ -z "$db_host" ] || [ -z "$db_name" ] || [ -z "$password" ] || [ -z "$bucket" ]; then
  echo "wes-score-env: SSM 파라미터에서 DB 주소·비밀번호·버킷을 만들지 못했다 (url=$url bucket=$bucket)" >&2
  exit 1
fi

umask 077
tmp=$(mktemp /run/wes-score.env.XXXXXX)
cat > "$tmp" <<EOF
DB_HOST=$db_host
DB_PORT=$db_port
DB_NAME=$db_name
DB_PASSWORD=$password
S3_BUCKET=$bucket
EOF
mv "$tmp" /run/wes-score.env
