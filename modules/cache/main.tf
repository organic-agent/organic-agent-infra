# 앱 서버들이 함께 쓰는 Redis 호환 캐시(ElastiCache Valkey) — 서버 저장소 #313 ADR-0002.
#
# 담는 것은 잃어도 되는 값뿐이다: 서명 URL·권한 캐시의 공유 층(앱은 서버 메모리 → 이 캐시 → 계산·DB 순서로 보고, 이 캐시가
# 안 되면 서버 메모리로 돌아간다)과 주기 작업 리더 잠금. 그래서 노드는 하나, 스냅샷·복제본 없음. refresh token 같은 잃으면
# 안 되는 상태는 DB에 둔다 — 여기 두려면 복제본·영속화부터 다시 정한다.
#
# 엔진은 Valkey(Redis OSS 포크, 프로토콜 같음). 같은 노드가 Redis OSS보다 싸다(서울 t4g.micro 시간당 $0.0192 vs $0.024).
# 복제 그룹으로 만든다 — 노드 하나여도 나중에 복제본을 붙일 때 다시 만들지 않는다.

resource "aws_security_group" "this" {
  name        = "${var.name_prefix}-cache"
  description = "Shared cache - only app servers"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-cache"
  }
}

resource "aws_vpc_security_group_ingress_rule" "from_clients" {
  for_each = toset(var.client_security_group_ids)

  security_group_id            = aws_security_group.this.id
  description                  = "Valkey from app servers"
  referenced_security_group_id = each.value
  from_port                    = var.port
  to_port                      = var.port
  ip_protocol                  = "tcp"
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name_prefix}-cache"
  subnet_ids = var.subnet_ids
}

# 담는 값이 전부 TTL 있는 캐시·잠금이라 메모리가 차면 오래 안 쓴 것부터 버린다(기본 volatile-lru는 TTL 없는 키를 못 버림).
resource "aws_elasticache_parameter_group" "this" {
  name   = "${var.name_prefix}-cache"
  family = var.parameter_group_family

  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${var.name_prefix}-cache"
  description          = "Shared cache and scheduler leader lock (ADR-0002)"

  engine               = "valkey"
  engine_version       = var.engine_version
  node_type            = var.node_type
  num_cache_clusters   = 1
  port                 = var.port
  parameter_group_name = aws_elasticache_parameter_group.this.name

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.this.id]

  automatic_failover_enabled = false
  multi_az_enabled           = false

  # 사설 서브넷 + 앱 SG만 받는다. 전송 암호화는 켜고(앱은 TLS로 붙음), 비밀번호(AUTH)는 두지 않는다 — 경계는 보안 그룹.
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  # 잃어도 되는 값만 담으므로 스냅샷을 남기지 않는다.
  snapshot_retention_limit = 0

  auto_minor_version_upgrade = true
  apply_immediately          = var.apply_immediately

  tags = {
    Name = "${var.name_prefix}-cache"
  }
}

# 앱(Spring Boot)이 시작 때 Parameter Store에서 읽는 접속 정보. 이름이 곧 Spring 속성 이름이다.
resource "aws_ssm_parameter" "host" {
  name  = "${var.parameter_prefix}/spring.data.redis.host"
  type  = "String"
  value = aws_elasticache_replication_group.this.primary_endpoint_address
}

resource "aws_ssm_parameter" "port" {
  name  = "${var.parameter_prefix}/spring.data.redis.port"
  type  = "String"
  value = tostring(var.port)
}

resource "aws_ssm_parameter" "ssl" {
  name  = "${var.parameter_prefix}/spring.data.redis.ssl.enabled"
  type  = "String"
  value = "true"
}
