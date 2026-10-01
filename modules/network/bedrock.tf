# --- 이 VPC가 다른 리전의 Bedrock에 닿을 통로 (#71) ---
#
# 조직 SCP가 2026-09-30부터 `global.` 크로스 리전 프로필을 거부한다(기반 모델 ARN의 리전 자리가 비어 있다).
# `us.` 프로필은 통과하지만 미국 리전의 bedrock-runtime으로만 부를 수 있고, categorize Lambda가 있는 DB 서브넷은
# 인터넷 경로가 없다. 그래서 Bedrock 리전에 엔드포인트만 담는 VPC를 두고 리전 간 피어링으로 잇는다.
#
#   Lambda(DB 서브넷)·앱(퍼블릭 서브넷) ──피어링──▶ [Bedrock 리전 VPC] bedrock-runtime 인터페이스 엔드포인트
#
# NAT 게이트웨이(월 약 $43)가 아닌 이유: 이쪽은 ENI 하나(약 $0.01/h ≈ 월 $7.3) + 호스티드 존 $0.5이고,
# DB 서브넷에 0.0.0.0/0을 열지 않아도 된다. 피어링 자체는 무료, 리전 간 전송은 GB당 과금(사진 몇 장 수준).
#
# 리소스 이름을 서울에 있던 `aws_vpc_endpoint.bedrock_runtime`·`aws_security_group.vpc_endpoints`와 다르게 둔 것은
# 의도다 — 같은 주소로 프로바이더만 바꾸면 Terraform이 서울의 옛 리소스를 지우지 않고 잃어버린다.

data "aws_region" "bedrock" {
  provider = aws.bedrock
}

# 인터페이스 엔드포인트는 서비스가 지원하는 AZ에만 둘 수 있다.
data "aws_vpc_endpoint_service" "bedrock_runtime" {
  provider = aws.bedrock

  service      = "bedrock-runtime"
  service_type = "Interface"
}

# 엔드포인트 ENI 하나만 사는 VPC. IGW·NAT가 없고 라우트는 피어링 하나뿐이다.
resource "aws_vpc" "bedrock" {
  provider = aws.bedrock

  cidr_block = var.bedrock_vpc_cidr

  tags = {
    Name = "${var.name_prefix}-bedrock-vpc"
  }
}

# 한 AZ. 앱 EC2·RDS가 단일 AZ라 여기만 이중화해 얻는 것이 없고, ENI가 곧 시간당 과금이다.
resource "aws_subnet" "bedrock" {
  provider = aws.bedrock

  vpc_id            = aws_vpc.bedrock.id
  availability_zone = sort(tolist(data.aws_vpc_endpoint_service.bedrock_runtime.availability_zones))[0]
  cidr_block        = var.bedrock_vpc_cidr

  tags = {
    Name = "${var.name_prefix}-bedrock"
  }

  lifecycle {
    # 서비스의 AZ 목록이 바뀌어도 이미 만든 서브넷(= 엔드포인트 ENI)을 갈아 끼우지 않는다.
    ignore_changes = [availability_zone]
  }
}

resource "aws_vpc_peering_connection" "bedrock" {
  vpc_id      = aws_vpc.this.id
  peer_vpc_id = aws_vpc.bedrock.id
  peer_region = data.aws_region.bedrock.name

  tags = {
    Name = "${var.name_prefix}-bedrock"
  }
}

# 리전 간 피어링은 요청 쪽에서 auto_accept를 쓸 수 없어 상대 리전에서 수락한다. 아래 라우트가 이 리소스의
# id를 쓰는 것은 수락(active)을 기다리기 위해서다 — pending 상태의 연결에는 라우트를 걸 수 없다.
resource "aws_vpc_peering_connection_accepter" "bedrock" {
  provider = aws.bedrock

  vpc_peering_connection_id = aws_vpc_peering_connection.bedrock.id
  auto_accept               = true

  tags = {
    Name = "${var.name_prefix}-bedrock"
  }
}

# DB 서브넷 → Bedrock VPC. 퍼블릭 서브넷 쪽 라우트는 aws_route_table.public의 인라인 블록에 있다
# (인라인 라우트를 쓰는 테이블에 aws_route를 섞으면 다음 apply가 지운다).
resource "aws_route" "db_to_bedrock" {
  route_table_id            = aws_route_table.db.id
  destination_cidr_block    = aws_vpc.bedrock.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.bedrock.id
}

resource "aws_route_table" "bedrock" {
  provider = aws.bedrock

  vpc_id = aws_vpc.bedrock.id

  tags = {
    Name = "${var.name_prefix}-bedrock-rt"
  }
}

resource "aws_route_table_association" "bedrock" {
  provider = aws.bedrock

  subnet_id      = aws_subnet.bedrock.id
  route_table_id = aws_route_table.bedrock.id
}

# 응답이 돌아갈 길.
resource "aws_route" "bedrock_to_main" {
  provider = aws.bedrock

  route_table_id            = aws_route_table.bedrock.id
  destination_cidr_block    = aws_vpc.this.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.bedrock.id
}

# 엔드포인트 ENI의 보안 그룹. 리전 간 피어링은 상대 VPC의 보안 그룹을 참조할 수 없어 CIDR로 받는다.
resource "aws_security_group" "bedrock_endpoint" {
  provider = aws.bedrock

  name_prefix = "${var.name_prefix}-bedrock-vpce-"
  description = "bedrock-runtime interface endpoint: HTTPS from the peered app VPC"
  vpc_id      = aws_vpc.bedrock.id

  tags = {
    Name = "${var.name_prefix}-bedrock-vpce"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "bedrock_endpoint_https" {
  provider = aws.bedrock

  security_group_id = aws_security_group.bedrock_endpoint.id
  description       = "HTTPS from the app VPC over peering (categorize Lambda, app EC2)"
  cidr_ipv4         = aws_vpc.this.cidr_block
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# private DNS는 끈다 — 그 옵션은 엔드포인트가 있는 VPC 안에서만 이름을 바꿔 주고, 부르는 쪽은 서울 VPC다.
# 서울 VPC의 이름 풀이는 아래 프라이빗 호스티드 존이 맡는다.
resource "aws_vpc_endpoint" "bedrock" {
  provider = aws.bedrock

  vpc_id              = aws_vpc.bedrock.id
  service_name        = data.aws_vpc_endpoint_service.bedrock_runtime.service_name
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.bedrock.id]
  security_group_ids  = [aws_security_group.bedrock_endpoint.id]
  private_dns_enabled = false

  tags = {
    Name = "${var.name_prefix}-bedrock-runtime"
  }
}

# 함수·앱 코드는 SDK 기본 호스트네임(`bedrock-runtime.<리전>.amazonaws.com`)으로 부른다. 이 존이 서울 VPC
# 안에서 그 이름을 엔드포인트 ENI의 사설 IP로 풀어 주므로 코드에 엔드포인트 URL을 심지 않아도 된다.
#
# 존은 VPC 전체에 걸린다 — 퍼블릭 서브넷의 앱 EC2도 이 이름을 사설 IP로 받는다. 그래서 퍼블릭 라우트
# 테이블에도 피어링 라우트가 있어야 하고, 없으면 앱의 Bedrock 호출이 연결 타임아웃으로 죽는다.
resource "aws_route53_zone" "bedrock_runtime" {
  name    = "bedrock-runtime.${data.aws_region.bedrock.name}.amazonaws.com"
  comment = "Resolves the ${data.aws_region.bedrock.name} bedrock-runtime hostname to the peered interface endpoint"

  vpc {
    vpc_id = aws_vpc.this.id
  }
}

resource "aws_route53_record" "bedrock_runtime" {
  zone_id = aws_route53_zone.bedrock_runtime.zone_id
  name    = aws_route53_zone.bedrock_runtime.name
  type    = "A"

  alias {
    name                   = aws_vpc_endpoint.bedrock.dns_entry[0].dns_name
    zone_id                = aws_vpc_endpoint.bedrock.dns_entry[0].hosted_zone_id
    evaluate_target_health = false
  }
}
