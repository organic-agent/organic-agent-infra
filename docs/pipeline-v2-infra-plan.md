# 분석 파이프라인 v2 — 인프라 작업 계획

상위 계획(분석 파이프라인 v2 개발 계획, 2026-09-07)의 **infra 항목 I1~I7**과 그에 딸린 권한 변경(W6·I4)을 이 저장소의 현재 코드와
대조해, **지울 것 · 바꿀 것 · 새로 만들 것**을 파일 단위로 적는다. 다른 세 저장소(wes · test-web · organic-agent-ai)의 작업은
다루지 않고, 인프라가 그쪽에 요구하는 계약만 §8에 모은다. AI 쪽 검토(2026-09-08)를 거쳐 확정한 판이다(§10 검토 이력).

---

## # 0. 지금 상태 (2026-09-07 조회)

| 항목 | 값 | 출처 |
|---|---|---|
| RDS | `wes-db` · db.t4g.micro · PostgreSQL 16.14. 실측 CPU 최대 14%, 크레딧 288 만땅, 벡터 인덱스 없음 | `aws rds describe-db-instances`, AI 검토 |
| EC2 G/VT 온디맨드 쿼터 | vCPU 8 (g6.xlarge 4 vCPU → 동시 실행 2대가 상한) | `service-quotas L-DB2E81BA` |
| Lambda 계정 동시성 | 400 (미예약 334 = 400 − embedder 32 − score 32 − categorize 2) | `lambda get-account-settings` |
| GPU 인스턴스·자체 AMI·여분 SG·볼륨·스냅샷 | 없음 (벤치마크 인스턴스는 모두 정리됨) | `ec2 describe-*` |
| 벤치마크 IAM 잔존물 | 롤 `wes-gpu-benchmark`(+ 인스턴스 프로파일, 인라인 `benchmark`, SSM Core 부착) · 롤 `wes-sagemaker-benchmark`(인라인 `benchmark`) | `iam list-roles` |
| SageMaker | 엔드포인트·모델 없음. 운영에서 쓰지 않는다 | `sagemaker list-*`, AI 검토 |
| ECR `wes-score` | 태그 `gpu`(4.19GB, AI 저장소 main #70 빌드) · `latest`(1.66GB) · untagged 9개 | `ecr describe-images` |
| Image Builder 서비스 연결 역할 | `AWSServiceRoleForImageBuilder` 없음 | `iam get-role` |
| CloudWatch Events 서비스 연결 역할 | `AWSServiceRoleForCloudWatchEvents` 없음. 계정에 액션이 붙은 CloudWatch 알람도 0개 | `iam get-role`, `cloudwatch describe-alarms` (09-08) |
| SSM `/wes/prod/photoselect.db.password` | SecureString, 키 `alias/aws/ssm`(기본 키) | `ssm describe-parameters` |

이 저장소에는 벤치마크 관련 Terraform 코드가 없다. IAM 잔존물은 전부 콘솔/CLI로 만든 것이라 I7은 코드 삭제가 아니라 **수동 삭제**다.

---

## # 1. 확정한 설계

| # | 결정 | 근거 |
|---|---|---|
| A | GPU 인스턴스 **2대**(2a·2c 각 1대), **g6.xlarge**, **퍼블릭 서브넷 + 공인 IP**, 인바운드 0, IMDSv2 강제, 접속은 SSM만. 인터페이스 엔드포인트·NAT는 비용으로 제외 | 상위 I2. 프라이빗 서브넷은 ECR·SSM 엔드포인트 월 $15~20 또는 NAT $43 |
| B | AMI는 **드라이버·Docker·toolkit·워커 systemd 유닛만**. 코드 이미지는 AMI에 굽지 않고 부팅 시 ECR `wes-score:gpu`(이동 태그) pull. AI 쪽 CI가 `gpu`와 `gpu-<sha>`를 함께 push. 지금 ECR의 `gpu` 태그를 그대로 시작점으로 쓴다 | 코드 갱신과 드라이버 갱신의 주기가 다르다(§4.3). 이동 태그가 없으면 워커가 돌릴 태그를 가리키는 포인터가 하나 더 필요하다 |
| C | 앱 인스턴스 롤에 `ec2:DescribeInstances` + `ec2:StartInstances`·**`ec2:StopInstances`**(태그 `Name=wes-score-gpu` 조건). 상위 I4의 Start·Describe에 Stop을 더한다 | W6 안전장치(running인데 30분 잡 없음 → 강제 정지)에 필요 |
| D | **RDS small·embedder 예약 동시성 64는 Phase 0에서 뺀다.** Phase 5 부하 테스트 뒤 함께 결정 | micro 실측(§0)으로 당장 필요 없고, GPU score 뒤 커넥션은 24+32+2+1 = 59 < 79. 둘은 한 묶음(24+64+3 = 91 > 79)이다 |
| E | Phase 0은 역할별 **`CONNECTION LIMIT`**(embedder 32 · photoselect 8 · 앱 40)만. `ALTER ROLE`이라 무중단 | 분석이 앱 사용자 커넥션을 못 뺏게 하는 것이 목적이고, 이건 클래스와 무관하다 |
| F | 벤치마크 롤 두 개 **수동 삭제** | I7. SageMaker 미사용 확정 |
| G | **G 쿼터 12를 지금 신청.** 인스턴스는 2대 유지, 비용 변화 없음 | AMI 빌드(g6.xlarge 4 vCPU)와 풀 2대(8 vCPU)가 겹치면 쿼터 초과로 빌드가 실패한다. "풀 정지 상태에서만 빌드"는 사람이 지켜야 하는 규칙이라 깨지기 쉽다. 쿼터는 무료이고 3대째의 선행 조건도 미리 채워진다 |
| H | Image Builder 서비스 연결 역할은 **`aws_iam_service_linked_role`로 코드 관리**, `tf_apply`에 권한 문장을 로컬 apply 1회로 넣는다 | 저장소 규칙 "IAM은 코드로, `modules/github-actions` 변경만 로컬 apply". 수동 생성은 deploy-order에 수동 단계가 늘고 destroy 뒤 재배포 때 빠뜨리기 쉽다 |
| I | AMI 도구는 **EC2 Image Builder**(Terraform 안) | Packer는 GitHub Actions에 EC2 RunInstances 권한을 가진 OIDC 롤이 하나 더 필요하다. "CI는 plan/apply만"을 유지한다 |
| J | 비밀 아닌 설정(DB_HOST·S3_BUCKET)은 **`/wes/prod/` 파라미터 세 개**에서 워커 env 스크립트가 읽는다. 프리픽스 전체는 열지 않는다 | 앱이 이미 쓰는 경로라 값이 어긋나지 않는다. JWT·OAuth 시크릿이 같은 프리픽스에 있어 와일드카드는 금지 |
| K | embedder 롤의 `ReinvokeSelf` 제거는 **보류** | 갤러리 경로(재호출)가 embedder에도 폴백으로 남을 수 있다. E1 배포 뒤 AI 쪽과 재확인 |
| L | GPU 인스턴스 끄기의 **최후 안전장치는 인프라 소유**: 인스턴스별 CloudWatch 알람(CPU 30분 < 5%)의 EC2 정지 액션. 대상은 알람 dimension `InstanceId`로 GPU 2대에만 박힌다(§4.5) | 워커 자기 정지(S1)와 wes 강제 정지(W6)는 둘 다 코드다. 둘이 없거나 고장 나면(W6 배포 전 테스트 기간, 워커 크래시 루프, wes 장애) 2대 상시 running 월 $1,424가 인프라 비용으로 남는다. 알람은 코드 없이 동작하고 월 $0.20 |

---

## # 2. 지울 것 · 바꿀 것 · 새로 만들 것

### 2.1 지울 것

| 대상 | 무엇을 | 언제 | 왜 |
|---|---|---|---|
| AWS(수동) | 롤 `wes-gpu-benchmark` + 인스턴스 프로파일 `wes-gpu-benchmark` + 인라인 정책 `benchmark` + `AmazonSSMManagedInstanceCore` 부착 해제 | Phase 0 | I7 |
| AWS(수동) | 롤 `wes-sagemaker-benchmark` + 인라인 정책 `benchmark` | Phase 0 | I7 |
| `modules/analysis/variables.tf` · 루트 `variables.tf` | `embedder_reserved_concurrent_executions`·`score_reserved_concurrent_executions` description의 "샤드 상한 MAX_SHARDS=32 · advisory lock stride 64 · micro 79 커넥션" 근거 문장 | Phase 3(score가 GPU로 감) · Phase 5 뒤(RDS 결정) | 값(32)은 그대로 두고 근거만 다시 쓴다. embedder 검증 `<= 64`는 advisory lock stride가 코드에서 사라진 뒤 풀 수 있다 |
| `modules/analysis/main.tf` 머리말 · `docs/runbook.md` "AI 파이프라인" · `README.md` 아키텍처 bullet | "갤러리 단위로 한 번 부른다 / 샤드 / 15분 앞에서 자기 재호출"을 **기본 흐름**으로 적은 서술과 흐름도 | Phase 3·5 | v2 흐름(스위퍼 배치 → embedder, GPU 워커 풀, Lambda 폴백)으로 교체. 폴백 경로 설명은 남긴다 |

지우지 **않는** 것과 이유:

- **score Lambda 전체**(함수·ECR·롤·10GB /tmp·동시성 32): 폴백 경로. GPU 풀이 전부 바쁘거나 `InsufficientInstanceCapacity`일 때 wes가 그대로 부른다.
- **`lambda`·`bedrock-runtime` 인터페이스 엔드포인트**: score 폴백의 자기 재호출·categorize 체인, categorize의 Bedrock 호출이 여전히 DB 서브넷에서 나간다.
- **embedder 롤 `ReinvokeSelf`**: 결정 K. `tests/analysis_lambdas_static_test.sh`의 존재 검사도 그대로.
- **RDS db.t4g.micro**: 결정 D. `instance_class` 변수는 그대로.
- **S3 ObjectCreated 트리거를 쓰지 않는다는 주석**: 상위 D4가 같은 결론이다.
- **`iam_database_authentication_enabled`와 `rds-db:connect` 문장**: SCP 우회 상태 그대로. GPU 워커도 같은 이유로 비밀번호를 쓴다.

### 2.2 바꿀 것

| 파일 | 변경 | Phase |
|---|---|---|
| `modules/analysis/main.tf` | ECR 라이프사이클에 `gpu-` 태그 접두사 규칙 추가(최근 3개만 유지). `gpu-<sha>` 불변 태그는 4.2GB짜리가 커밋마다 쌓인다 | 3 |
| `modules/security/main.tf` | GPU 워커 SG(인바운드 0, 이그레스 전부) + RDS SG에 `rds_from_score_gpu`(5432). GPU SG는 신규 모듈이 아니라 **security 모듈**에 만든다(RDS 규칙이 SG를 참조하므로 같은 모듈이 자연스럽다) | 3 |
| `modules/compute/main.tf` | 앱 인스턴스 롤에 결정 C의 EC2 제어 정책 | 3 |
| `modules/github-actions/main.tf` | `tf_apply_iam`에 서비스 연결 역할 문장(`iam:CreateServiceLinkedRole`·`DeleteServiceLinkedRole`·`GetServiceLinkedRoleDeletionStatus`). 리소스는 두 ARN 한정 — `role/aws-service-role/imagebuilder.amazonaws.com/AWSServiceRoleForImageBuilder`, `role/aws-service-role/events.amazonaws.com/AWSServiceRoleForCloudWatchEvents`. **로컬 apply** | 3 |
| `main.tf` | `module "score_gpu"` 호출, `module "security"`에 GPU 관련 입력 | 3 |
| `outputs.tf` | GPU 인스턴스 ID 맵, AMI 파이프라인 ARN, 현재 `gpu_ami_id` | 3 |
| `docs/deploy-order.md` | [7] DB 사용자 SQL에 `CONNECTION LIMIT`(Phase 0) · [3]에 "GPU AMI 파이프라인 1회 실행 → AMI ID를 `gpu_ami_id`로"(Phase 3) | 0·3 |
| `docs/runbook.md` | DB 사용자 절에 `ALTER ROLE … CONNECTION LIMIT`, 벤치마크 IAM 정리 기록(0) · AI 파이프라인 절 재작성, 비용 절에 GPU 풀 고정비·유휴 비용, "GPU 워커 점검" 절(SSM 접속, journald, 강제 정지)(3·5) | 0·3·5 |
| `README.md` · `docs/wes-infrastructure-architecture.drawio/.png` | AI 분석 bullet과 그림에 GPU 워커 풀·스위퍼 | 5 |

**Phase 5 부하 테스트 뒤 결정**(결정 D — 코드는 준비돼 있어 변수 기본값만 바꾼다):

| 파일 | 변경 | 조건 |
|---|---|---|
| `modules/database/variables.tf` | `instance_class` `db.t4g.micro` → `db.t4g.small` | 5팀 동시에서 커넥션 또는 CPU 크레딧이 실제로 바닥날 때. `apply_immediately = true`라 재기동 수 분 |
| `modules/analysis/variables.tf` · 루트 `variables.tf` | `embedder_reserved_concurrent_executions` 32 → 64 | RDS small과 한 묶음. Lambda 계정 여유는 400 − 64 − 32 − 2 = 302로 충분 |

### 2.3 새로 만들 것

| 경로 | 내용 | Phase |
|---|---|---|
| `modules/score-gpu/` | GPU 워커 풀 모듈(§4) — Image Builder 파이프라인 + 서비스 연결 역할 둘, 워커 롤·프로파일, 인스턴스 2대(생성 직후 정지), 인스턴스별 유휴 정지 알람 | 3 |
| `modules/score-gpu/components/` | Image Builder 컴포넌트 YAML(드라이버·Docker·toolkit·systemd 유닛·env 스크립트 설치·nvidia-smi 검증). 유닛·스크립트 본문은 AI 쪽이 S1 머지 때 전달 | 3 |
| `tests/score_gpu_static_test.sh` | §7 회귀 검사 | 3 |
| `docs/pipeline-v2-phase{0,3,5}.md` | 각 Phase 실측(상위 문서 §4 요구) | 각 Phase 끝 |

---

## # 3. PR 순서

한 PR = 한 plan 댓글 = 한 승인. 교체·삭제·권한 변경은 PR 본문에 명시한다(AGENTS.md).

```
PR-0a  docs: DB 역할 CONNECTION LIMIT 런북 · 벤치마크 IAM 정리 기록      ← Phase 0. Terraform 변경 없음. 수동 삭제(I7)·G 쿼터 12 신청을 같은 날
PR-3a  feat: tf_apply 에 서비스 연결 역할 권한(Image Builder·CloudWatch Events)  ← Phase 3 선행. modules/github-actions 변경이라 로컬 apply
PR-3b  feat: score GPU AMI 파이프라인(Image Builder) + 서비스 연결 역할  ← 머지·CI apply 후 파이프라인 1회 실행 → AMI ID 확보
PR-3c  feat: score GPU 워커 풀 2대 · SG · 롤 · 유휴 정지 알람 · 앱 롤 EC2 제어 권한  ← Phase 3 본체. gpu_ami_id 에 3b 결과를 박음
PR-3d  docs: 런북 AI 파이프라인 절 재작성 · 변수 description 근거 갱신   ← 3c 와 합쳐도 된다
PR-5   docs: 아키텍처 그림 · README · 실측 기록 · RDS/embedder 64 결정    ← Phase 5
(보류) refactor: embedder 자기 재호출 권한 제거                         ← 결정 K. AI 쪽이 "폴백으로 남지 않는다"고 답한 뒤에만
```

- PR-0a는 **바로** 가능하고 코드 변경이 없다.
- PR-3a를 따로 두는 이유: 권한이 먼저 들어가야 3b의 CI apply가 서비스 연결 역할을 만들 수 있고, 이 모듈은 규칙상 로컬 apply다.
- PR-3b와 3c를 나누는 이유: 인스턴스 리소스가 AMI ID를 요구하는데 파이프라인이 처음 돌기 전에는 AMI가 없다. 3b 머지·apply → 파이프라인 실행(15분 안팎) → AMI ID를 3c 변수 기본값에 넣는다.
- 3b의 파이프라인 실행은 G 쿼터 12 승인(PR-0a 때 신청, 1~2일) 뒤가 안전하다. 승인 전이라면 풀이 아직 없으니 충돌은 없다.
- `ReinvokeSelf`를 지우기로 정해지더라도 **AI 저장소 코드 배포가 먼저**다. 권한을 먼저 지우면 embedder 재호출이 AccessDenied로 조용히 끊긴다(`reinvoked=false`).

---

## # 4. `modules/score-gpu` 설계

### 4.1 리소스

```
data  aws_caller_identity · aws_region

# --- AMI 파이프라인 (I1) ---
aws_iam_service_linked_role               "imagebuilder"     aws_service_name = imagebuilder.amazonaws.com (계정에 없음, §0). infrastructure_configuration 이 depends_on 으로 기다린다
aws_imagebuilder_component                "nvidia_docker"    AL2023 + nvidia-release 드라이버(버전 고정, 컨테이너 CUDA 12.1 하한 525) + docker + nvidia-container-toolkit
                                                             + systemd 유닛·env 스크립트 설치(AI 쪽 전달본) + nvidia-smi 검증. 코드 이미지 pull 은 하지 않는다(결정 B)
aws_imagebuilder_image_recipe             "this"             parent = AL2023 x86_64 최신(SSM 퍼블릭 파라미터), 루트 gp3 30GB(처리량 기본 125MB/s)
aws_iam_role / aws_iam_instance_profile   "builder"          EC2InstanceProfileForImageBuilder + AmazonSSMManagedInstanceCore
aws_imagebuilder_infrastructure_configuration "this"         g6.xlarge(nvidia-smi 검증에 GPU 필요), 퍼블릭 서브넷, 인바운드 없는 SG, terminate_instance_on_failure = true
aws_imagebuilder_distribution_configuration   "this"         이름 `wes-score-gpu-{{ imagebuilder:buildDate }}`, 태그 Name=wes-score-gpu-ami
aws_imagebuilder_image_pipeline           "this"             schedule 없음 — 수동 실행(드라이버·베이스 갱신 때만)

# --- 워커 풀 (I2·I3) ---
aws_iam_role / aws_iam_instance_profile   "worker"           §4.2 정책
aws_instance                              "this"  for_each = { "ap-northeast-2a" = subnet_a, "ap-northeast-2c" = subnet_c }
    ami = var.gpu_ami_id                     # 변수로 고정. most_recent 데이터 소스는 파이프라인이 돌 때마다 replace 를 만든다
    instance_type = "g6.xlarge", associate_public_ip_address = true, key_name 없음(SSM 만)
    metadata_options { http_tokens = "required", http_put_response_hop_limit = 2 }   # 컨테이너에서 롤 자격증명·자기 인스턴스 ID
    root_block_device { gp3, 30, throughput = var.gpu_root_throughput (기본 125, 필요 시 250) }
    tags = { Name = "wes-score-gpu", Role = "score-gpu-worker" }
    user_data 없음 — 유닛은 AMI 에 있다
aws_ec2_instance_state                    "stopped" for_each 같은 키, state = "stopped", lifecycle { ignore_changes = [state] }
    # 생성 직후 한 번 정지시키고, 그 뒤 start/stop 은 wes(W6)와 워커 자기 정지(S1)가 소유한다.
    # 이게 없으면 첫 apply 뒤 유휴 10분 × $0.99 × 2대를 그냥 쓴다

# --- 최후 안전장치 (결정 L, §4.5) ---
aws_iam_service_linked_role               "cloudwatch_events"  aws_service_name = events.amazonaws.com → AWSServiceRoleForCloudWatchEvents (계정에 없음). 알람의 EC2 액션이 이 역할로 정지시킨다
aws_cloudwatch_metric_alarm               "idle_stop" for_each 같은 키
    namespace = "AWS/EC2", metric_name = "CPUUtilization", statistic = "Average"
    period = 300, evaluation_periods = 6, datapoints_to_alarm = 6, threshold = 5, comparison_operator = "LessThanThreshold"
    dimensions = { InstanceId = aws_instance.this[each.key].id }        # ← 인스턴스 ID 로만 대상 지정. 태그·ASG 아님
    treat_missing_data = "notBreaching"                                   # 정지 중엔 지표가 없다 — 헛방 금지
    alarm_actions = ["arn:aws:automate:${region}:ec2:stop"]
    depends_on = [aws_iam_service_linked_role.cloudwatch_events]
```

`aws_instance`는 wes가 start/stop 해도 drift가 나지 않는다(`instance_state`는 읽기 전용 속성). AMI를 바꾸면 replace이고 워커는 상태가
없으니 안전하다. 정지 중인 인스턴스를 replace 하면 새 인스턴스는 running으로 뜨는데, `aws_ec2_instance_state`가 함께 다시 만들어져 정지시킨다.

### 4.2 워커 인스턴스 롤 정책 (I3)

| sid | actions | resources / condition | 이유 |
|---|---|---|---|
| ReadPreviews | `s3:GetObject` | `${photo_bucket_arn}/previews/*` | score Lambda와 같은 범위. 원본은 볼 이유 없음 |
| PullScoreImage | `ecr:GetAuthorizationToken`(`*`) · `ecr:BatchGetImage`·`ecr:GetDownloadUrlForLayer`·`ecr:BatchCheckLayerAvailability`(`wes-score` 리포지토리 ARN) | 부팅 시 `docker pull …:gpu` |
| ReadRuntimeParameters | `ssm:GetParameter` | `/wes/prod/photoselect.db.password` · `/wes/prod/spring.datasource.url` · `/wes/prod/app.storage.bucket` 세 ARN | 결정 J. 와일드카드 없음 |
| DecryptViaSsm | `kms:Decrypt` | `*` + `kms:ViaService = ssm.ap-northeast-2.amazonaws.com` | 파라미터가 기본 `alias/aws/ssm` 키라 엄밀히는 불필요하지만, 고객 관리형 키로 바꿔도 깨지지 않게 `tf_plan_extra`와 같은 모양으로 둔다 |
| StopSelf | `ec2:StopInstances` | `arn:…:instance/*` + `ec2:ResourceTag/Name = wes-score-gpu` | 유휴 10분 자기 정지. IAM으로 "자기 자신만"은 표현할 수 없어 풀 태그로 좁힌다 |
| (관리형) | `AmazonSSMManagedInstanceCore` | | 접속은 SSM만. SSH 키·인바운드 없음 |

벤치마크 롤에 있던 `lambda:GetFunctionConfiguration`은 넣지 않는다(벤치마크용).

**GPU SG**(security 모듈): 인바운드 0, 이그레스 전부(S3·ECR·SSM은 IGW 경유, RDS는 VPC 내부). RDS SG에 `rds_from_score_gpu`(5432).
퍼블릭 라우트 테이블에 S3 게이트웨이 엔드포인트를 붙이지 않는 기존 결정은 유지한다 — 같은 리전 S3↔EC2 전송은 무료라 비용 이유가 없고 앱 서버 경로를 건드리지 않는다.

**로그**: Phase 3에서는 journald + SSM 접속으로 시작한다. Loki로 보내려면 monitoring SG에 GPU SG 소스의 Loki 포트 인그레스 한 줄이 더 필요하다 — Phase 5에서 필요하면 추가.

### 4.3 이미지 태그와 AMI 갱신 주기 (결정 B)

AMI는 콜드 로드 22초를 없애기 위한 드라이버 층이지 코드 배포 수단이 아니다. 두 갱신 축을 분리한다.

| 축 | 언제 | 어떻게 |
|---|---|---|
| **코드**(score 워커) | AI 저장소 push마다 | CI가 `gpu-<sha>`와 이동 태그 `gpu`를 함께 push. systemd `ExecStartPre=docker pull …:gpu` — 레이어가 같으면 수 초, 바뀐 레이어만 내려받는다 |
| **AMI**(드라이버·베이스) | 분기 1회 또는 CUDA 하한 변경 때 | 파이프라인 수동 실행 → `gpu_ami_id` 갱신 PR → 인스턴스 replace |

### 4.4 systemd 유닛 (AMI에 설치, 본문은 AI 쪽 S1 전달본)

```
[Service]
ExecStartPre=/usr/local/bin/wes-score-env.sh          # SSM 세 파라미터 → /run/wes-score.env (tmpfs, 0600). JDBC URL 에서 host·port·db 를 잘라 DB_HOST·DB_PORT·DB_NAME
ExecStartPre=/usr/bin/docker pull <ecr>/wes-score:gpu
ExecStart=/usr/bin/docker run --rm --gpus all --env-file /run/wes-score.env \
          -e DB_USER=photoselect -e DB_SSLMODE=verify-full -e IDLE_STOP_SECONDS=600 \
          <ecr>/wes-score:gpu python -m score worker --gpu
Restart=on-failure
```

DB_HOST·S3_BUCKET을 AMI에 굽지 않는 이유: RDS를 교체할 때 AMI를 다시 굽게 된다. 인스턴스 태그 대신 SSM을 고른 이유는 결정 J.

### 4.5 끄기 책임의 네 층 (결정 L)

| 층 | 무엇이 끄나 | 소유 | 인프라가 하는 것 |
|---|---|---|---|
| 1 | 워커 자기 정지 — 잡이 없으면 10분 뒤 자기 인스턴스 `StopInstances` | AI S1 | 워커 롤 `StopSelf`, 유닛의 `IDLE_STOP_SECONDS=600` |
| 2 | wes 강제 정지 — running인데 30분 이상 잡 없음 | wes W6 | 앱 롤 `StopInstances`·`DescribeInstances` |
| 3 | 생성 직후 정지 상태 | 인프라 | `aws_ec2_instance_state` |
| 4 | **CloudWatch 알람 EC2 정지 액션** — CPU 평균 30분(5분 × 6) < 5% | 인프라 | §4.1 `idle_stop`. 코드가 하나도 없어도, wes가 죽어도 동작 |

**GPU 2대에만 걸린다는 보장** — 세 겹으로 확인했다.

1. 알람의 대상은 dimension `InstanceId`이고, 값은 같은 모듈 안의 `aws_instance.this[each.key].id`다. 태그(`Name=wes-score-gpu`)나 ASG 같은 집합 조건이 아니라 인스턴스 하나를 가리키는 식별자다. 다른 EC2 넷(`wes-app`·`wes-admin`·`wes-monitoring`·테스트 프론트)에는 정지 액션이 붙은 알람이 없고, 이 계정에는 지금 액션이 붙은 알람 자체가 없다(2026-09-08 조회). 특히 `wes-app`(t4g.micro)은 평상시 CPU가 5% 아래라, 태그 기준이나 계정 전체 규칙이었다면 앱 서버가 꺼졌을 것이다 — InstanceId 지정이 필수인 이유다.
2. 정지 액션 ARN `arn:aws:automate:<region>:ec2:stop`은 그 알람의 dimension에 있는 인스턴스에만 작용한다. 알람마다 인스턴스 하나다.
3. 서비스 연결 역할 `AWSServiceRoleForCloudWatchEvents`의 권한 자체는 계정 전체 `ec2:StopInstances`다. 이 힘을 쓰는 건 알람만이고, 알람은 전부 코드라 §7의 정적 검사로 "정지 액션은 `modules/score-gpu` 밖에 없다"를 못 박는다. 인스턴스가 replace 되어 ID가 바뀌면 참조가 따라가므로 낡은 ID를 가리키는 알람이 남지 않는다.

IAM 태그 조건(층 1·2)은 "같은 태그를 단 인스턴스"를 다 허용하지만, 층 4는 인스턴스 ID라 **셋 중 가장 좁다**.

**임계값 보정**: 유휴 워커는 DB를 3초마다 폴링만 해 CPU가 바닥이다. 점수 계산 중에는 JPEG 디코드가 CPU에서 돌아 4 vCPU 중 한 코어만 써도 25%다. 다만 디코드가 GPU(nvjpeg)로 가면 계산 중에도 CPU가 5% 아래로 떨어질 수 있으므로, Phase 3 검증에서 7,189장 실행 중 `CPUUtilization`을 실측해 임계값을 확정한다. 30분 창은 콜드 스타트(드라이버·pull 20초 남짓)나 배치 사이 틈보다 훨씬 길어 정상 작업을 끊을 일은 없다.

---

## # 5. Phase 0 세부 (PR-0a)

Terraform 변경이 없다. 런북 갱신과 수동 작업 셋이다.

1. 런북 DB 사용자 SQL에 역할별 상한(결정 E):
   ```sql
   ALTER ROLE embedder    CONNECTION LIMIT 32;
   ALTER ROLE photoselect CONNECTION LIMIT  8;
   ALTER ROLE wes_admin   CONNECTION LIMIT 40;   -- 앱(마스터). 관리자 API 계정(wes_admin_api)은 wes 팀이 정한다
   ```
   `ALTER ROLE`은 무중단이며 이미 열린 커넥션은 끊지 않는다. 합계 80이 micro `max_connections` 79를 넘는 것은 의도된 상한이다 —
   동시에 다 차는 경우가 없고, 상한의 목적은 한 역할이 다른 역할 몫을 뺏지 못하게 하는 것이다.
2. I7 수동 삭제(결정 F): `wes-gpu-benchmark` 인스턴스 프로파일에서 롤 분리 → 프로파일 삭제 → 인라인 정책 `benchmark` 삭제 →
   `AmazonSSMManagedInstanceCore` 분리 → 롤 삭제. `wes-sagemaker-benchmark`는 인라인 정책 삭제 → 롤 삭제. 실행 전 `iam get-role`의
   `RoleLastUsed`가 벤치마크 날짜(09-07)인지 확인. 삭제 기록은 런북 "AI 파이프라인" 절 끝에 한 줄.
3. **G 쿼터 12 신청**(결정 G): `service-quotas request-service-quota-increase --service-code ec2 --quota-code L-DB2E81BA --desired-value 12`. 승인 1~2일.
4. 다운타임 없음.

---

## # 6. 권한 변화 총표

| 주체 | 추가 | 제거 |
|---|---|---|
| 앱 인스턴스 롤(`wes-ec2-*`) | `ec2:DescribeInstances`(`*`), `ec2:StartInstances`·`ec2:StopInstances`(태그 조건) | — |
| GPU 워커 롤(신규 `wes-score-gpu-*`) | §4.2 | — |
| Image Builder 빌더 롤(신규 `wes-score-gpu-builder-*`) | 관리형 2개 | — |
| Image Builder 서비스 연결 역할 | 신규(코드 관리) | — |
| CloudWatch Events 서비스 연결 역할(`AWSServiceRoleForCloudWatchEvents`) | 신규(코드 관리). 권한은 계정 전체 `ec2:StopInstances`지만 쓰는 주체는 `modules/score-gpu`의 알람 2개뿐(§4.5) | — |
| embedder Lambda 롤 | — | 없음(`ReinvokeSelf` 보류, 결정 K) |
| `tf_apply` | 서비스 연결 역할 생성·삭제·삭제상태 조회(imagebuilder·events SLR ARN 두 개 한정, PR-3a 로컬 apply). `iam:PassRole`의 `PassedToService`에 `imagebuilder.amazonaws.com`이 필요한지는 PR-3b의 첫 plan/apply에서 확인(문서상 인프라 구성은 인스턴스 프로파일 **이름**만 받는다) | — |
| `worker_deploy`(AI CD) | 없음 — `wes-score` `PutImage`가 이미 있어 `gpu` 태그 push에 추가 권한 불필요 | — |
| `tf_plan` | 없음(ReadOnlyAccess에 imagebuilder 읽기 포함) | — |

모두 `wes-*` 접두사라 `tf_apply_iam`의 울타리 안이다.

---

## # 7. 테스트 (`tests/score_gpu_static_test.sh`)

기존 `tests/*.sh` 방식(rg 기반 정적 검사). 항목:

1. GPU 인스턴스 2대가 서로 다른 AZ 키로 `for_each`, `instance_type = "g6.xlarge"`, `http_tokens = "required"`, `key_name` 없음
2. `aws_ec2_instance_state` `state = "stopped"` + `ignore_changes = [state]`
3. GPU SG에 인그레스 규칙 리소스가 0개, RDS SG에 `rds_from_score_gpu` 존재
4. 워커 롤: S3 `previews/*`만, SSM 리소스가 정확히 세 파라미터 ARN이고 `/wes/prod/*` 와일드카드 없음, `lambda:` 액션 없음, `ec2:StopInstances`에 `ec2:ResourceTag/Name` 조건
5. 앱 롤: Start/Stop에 태그 조건, `DescribeInstances`만 `*`
6. `ami = var.gpu_ami_id`(데이터 소스 `most_recent` 금지)
7. ECR 라이프사이클에 `tagPrefixList = ["gpu-"]` 규칙
8. `aws_iam_service_linked_role` `imagebuilder.amazonaws.com`·`events.amazonaws.com` 존재, `tf_apply_iam`의 서비스 연결 역할 문장이 그 두 ARN으로 한정
9. 유휴 정지 알람: `dimensions = { InstanceId = aws_instance.this[each.key].id }`, `treat_missing_data = "notBreaching"`, `evaluation_periods = 6`·`period = 300`. 알람 `for_each`가 인스턴스와 같은 키
10. **`arn:aws:automate:` EC2 액션 ARN이 `modules/score-gpu` 밖 어디에도 없다**(전체 저장소 rg). 다른 모듈의 알람(analysis의 Lambda 비동기 알람)에 `alarm_actions`가 없다
11. 기존 `analysis_lambdas_static_test.sh`가 계속 통과(score Lambda 폴백 경로 불변, embedder `ReinvokeSelf` 유지)

CI는 `terraform fmt -check` · `validate` · `plan` 그대로. Image Builder 리소스는 plan에서 검증되고, 파이프라인 실행 결과(AMI)는 CI 밖이다.

---

## # 8. 다른 저장소에 요구하는 계약

| 저장소 | 계약 | 근거 |
|---|---|---|
| organic-agent-ai (S1) | 워커가 IMDSv2로 자기 인스턴스 ID를 얻어 `StopInstances` 호출. `IDLE_STOP_SECONDS` env. DB 비밀번호는 env(`--env-file`)로 받고 컨테이너는 SSM을 직접 읽지 않는다. systemd 유닛·env 스크립트 본문은 S1 머지 때 전달 → 인프라가 Image Builder 컴포넌트에 넣는다 | §4.2·4.4 |
| organic-agent-ai (S1 env 스크립트) | 비밀번호 외에 `/wes/prod/spring.datasource.url`·`app.storage.bucket`도 읽어 DB_HOST·DB_PORT·DB_NAME·S3_BUCKET을 만든다. 인스턴스 롤은 이 세 파라미터만 허용한다 | 결정 J |
| organic-agent-ai (X1) | `wes-score` 리포지토리에 `gpu-<sha>`와 이동 태그 `gpu` 둘 다 push | 결정 B |
| organic-agent-ai (S3) | score Lambda는 갤러리 샤딩·자기 재호출·체인을 유지(폴백) | §2.1 |
| organic-agent-ai (E1) | E1 배포 뒤 embedder의 갤러리 경로(자기 재호출)가 폴백으로 남는지 알려 준다. 남으면 `ReinvokeSelf` 유지 | 결정 K |
| wes (W6) | 인스턴스 탐색은 태그 `Name=wes-score-gpu` + `DescribeInstances`. Start 실패(`InsufficientInstanceCapacity`·`IncorrectInstanceState`)는 Lambda 폴백. 30분 유휴 강제 Stop. **인스턴스 0대도 정상 경로**(§9 롤백 조건) | 결정 C |
| wes (W10) | DB 역할 `CONNECTION LIMIT` — embedder 32 · photoselect 8 · 앱 40. 관리자 API 계정 상한은 wes 팀 | 결정 E |

---

## # 9. 롤백

| PR | 되돌리기 |
|---|---|
| 0a | `ALTER ROLE … CONNECTION LIMIT -1`. 무중단. 벤치마크 롤 삭제는 되돌릴 일이 없다(운영 미사용) |
| 3a | 권한 문장 제거 후 로컬 apply. 3b가 이미 적용됐다면 서비스 연결 역할 삭제 권한도 함께 사라지므로 3b를 먼저 되돌린다 |
| 3b | 모듈 제거 → 파이프라인·레시피·컴포넌트·서비스 연결 역할 둘 삭제. 만들어진 AMI·스냅샷은 Terraform 밖(배포 구성이 만든 것)이라 수동 `deregister-image` + `delete-snapshot` |
| 3c | 모듈 제거 → 인스턴스 2대·롤·SG·알람 삭제(알람은 인스턴스와 같은 모듈이라 함께 사라지고, 다른 인스턴스에 영향 없음). wes 쪽 W6이 태그로 인스턴스를 찾다가 0대를 보면 Lambda 폴백으로 흐르므로 앱 코드 변경 없이 되돌아간다 — **wes가 "인스턴스 0대"를 정상 경로로 다루는지가 3c 머지 조건** |

---

## # 10. 남은 것과 검토 이력

남은 것:

1. GPU 워커 로그의 Loki 전송(§4.2 로그) — Phase 3 제외, Phase 5에서 판단.
2. 3대째 조건 — 상위 문서대로 Lambda 폴백 하루 수 회를 신호로. 쿼터 12는 결정 G로 미리 채워진다.
3. `ReinvokeSelf` 제거 여부 — E1 배포 뒤 AI 쪽 답(결정 K).
4. RDS small·embedder 64 — Phase 5 부하 테스트 뒤(결정 D).

검토 이력:

- 2026-09-07 초안. RDS small·embedder 64를 Phase 0에 두고, `ReinvokeSelf` 제거를 Phase 2 PR로 잡았다.
- 2026-09-08 AI 쪽 검토. RDS small·embedder 64를 Phase 5 뒤로(micro 실측), `ReinvokeSelf` 제거 보류(폴백 가능성), 앱 롤 `StopInstances`·이동 태그 `gpu`·벤치마크 롤 삭제 확정. 쿼터(G)와 서비스 연결 역할(H)은 인프라 판단으로 확정.
- 2026-09-08 끄기 책임 정리(결정 L). 코드와 무관한 최후 안전장치로 인스턴스별 CloudWatch 정지 알람을 인프라 소유로 추가. GPU 2대에만 걸리는 근거는 §4.5.
