# WES 배포 순서

제로 상태(앱 스택 destroy)에서 서비스가 뜰 때까지의 전체 순서.
각 단계의 상세 절차는 [runbook.md](runbook.md) 해당 섹션 참고.

```
[1] dns 스택 (최초 1회)          — Route53 존 + NS 위임
[2] SSM 수동 파라미터 등록        — DB 비밀번호, OAuth, cors 등
[3] 앱 스택 terraform apply      — VPC/ALB/EC2/RDS + 배포 롤
[4] AWS_DEPLOY_ROLE_ARN 시크릿   — 서버 저장소에 롤 ARN 등록
[5] 서버 저장소 main 머지         — CD가 빌드→GHCR→SSM 배포
[6] 검증                         — 헬스체크·타깃 그룹·OAuth
```

1~2는 한 번 해두면 destroy 후 재배포 때 건너뛴다. 3~4는 스택을 다시 세울 때마다,
5~6은 배포할 때마다 반복된다.

## [1] dns 스택 — 최초 1회

존은 앱 스택과 분리되어 destroy 후에도 남는다. 이미 위임돼 있으면 생략.

```bash
terraform -chdir=dns apply
dig NS easyselect.kr +short   # awsdns 4개면 위임 완료
```

상세: [runbook.md > 배포 1단계](runbook.md#1단계--dns-스택으로-존-생성-등록기관에서-ns-변경)

## [2] SSM 수동 파라미터 — 최초 1회

앱은 부팅 시 `/wes/prod/` 아래를 통째로 읽는다. **아래가 없으면 앱이 부팅에 실패한다**
(빠지면 `Could not resolve placeholder ...` 에러로 컨테이너가 재시작 루프를 돈다):

| 파라미터 (`/wes/prod/` 아래) | 타입 | 비고 |
|---|---|---|
| `spring.datasource.password` | SecureString | RDS 마스터 비밀번호 — apply **전에** 있어야 함 |
| `jwt.secret` | SecureString | |
| `spring.security.oauth2.client.registration.{kakao,google,naver}.*` | SecureString | client-id/secret, redirect-uri, scope 등 |
| `cors.allowed-origins` | String | 쉼표 구분 문자열 (프론트 오리진 목록) |
| `springdoc.server-url` | String | `https://api.easyselect.kr` |

`spring.datasource.url`·`username`은 테라폼이 apply 때 자동 생성하므로 등록하지 않는다.
파라미터는 destroy와 무관하게 남으므로 최초 1회만 등록하면 된다.

상세: [runbook.md > 사전 준비](runbook.md#사전-준비-최초-1회), [설정 주입](runbook.md#설정-주입-ssm-파라미터)

## [3] 앱 스택 apply — 스택 세울 때마다

```bash
terraform apply   # ~39개 리소스, ACM 검증 포함 5~15분
```

EC2 user_data가 Docker·스왑을 설치하고, GitHub Actions용 OIDC 배포 롤도 함께 생성된다.

## [4] 배포 롤 시크릿 등록 — 스택 세울 때마다

```bash
terraform output -raw github_deploy_role_arn
```

이 값을 서버 저장소 **Settings → Secrets and variables → Actions**의
`AWS_DEPLOY_ROLE_ARN` 시크릿에 등록(있으면 Update).

> **주의:** 롤 이름에 랜덤 접미사가 붙어 **destroy → apply를 거치면 ARN이 바뀐다.**
> 스택을 다시 세웠다면 시크릿도 갱신해야 한다. 안 하면 CD가
> `Not authorized to perform sts:AssumeRoleWithWebIdentity`로 실패한다.

## [5] 앱 배포 — CD 자동

서버 저장소(WES-Server)에서 **main에 머지**하면 CD가 자동으로:

1. JAR 빌드 → arm64 이미지 빌드 → GHCR 푸시
2. OIDC로 배포 롤 assume (main 브랜치 토큰만 허용)
3. `wes-app` 태그로 인스턴스 조회 → SSM Run Command로 `docker compose pull && up`
4. 헬스체크(최대 150초) 통과까지 확인

같은 이미지 재배포는 Actions 탭 → `[PROD] Build and Deploy` → Run workflow (**main 브랜치 선택** — 다른 브랜치는 롤 신뢰 조건에 걸려 실패한다).

순서 주의: 스택이 없는 상태에서 머지하면 배포 잡이 "실행 중인 wes-app 인스턴스가
없습니다"로 실패한다(빌드·푸시는 성공). 재실행은 [3]~[4] 후 workflow_dispatch로.

## [6] 검증

```bash
curl -s https://api.easyselect.kr/actuator/health   # {"status":"UP"}
```

타깃 그룹은 기동 후 `healthy` 전환까지 2~3분 걸린다(30초 간격 × 5회).
전체 체크리스트: [runbook.md > 검증 체크리스트](runbook.md#검증-체크리스트)

## 폐기 시 남는 것

`terraform destroy` 후에도 다음은 남는다 — 재배포 시 재사용되므로 지우지 말 것
(프로젝트를 완전히 접을 때만 정리):

| 남는 것 | 위치 |
|---|---|
| Route53 존 | dns 스택 (월 $0.50) |
| `/wes/prod/*` 수동 파라미터 | SSM Parameter Store |
| 컨테이너 이미지 | GHCR |
| `AWS_DEPLOY_ROLE_ARN` 시크릿 | 서버 저장소 (재apply 시 값 갱신 필요 — [4] 참고) |
