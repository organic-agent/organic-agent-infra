# 마스터 비밀번호는 Terraform 밖에서 생성함 (최초 1회 수동 작업):
#   aws ssm put-parameter --name <parameter_prefix>/spring.datasource.password --type SecureString --value '<password>'
# (이 환경의 실제 경로는 /wes/prod/spring.datasource.password — docs/runbook.md '사전 준비' 참고)
# ephemeral로 읽어서 write-only 인자로 넘기기 때문에 비밀번호가
# Terraform state에 절대 남지 않음. 비밀번호 변경 후 RDS에 반영하려면
# var.password_wo_version을 올리면 됨.
ephemeral "aws_ssm_parameter" "db_password" {
  arn = var.password_ssm_parameter_arn
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db"
  subnet_ids = var.subnet_ids # RDS는 single-AZ 인스턴스여도 2개 이상 AZ의 서브넷을 요구함

  tags = {
    Name = "${var.name_prefix}-db"
  }
}

resource "aws_db_instance" "this" {
  identifier = "${var.name_prefix}-db"

  engine                     = "postgres"
  engine_version             = var.engine_version
  auto_minor_version_upgrade = true

  instance_class    = var.instance_class
  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name             = var.db_name
  username            = var.db_username
  password_wo         = ephemeral.aws_ssm_parameter.db_password.value
  password_wo_version = var.password_wo_version

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false
  multi_az               = false # 운영용 아님

  backup_retention_period = 0     # 운영용 아님 — 날려도 되는 테스트 데이터
  skip_final_snapshot     = true  # 운영용 아님
  deletion_protection     = false # 운영용 아님
  apply_immediately       = true  # 운영용 아님 — 점검 시간대 안 기다림
}

# 앱이 SSM에서 직접 읽는 접속 정보 — 비밀 아님, RDS 생성 후 값이 확정되므로
# Terraform이 자동으로 채움. (password는 위 주석대로 수동 관리)
resource "aws_ssm_parameter" "datasource_url" {
  name  = "${var.parameter_prefix}/spring.datasource.url"
  type  = "String"
  value = "jdbc:postgresql://${aws_db_instance.this.address}:${aws_db_instance.this.port}/${aws_db_instance.this.db_name}?sslmode=require"
}

resource "aws_ssm_parameter" "datasource_username" {
  name  = "${var.parameter_prefix}/spring.datasource.username"
  type  = "String"
  value = var.db_username
}
