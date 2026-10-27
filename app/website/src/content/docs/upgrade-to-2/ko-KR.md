---
title: 1.0에서 2.0으로 업그레이드
description: 1.x 사이트의 데이터베이스, Worker, Agent Home, 드라이브를 2.0으로 옮기고 복구 경로를 확인합니다.
section: Guides
order: 313
---

이 가이드는 Ankole 1.0 또는 이후 1.x 버전을 운영 중인 자체 호스팅 사이트를 2.0으로 업그레이드하는 절차를 안내합니다. 충분한 점검 시간(maintenance window)을 확보하고 1.x 버전의 모든 쓰기 프로세스를 완전히 중지한 뒤 새 마이그레이션을 실행하세요. 컨테이너 이미지만 이전 버전으로 되돌려서는 이미 적용된 데이터베이스 마이그레이션을 취소할 수 없습니다.

특히 초기 1.x 버전을 사용 중이거나 배포 구성을 커스터마이징한 경우, 또는 데이터베이스 스키마를 직접 수정한 적이 있다면 프로덕션 작업 전에 반드시 격리된 검증 환경에서 백업 사본으로 전체 절차를 먼저 리허설하세요.

## 달라지는 구성

| 이전 1.x 구성 | 2.0 구성 | 필요한 운영 작업 |
| --- | --- | --- |
| 풀(pool) 방식 Worker와 공유 `/agents` 볼륨 | Agent별 전용 Worker와 전용 `/workspace` | Agent Home 이전(또는 인계) 및 WorkerProvider 할당 |
| Home 내부의 Skill 및 Automation 스크립트 | 제어 플레인 드라이브의 `skills/`, `automation/` 경로 | 일회성 파일 가져오기(import) 실행 |
| Worker 로컬의 임시 Codex 상태 | `/workspace/.codex`에 영속 스레드, `/var/cache/ankole/codex`에 재구축 가능한 캐시 분리 | Home 보존 및 별도 캐시 디스크 준비 |
| 인프로세스 스크립트 실행 및 2개 이미지 구성 | 외부 무상태 `ankole-function-runtime` 분리(동일 버전 3개 이미지: `control-plane`, `worker`, `function-runtime`) | `ANKOLE_FUNCTION_RUNTIME_TOKEN` 추가 및 버전이 일치하는 세 이미지 동시 업그레이드 |
| 테넌트 구분이 없는 데이터 및 설정 | 기존 데이터를 `default` 테넌트로 귀속, Pod / Base 저장소에 **PostgreSQL 18+** 필수(선택적 `BASE_DB_URLS` 전용 샤드 지원) | PostgreSQL 18+로 먼저 업그레이드한 뒤 기존 암호화 키로 스키마 및 설정 마이그레이션 |
| `LocalPassword` 로그인 및 단일 관리자 그룹 | 100% 패스워드리스 인증(`SiteCredential` `email_otp` + 엔터프라이즈 SSO) 및 테넌트별 `pod_admin`과 `siteadmin` 분리 | 자격 증명 사전 검사 통과, SMTP(`authn.email.mail` 또는 `mix ankole.authn.mail.put`) 또는 SSO 구성, Pod 관리자 확인 |
| `/console` 경로의 Console | `/site-admin-console`(또는 `ANKOLE_SITE_ADMIN_CONSOLE_PATH`) 경로의 사이트 관리 Console | 북마크 및 Ingress 라우팅 규칙 업데이트 |

이미 전용 Worker나 드라이브 저장소를 사용 중인 1.x 사이트라면 해당하는 단계만 수행하면 됩니다. 기존 Agent Home이나 드라이브 볼륨을 빈 저장소로 덮어쓰지 않도록 주의하세요.

## 업그레이드 준비

1. 현재 버전과 목표 버전, 이미지 digest, Compose 프로젝트 이름 또는 Helm 릴리스 이름, 설치 식별자, 볼륨/PVC 이름, provider 설정을 모두 기록해 두세요. **세 이미지(`control-plane`, `worker`, `function-runtime`) 모두** 동일한 소스 리비전에서 빌드된 버전이어야 합니다(공식 제어 플레인 이미지에는 짝을 이루는 Worker 이미지 참조가 내장되어 있습니다).
2. 기존 `ANKOLE_SECRET_BASE`, 데이터베이스 자격 증명, 배포 설정을 안전하게 보관하고, 아직 없다면 각각 독립된 난수 16진수 값으로 `RELEASE_COOKIE`와 `ANKOLE_FUNCTION_RUNTIME_TOKEN`을 생성해 준비하세요. 저장된 자격 증명과 암호화 설정을 복호화해야 하므로 `ANKOLE_SECRET_BASE`는 절대 새로 생성해 바꾸지 마세요.
3. 1.x 서비스를 내리기 전에 Ecto 마이그레이션을 즉시 중단시키는 아래 사전 검사 항목들을 기존 환경에서 먼저 점검하고 해소하세요.
   - **예약 그룹 이름 충돌(`siteadmin` 및 `pod_admin`):** 특권 테넌트에 수동 생성한 `siteadmin` 그룹이 있거나, 어느 테넌트에든 수동 생성한 `pod_admin` 그룹(특히 `computed` 유형 그룹)이 있으면 업그레이드 전에 이름을 변경하세요. 두 이름 모두 2.0에서 시스템 예약어로 쓰이므로 이름이 겹치면 마이그레이션이 중단됩니다. 마이그레이션 완료 후 활성 관리자가 없는 테넌트가 생기면 `mix ankole.admin.recover HUMAN_UID OPERATOR REASON --identity-verified --tenant SLUG` 명령으로 복구할 수 있습니다(`--tenant`를 생략하면 특권 테넌트의 `siteadmin`을 복구합니다).
   - **패스워드리스 자격 증명 사전 검사(`Ankole.CredentialUpgrade.preflight!/1`):** 비가역 자격 증명 변환에 앞서 읽기 전용으로 먼저 실행됩니다. 퇴사 처리(`offboarded`)되지 않은 Human 주체(`active` 또는 `suspended`) 가운데 로그인 이메일이 비어 있거나 누락된 경우, 같은 테넌트의 유지 대상 Principal 둘 이상이 정규화된 동일 로그인 이메일을 공유하는 경우, 또는 단일 Principal에 로그인 이메일이 여러 개 등록된 경우 실행을 멈춥니다. 보고된 충돌 레코드를 1.x에서 정리한 뒤 다시 시도하세요. 변환 시 기존 브라우저 패스워드 인증 증명은 철회됩니다(고유한 원래 인증 증명에 1:1로 매핑되는 오프라인 OIDC 세션은 유지되며, 그 외 세션은 재인가가 필요합니다). 기존에 `LocalPassword`를 쓰던 사이트는 변환된 `email_otp` 사용자가 로그인할 수 있도록 반드시 SMTP(Console의 `authn.email.mail`, `mix ankole.authn.mail.put FILE.json` 또는 `Ankole.Release.put_authn_mail/1`)나 허용된 엔터프라이즈 SSO 소스를 구성해야 합니다.
   - **Console 권한 부여 CEL `resource` 변수 검사:** 2.0에서 `site_console:*` 또는 `tenant_console:*` 패턴으로 변환되는 레거시 Console grant는 CEL `condition` 식 안에서 `resource` 변수를 참조할 수 없습니다. 사용자 정의 Console grant를 점검해 업그레이드 전에 `resource` 참조를 제거하세요.
4. 신규 유입 요청과 예약 스케줄을 멈추고 모든 Agent를 비활성화한 뒤, 진행 중인 작업이 완전히 끝날 때까지 기다리세요. 이어서 일시 중지(`paused`) 상태인 인스턴스를 포함해 기존 Worker를 모두 정상 종료(graceful stop)한 다음, 1.x 제어 플레인 복제본을 전부 중지하세요. 이때 Worker를 내리려는 목적으로 Agent 자체를 삭제해서는 안 됩니다.
5. 데이터베이스 서버가 **PostgreSQL 18+**(`server_version_num >= 180000`, `shared_preload_libraries`에 `pg_search` 포함, `pg_search` 및 `vector` 확장 사용 가능) 요건을 충족하는지 확인하세요. PostgreSQL 데이터베이스(전용 `BASE_DB_URLS` 샤드 포함), 기존 파일 저장소, 전체 Agent Home, 배포 시크릿을 한 세트로 백업하고, 업그레이드 후 로그인·테넌트 멤버십·OIDC 검증이 모두 끝날 때까지 보관하세요. 백업 사본을 별도 인스턴스에 복원해 2.0 마이그레이션을 미리 돌려 보면 실제 소요 시간을 정확히 가늠할 수 있습니다. 또한 Docker Compose에서 Home 볼륨을 복사할 때는 기존 볼륨 사용량 이상의 여유 디스크 공간이 추가로 필요합니다. 백업 절차는 [백업과 복원](../backup-and-restore/)을 참조하세요.

마이그레이션 중에는 테넌트별 identity provider 설정 재암호화, 기존 Slack/Teams 공유 설정 분리, 외부 플랫폼 애플리케이션 ID 확인이 함께 수행됩니다. 따라서 원래 암호화 키와 유효한 플랫폼 자격 증명, 그리고 외부 플랫폼으로의 네트워크 연결이 열려 있어야 합니다. 실패 시 로그에 기록된 대상 설정을 수정한 뒤 재시도하시고, 데이터베이스의 암호문 문자열을 새 scope 행으로 임의 복사하지 마세요.

## Docker Compose 업그레이드

목표 릴리스 버전의 [Compose 배포 파일](https://github.com/AgentBull/ankole/tree/main/tools/deploy/docker-compose)(`compose.yaml`, `worker-providers.yaml`, `migrate-agent-homes.sh`)을 준비합니다. 기존 `.env` 파일과 프로젝트 이름은 그대로 유지한 채 `ANKOLE_CONTROL_PLANE_IMAGE`와 `ANKOLE_FUNCTION_RUNTIME_IMAGE`를 목표 릴리스의 일치하는 태그 또는 digest로 고정하세요(제어 플레인 이미지가 동일 버전의 Worker 이미지를 지정합니다). 아울러 `ANKOLE_DOCKER_GID`를 설정하고 기존 `ANKOLE_WORKER_INSTALLATION` 값을 유지합니다.

아래 명령 예시는 기본 로컬 파일시스템(`fs`) 구성을 기준으로 합니다. S3 백엔드를 사용하는 환경이라면 [드라이브 저장소](../drive-storage/)의 override 파일을 함께 준비하고, 파일 가져오기를 포함한 모든 Compose 명령에 동일한 `-f` 옵션을 지정하세요.

`.env` 파일에 `RELEASE_COOKIE`나 `ANKOLE_FUNCTION_RUNTIME_TOKEN`이 아직 없다면 추가합니다.

```sh
grep -q '^RELEASE_COOKIE=' .env || printf 'RELEASE_COOKIE=%s\n' "$(openssl rand -hex 32)" >> .env
grep -q '^ANKOLE_FUNCTION_RUNTIME_TOKEN=' .env || printf 'ANKOLE_FUNCTION_RUNTIME_TOKEN=%s\n' "$(openssl rand -hex 32)" >> .env
```

최초 provider 시드 파일에는 `legacy_agents: true`가 설정되어 있어야 하며, `provider_id` 값이 Home 이전 스크립트의 `WORKER_PROVIDER` 값과 일치해야 합니다(공식 파일 기본값은 `docker`). 시드 YAML은 데이터베이스의 provider 테이블이 비어 있을 때 한 번만 적재되므로, 이후 변경이 필요하면 YAML 파일이 아니라 Console에서 직접 수정합니다.

Ankole 2.0은 **PostgreSQL 18+**(`pg_search` 0.25.11 및 `vector`)를 요구하므로, 기존 데이터베이스가 PostgreSQL 18 미만이라면 먼저 메이저 버전 업그레이드를 마친 뒤 아래 절차에 따라 `pg_search` 확장을 업데이트하세요.

```sh
docker compose pull
docker compose stop
docker compose up -d postgresql
docker compose exec postgresql psql -U ankole -d ankole -v ON_ERROR_STOP=1 \
  -c "ALTER EXTENSION pg_search UPDATE TO '0.25.11'"
docker compose up -d --force-recreate
docker compose ps -a migrate migrate-agent-homes
docker compose logs migrate migrate-agent-homes
```

`migrate` 서비스는 데이터베이스 스키마와 설정 데이터를 이전하고, `migrate-agent-homes` 서비스는 이전 공유 볼륨을 물고 있는 컨테이너를 내린 뒤 현존하는 각 Agent의 Home 데이터를 전용 볼륨으로 복사해 `uid 1000` 소유권을 부여합니다. 두 일회성 서비스가 모두 정상 종료되어야 제어 플레인이 시작됩니다. 각 단계에는 완료 마커가 기록되므로 재실행하더라도 이미 복사가 끝난 디렉터리를 덮어쓰지 않으며, 이전 공유 볼륨이 없는 환경에서는 복사 작업 없이 바로 완료됩니다.

파일 가져오기가 끝날 때까지 Agent는 계속 비활성화 상태로 두세요. 1.x 환경에서 별도 드라이브 저장소를 쓰지 않았다면, 가져오기 프로세스가 이전 공유 볼륨을 읽을 수 있도록 권한을 조정한 뒤 가져오기 명령을 실행합니다(아래 예시는 기본 볼륨 이름인 `ankole_agents_data` 기준이므로, 커스텀 프로젝트 이름을 썼다면 실제 볼륨 이름으로 바꾸세요).

```sh
docker compose run --rm --no-deps --user root --entrypoint chmod \
  -v ankole_agents_data:/agents control-plane -R a+rX /agents
docker compose run --rm --no-deps -v ankole_agents_data:/agents:ro control-plane \
  /app/bin/ankole eval 'Ankole.Upgrade202610.import_agent_home("/agents")'
```

이 명령은 기존 Home에 있던 Skill, Automation 스크립트, 미전송 Outbox 첨부 파일을 드라이브로 복사하며, 이미 드라이브에 존재하는 경로는 덮어쓰지 않습니다. 그 밖의 일반 작업 파일과 Session/Job 워크스페이스는 각 Agent의 새 Home에 그대로 남습니다. 출력된 결과 보고서를 보관해 두고, `Skipped`로 표시된 파일이나 `main.ts`가 누락된 Automation Job이 있다면 정리한 뒤 가져오기를 다시 실행하세요. 모든 파일 확인과 복원 리허설을 마칠 때까지 이전 볼륨은 삭제하지 말고 그대로 두세요.

## Kubernetes / Helm 업그레이드

1. 기존 1.x 제어 플레인과 풀 방식 Worker Deployment의 replica 수를 `0`으로 줄이고 이전 Pod가 모두 종료될 때까지 기다리세요. 이때 강제 삭제나 `--grace-period=0` 옵션을 사용해서는 안 됩니다.
2. 외부 또는 번들 데이터베이스가 **PostgreSQL 18+**인지 확인합니다. `secrets.existingSecret`(`ankole-bootstrap`)을 사용하는 경우에는 `helm upgrade`를 실행하기 전에 기존 `ANKOLE_SECRET_BASE`, `DATABASE_URL`과 더불어 `RELEASE_COOKIE`와 `ANKOLE_FUNCTION_RUNTIME_TOKEN` 키가 시크릿에 들어 있는지 확인하고 누락된 키를 추가하세요.

```sh
kubectl -n ankole patch secret ankole-bootstrap --type merge -p "$(printf '{"stringData":{"RELEASE_COOKIE":"%s","ANKOLE_FUNCTION_RUNTIME_TOKEN":"%s"}}' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)")"
```

   (아직 `ankole-bootstrap`에 없는 키만 패치하세요.)
3. 기존 공유 Agent Home PVC를 그대로 유지하고 `worker.agents.persistence.existingClaim`에 연결합니다. 기존 `worker.installation` 값과 Helm 릴리스 이름도 바꾸지 말고 그대로 유지하세요. 번들 PostgreSQL 데이터가 볼륨 루트 경로에 들어 있었다면 원래 `postgresql.pgdata`(`/var/lib/pgsql/18/data`) 경로 설정도 그대로 유지해야 합니다(경로가 바뀌면 빈 신규 데이터베이스로 초기화될 수 있습니다).
4. 새 제어 플레인을 올리기 전에 Home 볼륨의 파일 소유권과 접근 권한을 먼저 맞춥니다. 아래 일회성 Pod 명령은 컨테이너 root가 `chown`을 수행할 수 있는 스토리지 환경을 기준으로 작성되었으므로, `OLD_AGENTS_PVC` 부분만 실제 PVC 이름으로 바꾸어 실행하세요.

```sh
kubectl -n ankole run ankole-agent-home-prepare --rm -i --restart=Never \
  --image=busybox:1.37 --overrides='{"apiVersion":"v1","spec":{
    "containers":[{"name":"prepare","image":"busybox:1.37",
      "securityContext":{"runAsUser":0},
      "command":["sh","-ec","chown -R 1000:1000 /agents; chmod 2777 /agents; chmod -R a+rX /agents"],
      "volumeMounts":[{"name":"agents","mountPath":"/agents"}]}],
    "volumes":[{"name":"agents","persistentVolumeClaim":{"claimName":"OLD_AGENTS_PVC"}}]}}'
```

기본 root-squash가 켜진 NFS에서는 Pod 내부에서 위 `chown` 명령이 동작하지 않습니다. 이 경우 NFS 서버 측에서 미리 권한을 조정해 Worker root 쓰기 및 소유권 변경을 허용하거나, 모든 접근을 `uid/gid 1000`으로 매핑하세요(`uid/gid 1000`이 지정된 AWS EFS Access Point를 쓰는 경우에는 별도 소유권 변환이 필요 없습니다). 스토리지별 세부 조건은 [WorkerProvider와 캐시 디스크](../worker-providers/)를 참조하세요.

이제 `values-production.yaml`에 버전이 일치하는 `controlPlane.image` 및 `functionRuntime.image` digest(Worker 이미지를 별도로 재정의하는 경우에만 동일 리비전의 `worker.image` 함께 지정), [드라이브 backend](../drive-storage/) 설정, 기존 PVC 참조를 반영한 뒤 업그레이드와 파일 가져오기를 실행합니다. 아래 예시는 네임스페이스와 릴리스 이름 모두 `ankole`이고 `fullnameOverride: ankole`인 구성을 기준으로 합니다.

```sh
helm upgrade ankole ./tools/deploy/helm/ankole-agent \
  --namespace ankole --values values-production.yaml \
  --set files.importAgentHomeClaim=OLD_AGENTS_PVC --wait --timeout 15m
kubectl -n ankole exec deployment/ankole-control-plane -c control-plane -- \
  /app/bin/ankole eval 'Ankole.Upgrade202610.import_agent_home("/agents")'
```

Deployment 전략은 `Recreate`로 동작하며, 새 Pod가 뜰 때 `db-migrate` 초기화 컨테이너가 데이터베이스 마이그레이션을 먼저 수행합니다. 파일 가져오기가 끝날 때까지 Agent는 비활성화 상태로 유지하세요. 결과 보고서에 문제가 없는지 확인한 뒤에는 `--set files.importAgentHomeClaim` 옵션을 빼고 `helm upgrade`를 한 번 더 실행해 임시 마운트를 정리합니다. 단, 공유 PVC 자체는 이후에도 Worker들이 Home으로 계속 사용하므로 삭제하지 말고 유지하세요. 커스텀 릴리스 이름이나 네임스페이스를 쓰는 경우 그에 맞게 대상 이름을 조정하시고, 전체 차트 옵션은 [Helm 가이드](https://github.com/AgentBull/ankole/blob/main/tools/deploy/helm/ankole-agent/README.md)를 참조하세요.

## 검증과 복구

- Console에 접속해 `default` 테넌트 아래에 기존 Agent, identity provider, signal binding, Job이 정상 조회되는지 확인하세요. 또한 기존 Agent마다 WorkerProvider가 할당되어 있어야 합니다(기본 provider 설정은 새로 만드는 Agent의 초기 배치에만 사용됩니다).
- 먼저 테스트할 Agent 하나만 활성화해 실제 파일 읽고 쓰기와 Job 실행을 검증하세요. 기존 Home 파일 접근, Codex 스레드 이어가기, Skill 로드, Automation 스크립트 실행, 드라이브 업로드·다운로드, 채팅 첨부 전송이 모두 정상인지 확인한 다음 나머지 Agent와 예약 스케줄을 순차적으로 다시 켜세요.
- 마이그레이션이 실패하면 1.x 제어 플레인을 절대 다시 띄우지 말고 멈춘 상태 그대로 Compose의 `migrate` 로그나 Kubernetes의 `db-migrate` 컨테이너 로그를 확인하세요. 암호화 키, 플랫폼 자격 증명, 예약 그룹 이름 충돌, 볼륨 권한 등 원인을 해결한 뒤 동일한 2.0 버전의 마이그레이션을 다시 실행하면 됩니다.
- 가져오기 보고서에 이미 삭제된 과거 Agent의 잔여 디렉터리가 표시되더라도, 그 디렉터리를 재활용해 새 Agent를 만들려 하지 마세요. 이전 디렉터리나 볼륨은 더 이상 참조할 파일이 없음을 완전히 확인한 뒤에 정리하세요.
- 부득이하게 1.x로 롤백해야 한다면 2.0 제어 플레인, `ankole-function-runtime`, 모든 Worker를 먼저 내린 뒤 업그레이드 직전에 떠 둔 PostgreSQL 백업(`BASE_DB_URLS` 전용 샤드 포함), 파일 저장소, Agent Home, 설정 파일, 원래 암호화 키를 한 세트로 복원하고 기존 1.x 이미지를 기동하세요. 단순 `helm rollback`이나 컨테이너 이미지 태그 변경만으로는 패스워드리스 자격 증명 변환이나 스키마 변경을 되돌릴 수 없으며, 업그레이드 이후 새로 기록된 데이터도 별도로 내보내지 않는 한 유지되지 않습니다.

업그레이드 이후 일상 운영에 대해서는 [Worker](../worker-management/), [드라이브 저장소](../drive-storage/), [재해 복구](../disaster-recovery/)를 참조하세요.
