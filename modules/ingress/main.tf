locals {
  fqdn = "${var.subdomain}.${var.zone_name}"
}

resource "aws_acm_certificate" "this" {
  domain_name       = local.fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = var.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}

resource "aws_lb" "this" {
  name               = var.name_prefix
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.security_group_id]
  subnets            = var.public_subnet_ids
}

resource "aws_lb_target_group" "app" {
  name        = "${var.name_prefix}-app"
  vpc_id      = var.vpc_id
  port        = var.app_port
  protocol    = "HTTP"
  target_type = "instance"

  health_check {
    path    = var.health_check_path
    matcher = "200-399" # 앱/actuator 배포 전까지는 느슨하게 잡아둠
  }
}

resource "aws_lb_target_group_attachment" "app" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = var.instance_id
  port             = var.app_port
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  # certificate가 아니라 validation 리소스를 참조해야 리스너가
  # DNS 검증이 실제로 끝날 때까지 기다림.
  certificate_arn = aws_acm_certificate_validation.this.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# 내부 관리자 API는 wes-admin BFF가 앱의 사설 IP로만 호출한다. public ALB에서는
# default forward보다 우선 평가해 앱 타깃에 도달하기 전에 존재를 숨기는 404로 끝낸다.
resource "aws_lb_listener_rule" "block_internal_admin" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 1

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "application/json"
      message_body = jsonencode({ message = "Not Found" })
      status_code  = "404"
    }
  }

  condition {
    path_pattern {
      values = ["/internal/admin", "/internal/admin/*"]
    }
  }
}

resource "aws_route53_record" "app" {
  zone_id = var.zone_id
  name    = local.fqdn
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = false
  }
}
