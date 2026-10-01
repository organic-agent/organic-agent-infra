output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "퍼블릭 서브넷 ID 목록 (ALB + EC2)"
  value       = aws_subnet.public[*].id
}

output "db_subnet_ids" {
  description = "데이터베이스 서브넷 ID 목록 (RDS 서브넷 그룹 + 임베딩 Lambda의 ENI)"
  value       = aws_subnet.db[*].id

  # Lambda의 ENI가 이 서브넷에 생기는데, 게이트웨이 엔드포인트의 라우트가 생기기 전에는
  # S3에 닿지 못하고, 피어링 라우트와 호스티드 존 레코드가 없으면 Bedrock에 닿지 못한다.
  # 이 출력을 쓰는 쪽이 그 순서를 기다리게 한다.
  depends_on = [
    aws_vpc_endpoint.s3,
    aws_route_table_association.db,
    aws_route.db_to_bedrock,
    aws_route.bedrock_to_main,
    aws_route_table_association.bedrock,
    aws_vpc_security_group_ingress_rule.bedrock_endpoint_https,
    aws_route53_record.bedrock_runtime,
  ]
}

output "bedrock_runtime_endpoint_id" {
  description = "Bedrock 리전 VPC의 bedrock-runtime 인터페이스 엔드포인트 ID (categorize의 그룹 이름 짓기, 앱의 추천 이유)"
  value       = aws_vpc_endpoint.bedrock.id
}

output "bedrock_peering_connection_id" {
  description = "서울 VPC ↔ Bedrock 리전 VPC 피어링 연결 ID"
  value       = aws_vpc_peering_connection.bedrock.id
}
