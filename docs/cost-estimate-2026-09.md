# 월 비용 추정 (2026-09-10 기준)

모니터링 서버(`wes-monitoring`)와 테스트 웹(`wes-frontend-test`)을 **제외**한 서비스 고정비 추정.
실제 청구액은 Cost Explorer·Pricing API가 조직 SCP로 막혀 있어 조회하지 못했다.
아래는 2026-09-10에 AWS CLI로 확인한 **실제 떠 있는 자원**에 서울 리전(ap-northeast-2) 온디맨드 공시 단가를 곱한 값이다.
런북(`docs/runbook.md` "비용" 절)의 "$55-60"은 관리자 EC2·GPU 워커·Bedrock 엔드포인트·ECR·퍼블릭 IPv4 과금이 붙기 전 숫자라 지금은 맞지 않는다.

## 고정비 — 월 약 $105 (약 14~15만 원)

| 항목 | 내역 | 월 추정 |
|---|---|---|
| ALB `wes` | 시간당 $0.0225 + 최소 LCU | $17.5 |
| ALB 퍼블릭 IPv4 2개 | AZ당 1개 × $0.005/h | $7.3 |
| RDS `wes-db` | db.t4g.micro $19 + gp3 20GB $2.6 (Single-AZ, 백업 0일) | $21.6 |
| 앱 EC2 `wes-app` | t4g.micro $7.6 + gp3 20GB $1.8 + 퍼블릭 IP $3.65 | $13.1 |
| 관리자 EC2 `wes-admin` | t4g.small $15.2 + gp3 20GB $1.8 + 퍼블릭 IP $3.65 | $20.7 |
| GPU 워커 2대 (정지 상태) | gp3 30GB × 2 $5.5 + AMI 스냅샷 30GB ≈ $1.5. 정지 중엔 퍼블릭 IP 없음 | $7 |
| `bedrock-runtime` 인터페이스 엔드포인트 | ENI 1개(한 AZ) × $0.0147/h. 두 AZ면 $21 | $10.7 |
| ECR | 약 53GB(score 44GB, embedder 6.7GB, categorize 1.8GB) × $0.10 | $3~5 |
| S3 | wes-photos 16GB + wes-dev-photos 11.5GB + tf-state 0.2GB × $0.025 | $0.7 |
| Route53 존 | easyselect.kr | $0.5 |
| CloudWatch 알람·로그 | 알람 10개 이내 무료, Lambda 로그 14일 보관 | $0~1 |
| **합계** | | **약 $103~107** |

제외한 두 항목(참고): 모니터링 약 $13 (t4g.micro + gp3 20GB + EIP), 테스트 웹 약 $21 (t4g.small + gp3 20GB + EIP + 아티팩트 버킷).

## 변동비 — 사용량에 비례

| 항목 | 단가 | 비고 |
|---|---|---|
| GPU 워커 가동 | g6.xlarge 대당 약 $0.99/h | 2대 × 월 10시간 ≈ $20. 자기 정지(30초 유휴)·wes 강제 정지·CloudWatch 알람이 모두 실패해 상시 running이면 월 $1,424 |
| Lambda 3개 | embedder 3GB · score 8GB(폴백) · categorize 3GB × 실행 시간 | 호출량 비례. GPU 풀이 켜져 있어 score Lambda는 폴백만 |
| Bedrock | Claude Sonnet 4.6 (`global.anthropic.claude-sonnet-4-6`) 토큰 과금 | categorize 그룹 이름 짓기(갤러리당 몇 번) + 앱의 추천 이유·비교샷 판정 |
| 데이터 전송 아웃 | GB당 $0.126, 월 100GB 무료 | ALB 응답 + S3 원본/미리보기 다운로드 |
| AMI 빌드 | Image Builder 실행 시 g6.xlarge 1시간 안팎 | 회당 $1 정도, 수동 실행 때만 |

## 줄일 수 있는 곳

- **ECR `wes-score` 이미지 19개, 44GB.** 라이프사이클 규칙은 `gpu-<sha>` 접두사 3개 유지 + untagged 3일이라 그 밖의 태그(`latest`, `gpu` 등 이동 태그와 다른 접두사)는 안 걸린다. 안 쓰는 태그를 지우면 $3 정도. 레이어 공유분이 있어 실제 과금은 합산치보다 적을 수 있다.
- **`wes-dev-photos` 11.5GB.** 로컬 개발용 버킷이라 오래된 사진을 비우면 소액이지만 계속 커지는 것을 막는다.
- **테스트하지 않는 기간엔 앱 스택 destroy** (런북 방침). 호스팅 존은 dns 스택 소유라 남는다.

## 계산에 쓴 단가 (서울, 온디맨드, USD)

| 자원 | 단가 |
|---|---|
| t4g.micro / t4g.small / g6.xlarge | $0.0104/h / $0.0208/h / ≈$0.99/h |
| EBS gp3 | $0.0912/GB-월 |
| EBS 스냅샷 | $0.05/GB-월 |
| RDS db.t4g.micro PostgreSQL Single-AZ | $0.026/h |
| RDS gp3 스토리지 | $0.131/GB-월 |
| ALB | $0.0225/h + LCU $0.008/h |
| 퍼블릭 IPv4 (EIP·자동 할당·ALB 모두) | $0.005/h ≈ $3.65/월 |
| 인터페이스 VPC 엔드포인트 | ENI당 $0.0147/h |
| ECR | $0.10/GB-월 |
| S3 Standard | $0.025/GB-월 |
| Route53 호스티드 존 | $0.50/월 |

월 730시간 기준. 단가는 공시값 기억에 의존했으므로 청구서와 ±10% 정도 차이가 날 수 있다.

## 확인에 쓴 명령

```bash
R=ap-northeast-2
aws ec2 describe-instances --region $R --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceType,State.Name]' --output text
aws ec2 describe-volumes --region $R --query 'Volumes[].[Size,VolumeType,State]' --output text
aws ec2 describe-addresses --region $R --query 'Addresses[].[PublicIp,InstanceId]' --output text
aws rds describe-db-instances --region $R --query 'DBInstances[].[DBInstanceClass,AllocatedStorage,MultiAZ]' --output text
aws elbv2 describe-load-balancers --region $R --query 'LoadBalancers[].[LoadBalancerName,Type]' --output text
aws ec2 describe-vpc-endpoints --region $R --query 'VpcEndpoints[].[ServiceName,VpcEndpointType,length(SubnetIds)]' --output text
aws ec2 describe-snapshots --region $R --owner-ids self --query 'Snapshots[].[VolumeSize]' --output text
# S3 크기: CloudWatch AWS/S3 BucketSizeBytes, ECR 크기: describe-images imageSizeInBytes 합
```
