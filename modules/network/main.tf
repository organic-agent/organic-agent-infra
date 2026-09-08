resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # VPC 안에서 RDS 엔드포인트 호스트네임이 리졸브되려면 필요

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

resource "aws_subnet" "public" {
  count = length(var.azs)

  vpc_id                  = aws_vpc.this.id
  availability_zone       = var.azs[count.index]
  cidr_block              = var.public_subnet_cidrs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name_prefix}-public-${var.azs[count.index]}"
  }
}

# DB 서브넷은 인터넷 라우트 없음 (IGW/NAT 없음): RDS는 egress가 필요 없음.
resource "aws_subnet" "db" {
  count = length(var.azs)

  vpc_id            = aws_vpc.this.id
  availability_zone = var.azs[count.index]
  cidr_block        = var.db_subnet_cidrs[count.index]

  tags = {
    Name = "${var.name_prefix}-db-${var.azs[count.index]}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.name_prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  # 리소스 속성 대신 변수 기반 count — import/plan 시점에 개수가 확정되도록.
  count = length(var.azs)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- 임베딩 Lambda가 S3를 읽을 통로 ---

data "aws_region" "current" {}

# DB 서브넷에는 지금까지 라우트 테이블이 없었다. RDS는 어디로도 나가지 않아서 VPC 기본
# 라우트 테이블로 충분했다. 게이트웨이 엔드포인트는 리소스가 아니라 *라우트*라, 우리가
# 소유한 테이블이 있어야 넣을 수 있어서 여기서 처음 만든다.
#
# 0.0.0.0/0 항목은 일부러 없다 — 이 서브넷은 여전히 인터넷으로 나가는 길이 없다.
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-db-rt"
  }
}

resource "aws_route_table_association" "db" {
  count = length(var.azs)

  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}

# DB 서브넷 안의 것이 S3에 닿는 유일한 방법.
#
# VPC에 붙은 Lambda는 기본으로 받던 AWS 관리형 인터넷을 잃고 그 서브넷의 라우트만 쓸 수
# 있게 된다. 여기에는 NAT 게이트웨이가 없으므로(의도된 설계 — 위 퍼블릭 서브넷 주석 참고)
# 이게 없으면 임베딩 잡이 사진을 한 장도 못 가져온다.
#
# *게이트웨이* 엔드포인트라 공짜다. 프리픽스 리스트 라우트일 뿐 과금되는 ENI가 아니다
# (SSM·ECR·KMS가 요구하는 인터페이스 엔드포인트와 다르다).
#
# 퍼블릭 라우트 테이블에는 붙이지 않는다. 붙이면 앱 서버의 S3 트래픽이 IGW를 벗어나 조용히
# 경로를 바꾸고, 그걸 필요로 하는 것이 아무것도 없다.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.db.id]

  tags = {
    Name = "${var.name_prefix}-s3"
  }
}

# --- AI Lambda 셋이 AWS API에 닿을 통로 (인터페이스 엔드포인트) ---
#
# S3 게이트웨이 엔드포인트만으로는 부족한 호출이 셋 있다. embedder·score의 자기 재호출과
# score → categorize 체인은 Lambda API(`lambda.<region>.amazonaws.com`)로, categorize의 그룹
# 이름 짓기는 Bedrock(`bedrock-runtime.<region>.amazonaws.com`)으로 나간다. 둘 다 게이트웨이
# 엔드포인트가 없는 서비스라 인터페이스 엔드포인트(= ENI)가 필요하고, 없으면 15분짜리
# 함수가 남은 시간을 연결 타임아웃에 쓰고 재호출·체인만 실패한 채 끝난다.
#
# 인터페이스 엔드포인트는 게이트웨이와 달리 **시간당 과금**이다(ENI 하나에 약 $0.0147/h,
# 서브넷 = AZ마다 하나). 두 AZ에 다 두면 엔드포인트 둘 × ENI 둘 ≈ 월 $43, 한 AZ면 절반.
# Lambda ENI는 두 DB 서브넷 어디에나 생기지만 엔드포인트는 기본 한 AZ([0])만 둔다(#57) — 다른 AZ의
# 함수는 AZ를 건너 붙어 동작하고, 그 AZ가 죽으면 같이 죽는다. 앱 EC2·RDS도 단일 AZ라 같은 수준이다.
# 두 AZ로 늘리려면 `interface_endpoint_subnet_indexes = [0, 1]`.
#
# private_dns_enabled: 함수 코드는 기본 퍼블릭 호스트네임(boto3 기본값)으로 부른다. 이 옵션이
# 그 이름을 VPC 안에서 ENI 주소로 풀어 주므로 코드에 엔드포인트 URL을 심을 필요가 없다.

# 엔드포인트 ENI에 붙는 보안 그룹. 이 VPC 안에서만 443으로 들어온다 — 엔드포인트는 VPC 밖에서
# 닿을 수 없으므로 출처를 Lambda SG로 더 좁혀 얻는 것이 없고, security 모듈이 network 모듈에
# 의존하는 구조라 여기서 Lambda SG를 참조하면 순환이 된다.
resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "${var.name_prefix}-vpce-"
  description = "Interface VPC endpoints: HTTPS from inside the VPC"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-vpce"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_https" {
  security_group_id = aws_security_group.vpc_endpoints.id
  description       = "HTTPS from the VPC (Lambda ENIs in the DB subnets)"
  cidr_ipv4         = aws_vpc.this.cidr_block
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

locals {
  interface_endpoint_subnet_ids = [for i in var.interface_endpoint_subnet_indexes : aws_subnet.db[i].id]
}

# lambda 인터페이스 엔드포인트는 없다. Lambda가 Lambda를 부르던 경로(embedder 재호출·score 샤드 팬아웃·
# score → categorize 체인)는 파이프라인 v2에서 wes가 가져갔다(#57). 다시 필요해지면 bedrock_runtime과 같은 모양으로 만든다.

# categorize의 그룹 이름 짓기(Bedrock InvokeModel). `global.` 크로스 리전 프로필도 이 리전의
# bedrock-runtime으로 들어가고, 다른 리전으로 넘기는 것은 Bedrock 안쪽 일이다.
resource "aws_vpc_endpoint" "bedrock_runtime" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.bedrock-runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.interface_endpoint_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.name_prefix}-bedrock-runtime"
  }
}
