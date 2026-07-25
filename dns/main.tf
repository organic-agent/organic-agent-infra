# 공유 호스티드 존. 앱 환경을 destroy 해도 존이 같이 지워지지 않도록
# 앱 환경과 일부러 분리해둠 (Route53은 존을 다시 만들 때마다 새 NS 서버를
# 할당해서, 존이 지워지면 등록기관에서 재위임을 해야 함).
# 앱 환경들은 data source로 존을 이름으로 조회해서 씀.
resource "aws_route53_zone" "this" {
  name = var.zone_name
}
