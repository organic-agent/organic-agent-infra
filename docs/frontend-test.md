# 테스트 프론트 AWS 실행

`https://test.easyselect.kr`는 원본 WES-Web에서 분리한 테스트 프론트를 실행한다. `api.easyselect.kr`의 공개 API를 사용한다.

## 구성

- `wes-frontend-test`: Ubuntu 24.04 ARM64, t4g.small, 암호화 gp3 20GiB, 빌드 피크용 swap 2GiB.
- EIP와 Route53 A 레코드. Caddy가 HTTP를 HTTPS로 전환하고 ACME 인증서를 갱신한다.
- SG는 인바운드 TCP 80/443만 허용한다. Next standalone은 `127.0.0.1:3000`으로 게시하며 SSH 키·22번 포트가 없다. 관리는 SSM으로 수행한다.
- 호스트 IAM은 비공개 배포 버킷 `releases/*` 읽기와 SSM 관리만 사용한다. `/wes/*` 파라미터 읽기를 명시 거부하고 IMDSv2 hop limit 1로 앱 컨테이너의 자격 증명 접근을 제한한다.
- 프론트 컨테이너는 비특권 사용자 이미지, 읽기 전용 파일 시스템, capabilities 제거, no-new-privileges, 768MiB 메모리 제한으로 실행한다.
- 소스 아카이브 버킷은 공개 접근 차단·SSE-S3·TLS 필수이며 아카이브는 30일 후 만료한다. 고객 사진을 저장하지 않는다.
- API·관리자·모니터링 리소스의 SG, ALB, IAM 및 라우팅은 변경하지 않는다.

## 첫 배포와 업데이트

프론트 담당은 Node22 standalone Dockerfile, `/health` 200, `/version.json`의 `SOURCE_REVISION` 또는 `BUILD_SHA` 노출을 제공한다. 빌드에 사용하는 값은 공개 API/origin만 넣고 서버 비밀 값은 전달하지 않는다.

프론트 변경을 로컬 Git에 커밋한 뒤 인프라 저장소에서 실행한다.

```sh
scripts/deploy-frontend-test.sh /absolute/path/to/WES-Frontend-Test
```

스크립트는 커밋된 소스만 압축하고 `.env`·자격 증명 설정·빌드 캐시·심볼릭 링크를 거부한다. AWS operator의 기존 인증으로 비공개 S3에 업로드하고 해당 한 대에 SSM Run Command를 보낸다. 머신이 SHA256을 검증한 후 ARM64 이미지를 빌드한다. `127.0.0.1:3001` 후보 컨테이너의 health/revision을 먼저 확인하고 기존 컨테이너를 교체한다. 최종 검증은 실제 HTTPS health/revision이다.

현재 원본 GitHub 저장소의 fork 정책 때문에 별도 테스트 원격과 CI 역할을 만들지 않는다. 원본 원격 설정을 우회하거나 기존 서버 배포 역할을 확장하지 않는다.

## API와 OAuth 선행조건

테스트 origin을 `/wes/prod/cors.allowed-origins`에 추가하면 앱 스택이 같은 값을 읽어 사진 S3 CORS를 맞춘다. 기존 origin은 보존한다. 공개 API는 시작 시 설정을 읽으므로 별도 서버 배포 또는 재시작이 필요하다. 이 설정 변경은 운영 CORS 변경 승인 후 수행한다.

OAuth provider 콘솔에도 `https://test.easyselect.kr/callback/google`, `/callback/kakao`, `/callback/naver`처럼 해당 공급자의 실제 callback을 등록해야 한다. 로그인 URL이 발급되는 것만으로 공급자 콘솔 설정 완료를 판단하지 않는다.

## 점검 및 로그

- HTTPS `/infrastructure-health`: Caddy/인증서 준비 상태. 프론트 배포 성공을 의미하지 않는다.
- HTTPS `/health`: 실제 Next 프로세스 health.
- HTTPS `/version.json`: 배포된 소스 commit SHA.
- SSM에서 `cloud-init status`, `docker ps`, `docker logs --tail 100 wes-frontend`, `docker logs --tail 100 wes-frontend-proxy`로 점검한다.
- Docker 로그는 10MiB × 3개로 회전한다. Caddy 접근 로그는 OAuth code/token이 남지 않도록 URI와 요청 헤더를 제거한다.
- `wes-frontend-test-status-check` CloudWatch alarm은 EC2 상태 점검 실패를 기록한다. SNS 알림 수신자는 별도 설정하지 않았다.

## 롤백

배포 전 후보 health/revision이 실패하면 기존 앱을 유지한다. 교체 후 health가 실패하면 직전 로컬 이미지를 자동 복구한다. 특정 이전 commit으로 되돌릴 때는 그 commit의 깨끗한 프론트 체크아웃으로 같은 배포 스크립트를 실행한다. 인증서 볼륨과 프록시는 앱 배포 중 유지한다.

신규 인프라 제거는 별도 검토한 Terraform 계획으로 수행하며 자동 destroy는 제공하지 않는다. 아티팩트 버킷은 `force_destroy=false`라 파일이 있으면 임의 제거되지 않는다.
