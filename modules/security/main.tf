# ALB<->EC2 SG가 서로 참조하면서 생성 시점에 순환 참조가 생기지 않도록
# inline 블록 대신 별도 rule 리소스로 분리함.

resource "aws_security_group" "alb" {
  name_prefix = "${var.name_prefix}-alb-"
  description = "ALB: public HTTP/HTTPS in, app port out"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-alb"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "ec2" {
  name_prefix = "${var.name_prefix}-ec2-"
  description = "EC2 app server: app port from ALB, SSH from operator"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-ec2"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "rds" {
  name_prefix = "${var.name_prefix}-rds-"
  description = "RDS: database port from EC2 only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-rds"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# --- ALB ---

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP (redirected to HTTPS)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to app instances"
  referenced_security_group_id = aws_security_group.ec2.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
}

# --- EC2 ---

resource "aws_vpc_security_group_ingress_rule" "ec2_app_from_alb" {
  security_group_id            = aws_security_group.ec2.id
  description                  = "App traffic from ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
}

# 평소엔 SSM Session Manager로 접속하므로 SSH는 기본 차단. 비상시에만 CIDR 지정.
resource "aws_vpc_security_group_ingress_rule" "ec2_ssh" {
  count = var.ssh_allowed_cidr != null ? 1 : 0

  security_group_id = aws_security_group.ec2.id
  description       = "SSH from operator"
  cidr_ipv4         = var.ssh_allowed_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

# egress 전체 오픈: OAuth 토큰 교환(카카오/구글/네이버), dnf 저장소, SSM, RDS 용도.
resource "aws_vpc_security_group_egress_rule" "ec2_all" {
  security_group_id = aws_security_group.ec2.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- RDS ---

resource "aws_vpc_security_group_ingress_rule" "rds_from_ec2" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL from app server"
  referenced_security_group_id = aws_security_group.ec2.id
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = "tcp"
}
