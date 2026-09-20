# score 단계 Lambda → GPU 워커 풀 전환 — 인프라 변경 · 개선 · 트레이드오프 (2026-09-08)

사진 점수 계산(`score`: CLIP 임베딩 · ARNIQA 미학 · 기술 점수 · 피사체)을 **Lambda(CPU, 8 GB)** 로 내던 것을 **g6.xlarge GPU EC2
워커 풀**로 옮겼다. 이 문서는 인프라 저장소 관점이다 — 무엇이 어떻게 바뀌었는지(리소스·권한·PR), 그래서 무엇이 나아졌는지,
그 대가로 무엇을 지게 됐는지(성능·비용·운영). 설계 근거는 [계획 문서](../plans/pipeline-v2-infra-plan.md), 절차는
[런북 "GPU AMI"](../runbooks/runbook.md#-gpu-ami-score-워커-image-builder)에 있고 여기서는 반복하지 않는다.

숫자의 출처

| 표기 | 자료 |
|---|---|
| [S] | 서버 저장소 `wes/docs/improvements/score-lambda-vs-gpu-2026-09-08.md` — 2026-09-08 운영 실측(갤러리 9·10, 7,189장) |
| [A] | AI 저장소 `docs/experiments/gpu-benchmark-2026-09-07.md` — SageMaker·EC2 벤치마크 |
| [I] | 이 저장소 — PR 본문·plan 결과, 2026-09-08 리소스 인벤토리·CloudWatch 지표로 낸 비용 추정 |

단가는 ap-northeast-2 온디맨드 목록가다. Cost Explorer가 조직 SCP로 막혀 있어 청구액으로 검증하지는 못했다.

---

## 1. 한 장 요약

| | 이전: Lambda(CPU) | 이후: GPU 워커 풀 |
|---|---|---|
| 연산 | Lambda 8 GB(vCPU ≈5), 갤러리를 샤드 ≤32개로 나눠 병렬 | g6.xlarge(NVIDIA L4) 1대가 32장씩 직접 집음, fp16 |
| 장당 처리 시간 | 1.3~1.5초 [S] | **0.04초** (분당 ≈1,500장) [S] |
| 7,189장 갤러리 score 단계 | 6~10분 [S] | **4~5분 + 기동 1~2분** [S] |
| 7,189장 갤러리 비용 | $1.6~2.1 [S] | **$0.10~0.14** [S] |
| 사용량 0일 때 고정비 | ≈ $1/월 | ≈ $8~10/월(정지 인스턴스 EBS·AMI 스냅샷·ECR·알람) [S][I] |
| 인프라 코드 | `modules/analysis`의 함수 하나 | `modules/score-gpu`(AMI 파이프라인 + 워커 풀) + security·compute·github-actions 변경, +1,051줄 |
| 끄기 책임 | 없음(함수는 끝나면 사라진다) | 네 겹(워커 자기 정지 → wes 안전망 → CloudWatch 알람 → failsafe) |
| Lambda의 역할 | 유일한 경로 | **폴백**(워커가 안 뜨거나 10분 무진행일 때 wes가 50장 배치로 호출) |

핵심: 장당 속도 35~40배, 장당 비용 12~16배 개선. 대가는 기동 지연 1~2분, 한 번에 한 대라는 직렬성, 켜진 채 잊히면 시간당 $0.99가
새는 상태 기계, AMI라는 운영 표면이다. 인프라 고정비는 이 전환과 같이 한 정리(Lambda 간 호출 제거 → `lambda` 엔드포인트 삭제)로
오히려 월 $20 남짓 줄었다(§4.3).

---

## 2. 왜 바꿨나

Lambda 방식의 한계는 세 가지였고 셋 다 구조적이라 튜닝으로 풀리지 않았다.

1. **CPU 추론이 상한이다.** 8 GB를 잡아도 vCPU 5개, Lambda 한도(10 GB·vCPU 6)까지 가도 장당 1.3초 아래로 못 내려간다.
   7천 장 갤러리를 5분 안에 끝내려면 동시성으로 옆으로 늘리는 수밖에 없는데, 샤드 32개가 한꺼번에 RDS에 붙어 db.t4g.micro의
   커넥션(79)을 압박했다. 예약 동시성을 2 → 8 → 32로 올린 것(#29·#31·#33)이 이 방향의 끝이었다.
2. **배치마다 모델을 다시 로드한다.** CLIP-L + ARNIQA 로드 40초가 샤드/배치마다 붙는다. 50장 배치면 로드가 실행 시간의 36%다 [S].
3. **비용이 장당 선형이다.** 갤러리당 $1.7, 월 100갤러리면 $170. 사용량이 늘수록 GPU와의 차이가 벌어진다(§4.2).

GPU 한 대는 모델을 한 번 올려 두고 fp16으로 분당 1,500장을 처리한다. 벤치마크 [A]에서 SageMaker(ml.g6.xlarge)와 EC2(g6.xlarge,
DLAMI)를 재고 EC2를 골랐다 — SageMaker는 잡마다 프로비저닝 2~3분과 운영 미사용 확정, EC2는 정지/시작 16초 콜드에 시간당
$0.99. 결정 표는 계획 문서 §1(A~L).

---

## 3. 인프라가 어떻게 바뀌었나

### 3.1 리소스 전/후

| 영역 | 이전 | 이후 | 어디에 |
|---|---|---|---|
| 점수 연산 | `aws_lambda_function` wes-score(8 GB, /tmp 10 GB, 예약 32) | **그대로 둔다 — 폴백** | `modules/analysis` |
| GPU 워커 | 없음 | `aws_instance` ×2(2a·2c, g6.xlarge, 퍼블릭 서브넷, IMDSv2, key 없음) + `aws_ec2_instance_state` stopped(생성 직후 정지) | `modules/score-gpu/workers.tf` |
| 워커 AMI | 없음 | EC2 Image Builder 컴포넌트·레시피·infra/distribution configuration·파이프라인(schedule 없음). AL2023 + NVIDIA 580 + Docker + nvidia-container-toolkit + `wes-score` systemd 유닛 | `modules/score-gpu/main.tf`, `components/`, `files/` |
| 워커 롤 | 없음 | S3 `previews/*` 읽기 · ECR pull · SSM 파라미터 **세 개**(url·password·bucket) · KMS ViaService ssm · `ec2:StopInstances`(태그 `Name=wes-score-gpu` 조건) · SSM Core | `modules/score-gpu/workers.tf` |
| 서비스 연결 역할 | 없음 | `AWSServiceRoleForImageBuilder` · `AWSServiceRoleForCloudWatchEvents`(코드 관리) | `modules/score-gpu/main.tf` |
| 보안 그룹 | RDS ← embedder SG | + GPU SG(인바운드 0, 이그레스 전부), RDS ← GPU SG 5432 | `modules/security` |
| 앱(wes) 롤 | Lambda Invoke | + `ec2:DescribeInstances`(`*`), `ec2:Start/StopInstances`(태그 조건) | `modules/compute` |
| 끄기 안전장치 | — | CloudWatch 알람 ×2(인스턴스별 CPU 30분 < 5% → `arn:aws:automate:…:ec2:stop`), `wes-score-failsafe` 유닛(10분 3회 기동 실패 → 자기 정지) | `modules/score-gpu` |
| CI 권한 | `tf_apply` PowerUserAccess + 접두사 IAM | + 두 SLR ARN 한정 `iam:CreateServiceLinkedRole` 등(로컬 apply 1회) | `modules/github-actions` |
| SSM 파라미터 | `app.embedding.function-name` | `app.analysis.embedder-function-name`(wes V16 계약), `app.analysis.gpu.enabled`(변수 `gpu_score_enabled`, 지금 true) | `modules/analysis`, `admin.tf` |
| Lambda 간 호출 | `lambda` 인터페이스 엔드포인트(2 AZ), embedder `ReinvokeSelf`, score `ReinvokeSelfAndChainCategorize`, env `CATEGORIZE_FUNCTION_NAME` | **전부 삭제**. wes가 단계 전환을 소유 | `modules/network`, `modules/analysis` |
| Bedrock 엔드포인트 | 2 AZ | 1 AZ | `modules/network` |
| ECR `wes-score` | `latest` + untagged 3일 만료 | + 이동 태그 `gpu`(워커가 부팅마다 pull) · 불변 `gpu-<sha>`는 최근 3개만 | `modules/analysis` |
| DB 역할 | 커넥션 상한 없음 | `CONNECTION LIMIT` embedder 32 · photoselect 8 → 24 · wes_admin 40 (Terraform 밖, 런북) | 런북 "DB 사용자" |
| EC2 쿼터 | G 계열 vCPU 8 | 12 신청(2026-09-08, 승인 대기) — 빌드 4 + 워커 2대 8 | 계정 |

지운 것: 벤치마크가 남긴 IAM 롤 2개(`wes-gpu-benchmark`·`wes-sagemaker-benchmark`, 수동), `lambda` 엔드포인트와 Lambda 간
호출 권한. 지우지 않은 것: score Lambda 전체(폴백), `bedrock-runtime` 엔드포인트(categorize가 여전히 DB 서브넷에서 Bedrock을 부른다).

### 3.2 PR 이력 (2026-09-05 ~ 09-08)

```
#29 #31 #33  Lambda 동시성 2→8→32                    ← Lambda 방식의 마지막 확장. 여기서 한계가 드러남
#38          계획 문서 · Phase 0 런북                  ← 결정 A~L, PR 순서
(수동)       ALTER ROLE CONNECTION LIMIT · 벤치마크 IAM 삭제 · G 쿼터 12 신청
#40  3a      tf_apply에 SLR 권한 (로컬 apply)          ← CI가 서비스 연결 역할을 만들 수 있게
#42  3b      score-gpu AMI 파이프라인 + SLR 둘         ← Image Builder, 워커 유닛·스크립트
#44  hotfix  SSM 키 app.analysis.embedder-function-name 이동 + gpu.enabled   ← wes V16 배포와 맞물린 계약
#46 #48 #50 #52 #54  3b 후속(SLR description · TagRole · 예약 태그 · 유휴 30초 · kernel-devel 이름)  ← 첫 AMI 빌드에서 드러난 것들
#56  3c      워커 2대 · GPU SG · 워커 롤 · 유휴 정지 알람 · 앱 롤 EC2 제어  ← gpu_ami_id에 빌드 결과
#58          lambda 엔드포인트 · Lambda 간 호출 권한 제거, bedrock 1 AZ, 정지 워커 public-IP 드리프트 fix
#60          gpu_score_enabled = true                  ← 운영 경로 전환
```

3a → 3b → 3c로 쪼갠 이유: 3a는 `modules/github-actions`라 규칙상 로컬 apply, 3b가 만든 AMI ID가 있어야 3c의 인스턴스를 만들 수
있다(파이프라인 첫 실행은 사람이 돌린다). 첫 빌드에서 후속 fix가 다섯 개 나왔다 — Image Builder 예약 태그, AL2023 커널 패키지
이름(`kernel6.18-devel`), SLR description 한글 거부 같은 것들로, 계획으로는 못 잡고 실행해야 드러나는 종류였다.

### 3.3 실행 흐름 전/후

```
이전 (Lambda v1)
  wes ──EVENT {galleryId, jobId}──▶ score 조정자 ──자기 호출 ×N──▶ 샤드 1..N (각 137~225장, CPU 1.47 s/장)
                                                        └─ 마지막 샤드 ──EVENT──▶ categorize
  · 갤러리 = 잡 = 조정자. 끝 = 가장 느린 샤드의 끝(호스트 편차로 60% 느린 샤드가 전체를 2분 민 실측)
  · Lambda → Lambda 호출이라 DB 서브넷에 lambda 인터페이스 엔드포인트가 필요했다

이후 (GPU 워커 풀)
  wes GpuController(5초 스윕)
    ├─ backlog>0 ∧ 켜진 워커 0 ──ec2:StartInstances──▶ wes-score-gpu 1대
    │      └─ 부팅 → systemd wes-score → SSM 세 파라미터 → ECR wes-score:gpu pull → docker run --gpus all
    │             └─ photo_analysis에서 32장씩 SKIP LOCKED 집기 → GPU 점수 → UPSERT(커밋 = 잠금 해제) … 유휴 30초 → 자기 정지
    ├─ 워커 10분 무진행 ──EVENT {galleryId, photoIds ×50}──▶ score Lambda (폴백)
    └─ 점수가 다 차면 ──EVENT──▶ categorize (wes가 직접)
  · 워커는 갤러리·잡을 모른다. 벡터 있고 점수 없는 사진이면 집는다
  · 켜고 끄기: 워커(30초) → wes(무진행 2분) → 알람(CPU 30분 < 5%) → failsafe(기동 실패 3회)
```

---

## 4. 무엇이 나아졌나

### 4.1 성능 [S]

| 7,189장 갤러리 | Lambda v1 샤드 | Lambda v2 폴백(실측) | GPU 워커 |
|---|---|---|---|
| 첫 점수까지 | 40초(콜드 로드) | 40초 | 70~110초(EC2 부팅 + pull + 로드) |
| 장당 | 1.47초 | 2초(배치마다 로드) | 0.04초 |
| score 단계 wall | 6~10분 | 8~9분(이상) / **약 3시간**(접속 제한 8에 막힌 실측) | **4분 10초~4분 40초** |
| 갤러리 크기에 따라 | 비례해 늘어남(샤드 상한 32) | 비례 | 임베더 속도에 붙어 감 |

업로드와 동시에 돌린 실측(갤러리 10)에서는 업로드 시작 6분 뒤 7,189장 점수가 끝났고, 그중 점수가 임계 경로였던 구간은 임베딩
완료 뒤 49초뿐이다. **점수는 더 이상 병목이 아니다** — 파이프라인 임계 경로는 업로드(회선) → 임베더(Lambda)로 옮겨 갔다.

### 4.2 갤러리당 비용 [S]

| 7,189장 한 번 | 계산 | 금액 |
|---|---|---|
| Lambda v1 | 32 샤드 × 371초 × 8 GB × $0.0000166667 | $1.58~1.73 |
| Lambda v2 폴백 | 144 배치 × 85~110초 × 8 GB | $1.63~2.11 |
| GPU 워커 | running 465~495초 × $0.99/h | **$0.13** (기동·유휴 꼬리가 절반) |

월 시나리오(고정비 §4.3 포함): 월 6갤러리가 손익분기, 30갤러리면 75%, 100갤러리면 87% 절감. 100장짜리 작은 갤러리 하나는
둘이 같고($0.03), 그 아래에서는 GPU가 기동 1~2분만큼 시간에서 손해다.

### 4.3 인프라 고정비 — 전환 전후 [I]

| 항목 | 전환 전(09-07) | 전환 후(09-08) | 차이 |
|---|---|---|---|
| 인터페이스 엔드포인트 | lambda + bedrock × 2 AZ = ENI 4 → $43 | bedrock × 1 AZ = ENI 1 → $11 | **−$32** |
| GPU 워커 정지 상태(EBS 30 GB × 2) | — | $5.5 | +$5.5 |
| AMI 스냅샷 30 GB | — | $1.5 | +$1.5 |
| ECR `gpu`·`gpu-<sha>`(4.2 GB × ≤4) | — | ≈ $1.7 | +$1.7 |
| CloudWatch 알람 2 | — | $0.2 | +$0.2 |
| **합계** | $43 | **$20** | **−$23/월** |

`lambda` 엔드포인트를 지울 수 있었던 것은 GPU 전환 자체가 아니라 "단계 전환을 wes가 소유한다"는 v2 설계 덕이다 — Lambda가
Lambda를 부르는 경로(재호출·샤드 팬아웃·체인)가 코드에서 사라져야 엔드포인트와 InvokeFunction 권한을 뺄 수 있었다(#57).
GPU 전환 없이 v2 설계만 했어도 이 절감은 생겼을 것이고, GPU 전환만 하고 v2 설계를 안 했으면 고정비는 $43 + $9로 늘었을 것이다.

### 4.4 구조

- **Lambda 간 호출이 없다.** 재호출·팬아웃·체인이 wes로 가면서 실행 롤에서 `lambda:InvokeFunction`이 사라졌고, "함수가 15분 앞에서
  스스로 멈추고 자기를 다시 부른다"는 설명이 코드 주석·런북에서 지워졌다. 남은 Lambda는 `{galleryId, photoIds}` 하나만 받는 순수 함수다.
- **DB 커넥션이 예측 가능하다.** 워커는 커넥션 2개(레인 2개)다. 역할별 `CONNECTION LIMIT`가 앱 커넥션을 지키고, Lambda 폴백이
  한꺼번에 붙는 사고는 상한에서 막힌다(§5.5의 실측이 정확히 그 사고였다).
- **정합성은 오히려 낫다.** `SKIP LOCKED` 32장 단위 트랜잭션이라 워커가 배치 중간에 죽어도 행이 자동으로 돌아오고, score는 UPSERT라
  폴백과 겹쳐도 같은 값을 덮을 뿐이다.
- **코드와 드라이버의 갱신 축이 분리됐다.** AMI에는 드라이버·Docker·유닛만 굽고 코드 이미지는 부팅 때 `gpu` 태그를 pull 한다. AI
  저장소 push는 다음 부팅에 반영되고, AMI 재빌드는 드라이버·베이스를 올릴 때만이다(분기 1회 수준).

---

## 5. 트레이드오프 — 무엇을 지게 됐나

### 5.1 시간: 기동 지연

- Start → running 8초 → 부팅 · docker · ECR pull · 모델 로드 → 첫 점수까지 **70~110초**. Lambda는 콜드 40초, 웜이면 0초.
- 업로드와 겹치면 숨는다(실측: 첫 사진 0.4분 뒤 Start, 업로드 4.5분 동안 다 따라잡음). 수십 장짜리 갤러리를 하나만 올리면 Lambda가 1분 빠르다.
- 유휴 정지 30초(사용자 결정)는 "작업이 끝나면 바로 꺼진다"를 택한 것이다. 갤러리를 연달아 올리는 사용자는 매번 기동 1~2분을 다시 낸다.
  다중 사용자 운영에서 콜드가 아까워지면 변수 `gpu_worker_idle_stop_seconds`로 올린다(AMI 재빌드).

### 5.2 처리량: 한 번에 한 대, 직렬

- wes는 "켜진 워커가 없을 때" 한 대만 켠다. backlog가 커도 둘째 워커는 켜지 않는다. 한 대 1,500장/분이라 7천 장 갤러리 10개가
  동시에 들어오면 47분 큐다. Lambda는 동시성 32까지 갤러리 수와 무관하게 옆으로 늘었다.
- 워커는 갤러리 구분 없이 집으므로 여러 갤러리가 겹치면 섞여 처리된다. 갤러리 단위 SLA는 없다.
- 둘째 대를 쓰려면 wes에 "backlog ≥ N이면 2대" 규칙이 필요하고, 그러면 §5.4의 사고 비용 상한도 두 배다. 셋째 대부터는 G 쿼터(12,
  승인 대기)와 AZ별 g6 재고(`InsufficientInstanceCapacity` → 폴백)가 걸린다.

### 5.3 운영 표면: AMI · 드라이버 · 태그 롤백 · 로그

- Lambda는 코드 push로 끝났다. GPU는 Image Builder 파이프라인, 컴포넌트 YAML, systemd 유닛 3개·스크립트 3개, ECR 이동 태그, 롤·SG·
  알람·failsafe까지 인프라 표면이 넓다(+1,051줄). 정적 테스트 `tests/score_gpu_static_test.sh`가 §7 항목을 잡지만 빌드 자체는 CI 밖이다.
- 커널·드라이버 패키지 이름이 바뀌면 AMI 빌드가 깨진다(첫 빌드에서 실제로 `kernel6.18-devel`로 실패, #54). 컴포넌트·레시피는 불변이라
  내용이 바뀌면 버전을 올려야 하고, 빌드 한 번에 g6.xlarge 30분 ≈ $0.5다.
- 워커는 부팅마다 `wes-score:gpu` **최신 태그**를 pull 한다. 롤백은 태그를 이전 `gpu-<sha>`로 되돌리는 것뿐이고, Lambda의 불변
  버전·별칭 같은 것은 없다. 라이프사이클이 `gpu-<sha>`를 3개만 남기므로 롤백 창은 최근 3빌드다.
- 로그가 인스턴스 안(journald · `docker logs`)에 있다. CloudWatch에 안 오고, 정지된 뒤에는 켜서 SSM으로 들어가야 본다. Loki 전송은
  Phase 5에서 판단(계획 §4.2).

### 5.4 비용 구조: 고정비와 사고 비용의 꼬리

- Lambda는 0건이면 $0이고 최대 비용도 15분 × 동시성으로 상한이 있다. GPU는 아무것도 안 해도 월 $8~10이고, **정지가 전부 실패한 채
  주말을 넘기면 대당 $48**이 새는 꼬리가 있다.
- 그래서 끄기 책임이 네 겹이다. 그런데 실측 두 번 모두 1차(워커 자기 정지 30초)가 동작하지 않았고 wes 2분 안전망이 껐다 [S]. 회당
  $0.02~0.03 손해라 당장은 작지만, wes가 죽어 있으면 3차 알람(30분, 회당 $0.5)까지 간다. 원인은 워커 journal을 봐야 한다(§6).
- 정지 인스턴스는 퍼블릭 IP가 회수돼 프로바이더가 `associate_public_ip_address`를 false로 읽고 매 plan마다 replace를 만들었다(#58에서
  ignore_changes). 이런 종류의 드리프트는 Lambda에 없던 것이다.

### 5.5 Lambda 폴백을 유지하는 비용

- score Lambda(8 GB, /tmp 10 GB, 예약 동시성 32)는 그대로 남는다. 코드 이미지 두 벌(Lambda용 1.66 GB · GPU용 4.19 GB)을 AI CI가 함께
  민다. 예약 동시성은 프로비저닝이 아니라 무료지만, 계정 동시성 풀에서 32를 떼어 둔다.
- 폴백이 "미점수 전부를 50장씩 한꺼번에" 던져 `photoselect` CONNECTION LIMIT(8)에 막힌 실측이 있다(10분당 400장, 7,189장에 3시간).
  상한을 24로 올려 완화했지만, 폴백 발송을 동시성·접속 제한 안쪽으로 끊어 보내는 것은 wes 쪽 숙제다 [S]. 상한 자체는 앱 커넥션을
  지키는 울타리라 인프라는 그대로 둔다.

### 5.6 보안 경계

- 워커는 **퍼블릭 서브넷 + 퍼블릭 IP**(인바운드 0, 접속은 SSM만)다. 프라이빗 서브넷이면 ECR·SSM·S3 엔드포인트 월 $15~20 또는 NAT $43이
  더 들어서 택한 것이다(결정 A). Lambda는 DB 서브넷에서 엔드포인트로만 나갔다.
- 워커 롤은 `ec2:StopInstances`(태그 조건) · S3 previews 읽기 · SSM 세 파라미터 · ECR pull을 갖는다. 컨테이너 탈출 시 노출 면이 Lambda
  실행 롤보다 넓다. IAM으로 "자기 자신만 정지"는 표현할 수 없어 같은 태그의 워커 둘이 서로를 정지시킬 수 있는 범위다.
- `AWSServiceRoleForCloudWatchEvents`는 계정 전체 `ec2:StopInstances`를 갖는다. 쓰는 주체는 이 모듈의 알람 둘뿐이고 알람은 InstanceId
  dimension으로 워커 하나씩만 가리킨다(계획 §4.5 세 겹 확인). 정적 테스트가 `arn:aws:automate:`가 모듈 밖에 없음을 못 박는다.

### 5.7 로컬·테스트

- 로컬에는 GPU가 없다. AMI 빌드·드라이버·fp16·컨테이너 런타임 문제는 운영에서만 드러난다. 첫 빌드의 후속 fix 다섯 개가 그 증거다.

---

## 6. 남은 것

| # | 무엇 | 어디 | 왜 |
|---|---|---|---|
| 1 | 워커 자기 정지(30초)가 안 도는 원인 | AI(워커) · 인프라(롤 `StopSelf` 조건, IMDS hop limit 2) | 네 겹 중 1차가 빠진 채다. 다음 Start 때 `journalctl -u wes-score`에서 `StopInstances` 줄 확인 |
| 2 | 폴백 발송을 접속 제한 안쪽으로 끊기 | wes `GpuController.fallback()` | 실측 3시간 꼬리 |
| 3 | 둘째 워커 규칙("backlog ≥ N이면 2대") | wes | 동시 갤러리가 늘어 분당 1,500장을 넘길 때. 그 전엔 한 대가 임베더보다 빠르다 |
| 4 | G 쿼터 12 승인 확인 | 계정 | 승인 전에 AMI 재빌드와 워커 2대가 겹치면 빌드가 쿼터 초과로 실패 |
| 5 | 워커 로그 Loki 전송 | 인프라(monitoring SG + 워커 유닛) | Phase 5에서 필요하면. 지금은 SSM + journald |
| 6 | RDS small · embedder 예약 64 | 인프라 | Phase 5 부하 테스트 뒤(결정 D). GPU 전환으로 score 커넥션이 32 → 2로 줄어 급하지 않다 |
| 7 | AMI 갱신 주기와 옛 AMI 정리 | 런북 "GPU AMI" | 분기 1회. 옛 AMI는 `gpu_ami_id`가 바뀐 뒤 `deregister-image` + `delete-snapshot` |

---

## 7. 참고

- 계획과 결정: [`plans/pipeline-v2-infra-plan.md`](../plans/pipeline-v2-infra-plan.md) §1 결정 A~L, §4 모듈 설계, §4.5 끄기 책임, §9 롤백
- 절차: [`runbooks/runbook.md`](../runbooks/runbook.md) "GPU AMI" · "파이프라인 v2 준비(Phase 0)" · "DB 사용자"
- 코드: `modules/score-gpu/`(`main.tf` AMI 파이프라인, `workers.tf` 워커·알람, `files/` 유닛·스크립트), `modules/security/main.tf`
  GPU SG, `modules/compute/main.tf` 앱 롤 EC2 제어, `tests/score_gpu_static_test.sh`
- 실측 원본: [S] 서버 저장소 `wes/docs/improvements/score-lambda-vs-gpu-2026-09-08.md`(타임라인·REPORT 로그·단가 표·재측정 명령),
  [A] AI 저장소 `docs/experiments/gpu-benchmark-2026-09-07.md`
