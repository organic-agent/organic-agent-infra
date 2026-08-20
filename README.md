# WES Infrastructure

OAuth 로그인과 사진 갤러리(업로드·임베딩) 테스트용 AWS 인프라를 Terraform으로 관리한다. 단일 EC2, Single-AZ RDS, 사진 원본 S3 버킷, 임베딩 Lambda로 구성한 폐기 가능한 테스트 환경이며, 운영용 고가용성·백업·삭제 보호는 구성하지 않는다.

---

## # 아키텍처

현재 Terraform 기본값 기준. 서비스 요청 경로와 배포·설정·state 흐름을 색으로 구분해 표시한다.

![WES 인프라 아키텍처](docs/wes-infrastructure-architecture.png)

편집 원본 : [`docs/wes-infrastructure-architecture.drawio`](docs/wes-infrastructure-architecture.drawio)

---

## # 주요 구성

DNS와 앱 스택을 분리해 앱 스택을 삭제해도 Hosted Zone과 NS 위임을 유지한다.

- 요청 경로 : `api.easyselect.kr` → ALB(HTTPS) → EC2 `:8080` → RDS PostgreSQL `:5432`
- 사진 경로 : 브라우저가 서명 URL로 S3(`wes-photos-*`)에 직접 PUT/GET → 사진 바이트가 앱을 거치지 않는다
- 임베딩 : 앱이 갤러리 단위로 Lambda(`wes-embedder`)를 비동기 호출 → Lambda가 S3 게이트웨이 엔드포인트로 원본을 읽어 `photos.embedding`에 기록
- 모니터링 : 앱이 logback appender로 모니터링 EC2(`wes-monitoring`, t4g.micro + EIP)의 Loki `:3100`에 로그를 보내고, `monitoring.easyselect.kr` → Caddy(Let's Encrypt) → Grafana로 조회한다. ALB를 거치지 않는다
- 네트워크 : 2개 AZ의 public/DB subnet. DB subnet은 인터넷 경로가 없고 S3 게이트웨이 엔드포인트만 연결된다
- 설정 : EC2 앱이 부팅 시 SSM Parameter Store 경로 `/wes/prod/*`를 읽는다. Grafana 비밀번호는 앱이 읽지 못하도록 `/wes/monitoring/*`에 분리한다. 경로 이름과 별개로 폐기 가능한 테스트 환경이며, DB 비밀번호는 `ephemeral` → `password_wo`로 전달해 state에 값을 저장하지 않는다
- 보안 : ALB `:80/:443` → EC2 `:8080`(ALB SG만) → RDS `:5432`(EC2·임베더 SG만), 모니터링 `:80/:443` 공개·`:3100`(앱 EC2 SG만)만 허용한다. EC2는 임시 public IP로 AWS API에 outbound 접근하며 SSH는 기본 차단한다
- 배포 : 앱은 GitHub Actions `main` → OIDC IAM Role → SSM Run Command → EC2. 인프라는 PR `plan`(읽기 전용 롤) → `main` 머지 시 `apply`(wes-* IAM만 쓰기 가능한 롤)
- State : app/dns 스택이 관리하지 않는 사전 생성 S3 backend에서 `app/terraform.tfstate`, `dns/terraform.tfstate` 키를 분리하고 S3 native lock을 사용한다

---

## # 확인 명령

인프라 변경 전 포맷·정적 검증·비파괴 계획을 확인한다.

```sh
terraform fmt -check -recursive
terraform validate
terraform plan
```

PR을 열면 CI가 같은 검사와 `plan`을 돌려 요약을 댓글로 달고, `main`에 머지되면 CD가 `apply`한다. 최초 배포와 CI 롤(`modules/github-actions`) 변경만 로컬 `apply`가 필요하다. `destroy`는 항상 수동이다.

---

## # 문서

배포·운영 절차와 Terraform 학습 내용은 별도 문서에서 관리한다.

- [배포 순서](docs/deploy-order.md)
- [운영 런북](docs/runbook.md)
- [Terraform 학습 가이드](wes-terraform-learning-guide.md)
