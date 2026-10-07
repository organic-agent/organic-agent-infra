# 인프라 구조 단순화 — prod와 dev를 같은 모양으로

지금 구조는 **운영이 저장소 루트**이고 **dev는 `environments/dev/`에서 같은 모듈을 손으로 다시 엮는다**. 그래서 두 환경의
생김새가 다르고, 운영에 모듈 하나를 더하면 dev에 같은 배선을 또 써야 한다. 이 문서는 "앱 한 벌"을 조립 모듈 하나로 묶고,
환경 폴더를 그 모듈을 부르는 얇은 껍데기로 만드는 작업을 PR 단위로 적는다. 운영 리소스는 **한 개도 다시 만들지 않는다**가 전 단계의 조건이다.

---

## # 0. 지금 상태 (2026-10-07, 브랜치 `feat/dev-environment` 기준)

| 위치 | 하는 일 | 크기 |
|---|---|---|
| 루트 `*.tf` (state `app/`) | 운영 앱 + VPC·모니터링·AMI 파이프라인 + 관리자 서버 + 테스트 프론트 + CI·CD 롤 + 로컬 개발 버킷 | main 345 · admin 122 · variables 489 · outputs 195줄 |
| `dns/` (state `dns/`) | Route53 존 | 리소스 1개 |
| `environments/dev/` (state `dev/`, **미커밋·미적용**) | dev 앱 한 벌. 운영 VPC·모니터링을 Name 태그로 찾아 읽음 | 761줄 |
| `modules/` | 기능 모듈 13개 | — |

복잡하게 느껴지는 원인은 네 가지다.

1. **조립 코드가 두 벌이다.** security → storage → database → compute → ingress → analysis → GPU 워커 배선이 루트와 dev에 따로 있다.
2. **운영 스택이 여러 역할을 겸한다.** "운영 앱", "두 환경이 같이 쓰는 기반(VPC·모니터링·AMI)", "계정 전체 것(CI 롤)"이 한 state에 섞여 있어, 루트만 봐서는 어디까지가 운영인지 알 수 없다.
3. **같은 모듈이 환경마다 다르게 쓰인다.** `security`는 dev에서도 모니터링 SG를 만들지만 아무 데도 붙지 않는다. `score-gpu`는 운영에선 파이프라인과 워커를 함께 만들고 dev에선 워커만 만든다.
4. **값이 변수 한 겹을 더 거친다.** 운영 `variables.tf`의 대부분은 바꿀 일 없는 상수인데, 모듈 블록까지 `var.x → x`로 그대로 넘기기만 한다.

dev가 **아직 apply 전**이라는 점이 기회다. dev state가 비어 있어 dev 쪽은 옮길 것 없이 새 모양으로 처음부터 만들면 된다.

---

## # 1. 목표 구조

```
environments/
  global/      Route53 존 (지금 dns/)                          state dns/  (키 유지)
  shared/      두 환경이 같이 쓰는 기반: VPC·Bedrock 피어링,      state shared/ (신규)
               모니터링 서버, GPU AMI 파이프라인, 로컬 개발 버킷
  prod/        module "app" + 운영 전용(관리자 서버, 테스트 프론트, CI 롤)   state app/ (키 유지)
  dev/         module "app" + dev 전용(없거나 거의 없음)          state dev/
stacks/
  app/         앱 한 벌 = 기능 모듈들의 배선 (보안 그룹·버킷·RDS·앱 EC2·ALB·Lambda 셋·GPU 워커·CD 롤·런타임 SSM 값)
modules/       기능 모듈 (지금 그대로, 일부 정리)
```

계층은 셋이고 방향은 한쪽이다: `environments/*` → `stacks/app` → `modules/*`. 환경 폴더는 서로를 부르지 않고, 공유 기반 값은 SSM `/wes/shared/*`로만 읽는다.

완성되면 두 환경의 `main.tf`는 이렇게 생긴다. **두 파일의 차이는 값뿐이다.**

```hcl
# environments/prod/main.tf (dev는 이름·프리픽스·도메인·AZ·브랜치만 다르다)
module "app" {
  source = "../../stacks/app"

  name_prefix      = "wes"
  parameter_prefix = "/wes/prod"
  subdomain        = "api"
  cd_branch        = "main"
  gpu_worker_azs   = ["ap-northeast-2a", "ap-northeast-2c"]
  extra_web_origins = ["https://${local.admin_fqdn}"]   # 운영만: 관리자 웹
}
```

### 1.1 일부러 남기는 차이

| 항목 | prod | dev | 왜 다른가 |
|---|---|---|---|
| 이름 · SSM 프리픽스 · 도메인 | `wes` · `/wes/prod` · `api` | `wes-dev` · `/wes/dev` · `dev.api` | 분리의 근거 자체 |
| GPU 워커 AZ | 2a·2c | 2a | G 쿼터 12 |
| CD 브랜치 | `main` | `develop` | |
| 관리자 서버 · 테스트 프론트 · CI(tf_plan/apply) 롤 | 있음 | 없음 | 운영 DB를 다루거나 계정 단위라 한 벌만 |
| GPU 워커 `user_data` | 없음 | `image.env`를 덮는 bootcmd | AMI에 운영 프리픽스가 구워져 있다. `stacks/app`이 `parameter_prefix != AMI 프리픽스`일 때 스스로 만든다 |

이 표 밖의 차이가 생기면 버그로 본다(§6 테스트).

### 1.2 원칙

1. **환경 값은 모듈 블록에 직접 쓴다.** 바꿀 일 없는 값을 `variables.tf`에 두지 않는다. 변수는 "운영 중에 실제로 바꾸는 값"(AMI ID, DB 비밀번호 버전, 이미지 태그 등)에만 둔다.
2. **환경 차이는 플래그 대신 값으로 표현한다.** `enable_x` 대신 빈 목록이나 `null`을 쓴다. 예: `gpu_worker_azs = []`면 워커가 생기지 않는다.
3. **스택 사이 계약은 SSM 값으로만 주고받는다.** `/wes/shared/vpc-id`처럼 명시적인 값을 쓰고, Name 태그 탐색이나 `terraform_remote_state`는 쓰지 않는다. 계약 목록은 §3.4에 있다.
4. **모듈 블록에 `depends_on`을 걸지 않는다.** 모듈 전체 `depends_on`은 안쪽 data 소스를 apply 시점으로 미뤄 plan에 가짜 변경을 만든다. 필요하면 리소스 단위로 건다.

---

## # 2. PR 순서

각 PR의 통과 조건은 같다. **운영 plan이 `0 to add, 0 to change, 0 to destroy`이고 나머지는 전부 `has moved`여야 한다.** 예외는 표에 따로 적었다.

| PR | 내용 | 운영 state | 위험 | 로컬 apply |
|---|---|---|---|---|
| **S1** | 모듈 정리 + `stacks/app` 추출 (루트 그대로) | `moved`만 | 낮음 | 불필요 |
| **S2** | dev를 `stacks/app` 위에 새로 씀 → 부트스트랩 → 첫 apply | 변화 없음 | 낮음 (dev만) | 런북 [2] ECR 단계 |
| **S3** | 폴더 이동: 루트 → `environments/prod`, `dns/` → `environments/global` | 키 유지, 변화 없음 | 낮음 | 불필요 |
| **S4** | `environments/shared` 분리 (VPC·모니터링·AMI 파이프라인·로컬 버킷) | `removed` + `import` | **중간** | 권장 |
| **S5** | (선택) CD 롤을 `stacks/app`으로 옮기고 `github-actions`는 CI·운영 전용만 남김 | `moved`만 | 중간 (CI 롤 모듈) | **필요** |

S1~S3만 끝나도 "prod와 dev가 같은 모양"이라는 목표의 대부분이 이뤄진다. S4는 두 환경이 기반을 읽는 방식까지 맞추는 단계다. S5는 CD 롤까지 대칭으로 만드는 마무리다.

---

## # 3. 단계별 세부

### 3.1 S1 — 모듈 정리 + `stacks/app` 추출

현재 브랜치의 모듈 변경(`score-gpu-workers` 분리, `storage.attach_app_role_policy`)은 이 PR에 넣는다. `environments/dev/`는 **넣지 않는다**(S2에서 다시 씀).

**모듈 정리** (모두 같은 state 안의 `moved`)

| 변경 | 이유 | 운영 주소 이동 |
|---|---|---|
| `security`의 모니터링 SG와 그 인그레스 2개를 `modules/monitoring`으로 | dev에 붙지 않는 SG가 생기는 문제 제거. 모니터링 SG는 모니터링 서버의 것 | `module.security.aws_security_group.monitoring` → `module.monitoring.aws_security_group.this` 외 |
| 앱 → Loki 인그레스(`monitoring_loki_from_ec2`)는 `stacks/app`이 `loki_security_group_id`를 받아 직접 만든다 | dev가 지금 루트에 따로 둔 `loki_from_dev_app`과 같은 모양 | `module.security...monitoring_loki_from_ec2` → `module.app.aws_vpc_security_group_ingress_rule.loki_from_app` |
| `score-gpu`는 파이프라인만 남기고 워커 호출을 뺀다 | 워커는 앱 한 벌의 일부, 파이프라인은 공유 기반 | `module.score_gpu.module.workers.*` → `module.app.module.score_gpu_workers.*` |
| `score_gpu.worker_tag_name` 등 워커 관련 출력은 `module.app`에서 나옴 | | 출력만 |

**`stacks/app`이 갖는 것**

`security`(모니터링 제외) · `storage` · `database` · `compute` · `ingress` · `analysis` · `score-gpu-workers`, 그리고 루트에 흩어진 앱 런타임 SSM 값 `app.llm.region` · `app.llm.model-id` · `app.analysis.gpu.tag`.

입력은 대략 이렇다(이름은 구현하면서 확정한다).

```hcl
variable "name_prefix" {}
variable "parameter_prefix" {}
variable "network" {            # S1~S3에서는 운영 루트가 module.network 출력을, dev가 data 조회 결과를 넘긴다. S4부터 둘 다 SSM에서 읽는다
  type = object({ vpc_id = string, public_subnet_ids = list(string), db_subnet_ids = list(string), azs = list(string) })
}
variable "zone" { type = object({ id = string, name = string }) }
variable "subdomain" {}
variable "extra_web_origins" { default = [] }
variable "loki_security_group_id" {}
variable "gpu_ami_id" {}
variable "gpu_worker_azs" { default = [] }
variable "gpu_ami_parameter_prefix" { default = "/wes/prod" }  # AMI에 구워진 값. 다르면 워커 user_data를 스택이 만든다
# 규격: instance_type, db 클래스, Lambda 메모리·동시성 … (기본값 = 운영 값)
```

규격 변수의 기본값은 운영 값으로 둔다. 그러면 두 환경 모두 규격 줄을 쓰지 않아도 되고, "dev는 운영과 같은 규격"이 코드에서 저절로 지켜진다.

**루트에서 바뀌는 것**: 모듈 블록 7개와 SSM 리소스 2개가 `module "app"` 하나로 바뀐다. `moved` 블록은 `moved.tf` 파일 하나에 모으고 기존 `#18`·`deploy.tf` 이력용 `moved`도 그리로 옮긴다. `outputs.tf`는 `module.app.*`을 가리키도록 고친다(출력 이름은 그대로라 런북의 `terraform output -raw …`는 바뀌지 않는다).

**확인**: 운영 plan이 0/0/0이고 `moved` 약 95건(현재 state 기준: security 16 · storage 7 · database 4 · compute 8 · ingress 10 · analysis 35 · GPU 워커 10 · SSM 2, 모니터링 SG 4건은 `module.monitoring`으로)이 전부 `has moved`로 나와야 한다. `name_prefix` 기반 이름이 그대로라 롤 ARN, 인스턴스 ID, 버킷 이름이 바뀌지 않는다.

### 3.2 S2 — dev를 `stacks/app` 위에 새로 쓰기

`environments/dev/main.tf`는 `module "app"` 하나와 공유 기반 조회만 남는다. 지금의 `deploy-roles.tf`는 S5 전까지 dev 폴더에 그대로 둔다.

- `network`·Loki SG·Loki URL은 S4 전까지 지금처럼 Name 태그와 `/wes/prod/app.logging.loki-url`로 읽는다. S4에서 SSM 계약으로 바꾼다.
- 런북 `docs/runbooks/dev-environment.md`는 [1]~[7] 절차를 그대로 쓰고, 경로와 리소스 주소만 고친다.
- 부트스트랩 → 첫 apply까지가 이 PR의 범위다(런북 순서 그대로).

**확인**: 운영 plan은 변화가 없어야 한다. dev plan은 생성만 있어야 한다. `diff environments/prod/main.tf environments/dev/main.tf`(S3 뒤)에 §1.1 표에 있는 값만 남아야 한다.

### 3.3 S3 — 폴더 이동

| 이동 | backend 키 | 하는 일 |
|---|---|---|
| 루트 `*.tf`·`.terraform.lock.hcl` → `environments/prod/` | **`app/terraform.tfstate` 그대로** | 파일만 옮긴다. 키가 같아 state 작업이 없다 |
| `dns/` → `environments/global/` | `dns/terraform.tfstate` 그대로 | 같은 이유 |

함께 고치는 곳: CI 경로 필터와 매트릭스(`terraform-plan.yml`·`terraform-apply.yml`의 `app` → `prod` 경로, `working-directory`), `tests/*.sh`의 `$repo_root/main.tf`·`variables.tf`·`outputs.tf`·`admin.tf` 경로(8개 파일), `scripts/deploy-frontend-test.sh`의 `-chdir`, `README.md`, `AGENTS.md`, `docs/runbooks/*.md`의 `terraform output`(앞에 `-chdir=environments/prod` 추가), 로컬 `.terraform/` 재-init.

모듈 `source = "./modules/x"`는 `"../../modules/x"`로 바뀐다. 리소스 주소는 그대로라 `moved`가 필요 없다.

**확인**: 새 경로의 plan이 0/0/0이어야 한다. 머지 직후의 CI apply도 "No changes"여야 한다.

### 3.4 S4 — `environments/shared` 분리

state를 건너는 이동이라 `moved`를 쓸 수 없다. Terraform 1.7+의 **`removed { lifecycle { destroy = false } }`(운영 쪽) + `import`(shared 쪽)** 쌍을 한 PR에 넣는다. 지금 CI·로컬 모두 1.15.8이다.

| 옮길 것 | 운영 쪽 주소 | 리소스 수(2026-10-07 state) |
|---|---|---|
| VPC·서브넷·라우트·S3 게이트웨이·Bedrock 피어링 | `module.network` | 26 |
| 모니터링 서버·EIP·레코드·SG(S1에서 옮긴 것) | `module.monitoring` | 13 |
| GPU AMI 파이프라인·서비스 연결 역할 둘 | `module.score_gpu` | 12 |
| 로컬 개발 버킷(`/wes/local`) | `module.storage_local` | 6 |

**shared가 공개하는 계약** (SSM `String`, shared 스택이 쓰고 두 환경이 읽음)

| 파라미터 | 값 |
|---|---|
| `/wes/shared/network/vpc-id` | VPC ID |
| `/wes/shared/network/public-subnet-ids` · `db-subnet-ids` | 쉼표 구분, AZ 순서 고정 |
| `/wes/shared/monitoring/security-group-id` | Loki 인그레스 대상 |
| `/wes/shared/monitoring/loki-push-url` | 앱이 쓸 URL. 각 환경의 `stacks/app`이 `${prefix}/app.logging.loki-url`로 복사 |
| `/wes/shared/score-gpu/ami-id` | (선택) 지금은 변수로 손으로 올리지만, 파이프라인 출력을 계약으로 두면 두 환경이 같은 값을 자동으로 따른다 |

운영 `/wes/prod/app.logging.loki-url`은 지금 `module.monitoring`이 만든다. 이것도 `stacks/app` 소유로 옮긴다(`removed` + `import`). 앱은 같은 이름과 같은 값을 계속 읽는다.

**순서와 안전장치**

1. import ID 목록을 만든다: `terraform state show`로 각 리소스 ID를 뽑아 `environments/shared/imports.tf`에 적는다.
2. PR plan 확인: shared는 `import` N개와 `0 to add`, prod는 `removed` N개(`will no longer be managed`)와 `0 to destroy`여야 한다. **destroy가 한 개라도 보이면 머지하지 않는다.**
3. CI apply 순서: global → **shared → prod** → dev. 잠깐 두 state가 같은 리소스를 함께 들고 있는 구간이 생기지만, prod의 `removed`가 실행되는 순간 해소된다.
4. 사고에 대비해 머지 전에 `app/terraform.tfstate`를 백업한다. 버킷 버전 관리가 켜져 있지만 명시적으로 복사본을 하나 더 둔다.

이 PR은 **로컬에서 shared를 먼저 apply한 뒤 머지**하는 편이 안전하다. import만 하는 apply라 실제 변경은 없다.

### 3.5 S5 (선택) — CD 롤 대칭화

지금 운영의 서버·AI CD 롤(`deploy`·`worker_deploy`)은 `modules/github-actions`에, dev의 같은 롤은 `environments/dev/deploy-roles.tf`에 따로 있다. 이 둘을 `stacks/app`의 `cd_branch` 입력으로 통일하고, `github-actions`에는 계정·운영 전용(OIDC 프로바이더, `tf_plan`·`tf_apply`, 관리자 롤 둘, 테스트 프론트 롤)만 남긴다.

- 운영 롤은 `moved`로만 옮긴다. `name_prefix = "wes-deploy-"`·`"wes-worker-deploy-"`가 그대로여야 ARN이 유지되고, 서버·AI 저장소 시크릿을 고치지 않아도 된다.
- `modules/github-actions` 변경이므로 저장소 규칙대로 로컬 apply가 필요하다.
- 이득은 대칭성뿐이고 위험은 CD 중단이다. S1~S4 뒤에 따로 판단한다.

---

## # 4. 끝났을 때의 모습

| | 지금 | S4 뒤 |
|---|---|---|
| 앱 배선 위치 | 루트, `environments/dev` 두 곳 | `stacks/app` 한 곳 |
| 환경 폴더 | 루트(운영) + `environments/dev` + `dns/` | `environments/{global,shared,prod,dev}` |
| prod·dev `main.tf` 차이 | 구조부터 다름 | §1.1의 값만 다름 |
| 운영 스택이 겸하는 역할 | 운영 앱·공유 기반·계정 | 운영 앱 + 운영 전용(관리자·테스트 프론트·CI 롤) |
| 스택 간 계약 | Name 태그 탐색 | `/wes/shared/*` SSM 값 |
| 새 모듈 추가 | 루트와 dev에 각각 배선 | `stacks/app`에 한 번 |

줄 수 목표는 두지 않는다. 대신 "환경 폴더에 `resource` 블록은 §1.1 표의 운영 전용 항목만"을 테스트로 고정한다.

---

## # 5. 다른 저장소·사람에게 미치는 영향

| 대상 | 영향 |
|---|---|
| 서버·AI·백오피스 저장소 CD | 없음. 롤 ARN과 인스턴스 Name 태그가 그대로다 |
| 서버 앱 | 없음. SSM 파라미터 이름과 값이 그대로다 |
| 로컬 작업자 | S3 뒤 `terraform -chdir=environments/prod …`로 바뀐다. `.terraform/` 재-init |
| GitHub 시크릿 | 없음 (S5에서도 ARN 유지가 조건) |

---

## # 6. 테스트

| 테스트 | 내용 |
|---|---|
| `tests/environment_shape_static_test.sh` (신규) | prod·dev가 모두 `source = "../../stacks/app"`을 부른다. dev 폴더에 `resource` 블록이 없다. prod 폴더의 `resource`·`module`은 허용 목록(관리자·테스트 프론트·github-actions)뿐이다 |
| 같은 파일 | `environments/*`에 `data "aws_vpc"`·`data "aws_subnet"` 태그 탐색이 없다 (S4 뒤) |
| 같은 파일 | 모듈 블록에 `depends_on`이 없다 |
| 기존 `tests/*.sh` | S1에서 주소, S3에서 경로를 고친다. 검사 내용 자체는 바꾸지 않는다 |
| `dev_environment_static_test.sh` | S2에서 `stacks/app` 기준으로 다시 쓴다 (`/wes/prod` 금지 검증, 태그 분리, ECR 분리) |

---

## # 7. 롤백

| PR | 되돌리는 법 |
|---|---|
| S1 | revert만으로는 부족하다. **역방향 `moved`**(`module.app.x` → `x`)를 넣은 PR을 따로 낸다. 리소스는 그대로다 |
| S2 | `terraform -chdir=environments/dev destroy`. 운영 영향 없음 |
| S3 | revert. state 키가 같아 파일 위치만 돌아간다 |
| S4 | 반대 방향의 `removed`(shared) + `import`(prod) 쌍. 백업한 state로 되돌리는 것은 최후 수단이다 |
| S5 | 역방향 `moved` + 로컬 apply |

---

## # 8. 지금 브랜치(`feat/dev-environment`)를 어떻게 하나

1. 모듈 변경(`score-gpu-workers`, `storage`, `tests/score_gpu_static_test.sh`)은 **S1 PR로** 보낸다.
2. `environments/dev/`, 런북, `dev_environment_static_test.sh`, CI의 dev 잡은 **S2로** 미룬다. 설계 결정(운영 VPC 공유, 운영 AMI + bootcmd, dev 전용 ECR, `develop` 브랜치)은 그대로 두고 배선만 `stacks/app` 위로 옮긴다.
3. dev는 아직 apply하지 않는다. S1 전에 dev를 세우면 S2에서 dev 쪽에도 `moved`가 생긴다.

---

## # 9. 검토 이력

- 2026-10-07 초안. solid-connection-infra 구조(`environment/<env>/` 대칭 + 스택 단위 모듈)와 비교해, 대칭 환경 폴더는 가져오고 덩어리 모듈은 가져오지 않는 방향으로 정함.
