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
