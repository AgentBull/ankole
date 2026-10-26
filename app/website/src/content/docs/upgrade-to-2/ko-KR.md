---
title: 1.0에서 2.0으로 업그레이드
description: 1.x 사이트의 데이터베이스, Worker, Agent Home, 드라이브를 2.0으로 옮기고 복구 경로를 확인합니다.
section: Guides
order: 313
---

이 가이드는 1.0 또는 이후 1.x에서 2.0으로 옮기는 자체 호스팅 사이트를 위한 문서입니다. 유지보수 시간을 확보하고 이전 버전의 모든 쓰기 프로세스를 중지한 뒤 새 migration을 실행하세요. 이미지 변경으로 데이터베이스 migration을 되돌릴 수 없습니다.

프로덕션을 업그레이드하기 전에 격리 환경에서 백업으로 이 절차를 먼저 검증하세요(특히 초기 1.x 버전, 사용자 지정 배포, 수정한 schema인 경우).

## 달라지는 구성

| 이전 1.x 구성 | 2.0 구성 | 운영 작업 |
| --- | --- | --- |
| 풀형 Worker와 공유 `/agents` | Agent마다 Worker와 전용 `/workspace` | Home 이전 또는 인계와 WorkerProvider 할당 |
| Home의 Skill과 Automation 스크립트 | 제어면 드라이브의 `skills/`, `automation/` | 일회성 파일 가져오기 실행 |
| Worker의 임시 Codex 상태 | `/workspace/.codex`에 스레드, `/var/cache/ankole/codex`에 재구축 가능한 캐시 | Home 유지와 별도 캐시 디스크 준비 |
| 인프로세스 스크립트 실행과 2개 이미지 구성 | 외부 무상태 `ankole-function-runtime` (동일 버전 3개 이미지: `control-plane`, `worker`, `function-runtime`) | `ANKOLE_FUNCTION_RUNTIME_TOKEN` 추가 및 버전이 일치하는 세 이미지 동시 업그레이드 |
| 테넌트 소유권이 없는 데이터와 설정 | 기존 데이터는 `default` 테넌트, Pod / Base 저장소는 **PostgreSQL 18+** 필수(선택적 `BASE_DB_URLS` 전용 샤드 지원) | PostgreSQL 18+로 업그레이드한 뒤 원래 키로 schema와 암호화 설정 이전 |
| `LocalPassword` 로그인과 단일 관리자 그룹 | 100% 패스워드리스 인증(`SiteCredential` `email_otp` + 엔터프라이즈 SSO) 및 테넌트별 `pod_admin`과 `siteadmin` 분리 | 자격 증명 사전 검사 통과, SMTP(`authn.email.mail` 또는 `mix ankole.authn.mail.put`) 또는 SSO 구성 및 Pod 관리자 확인 |
| `/console`의 Console | `/site-admin-console`(또는 `ANKOLE_SITE_ADMIN_CONSOLE_PATH`)의 사이트 관리 Console | 북마크와 Ingress 규칙 업데이트 |

이미 전용 Worker나 드라이브를 사용하는 1.x 사이트는 필요한 단계만 실행하세요. 기존 Home이나 드라이브를 빈 저장소로 바꾸지 마세요.

## 업그레이드 준비

1. 현재 및 목표 버전, 이미지 digest, Compose project 또는 Helm release 이름, 설치 식별자, volume/PVC 이름, provider 설정을 기록하세요. **세 이미지 모두**(`control-plane`, `worker`, `function-runtime`) 같은 소스 revision이어야 합니다. 공식 제어면 이미지에는 맞는 Worker 이미지 참조가 포함됩니다.
2. 원래 `ANKOLE_SECRET_BASE`, 데이터베이스 자격 증명, 배포 설정을 보관하고, 아직 없다면 독립적인 16진수 `RELEASE_COOKIE`와 `ANKOLE_FUNCTION_RUNTIME_TOKEN`을 준비하세요. 기존 자격 증명과 설정을 복호화하는 `ANKOLE_SECRET_BASE`를 다시 생성하지 마세요.
3. 이전 버전을 중지하기 전에 Ecto migration을 즉시 중단시키는 모든 사전 검사 항목을 이전 환경에서 확인하고 해결하세요.
   - **예약 그룹 이름 충돌(`siteadmin` 및 `pod_admin`):** 특권 테넌트에 직접 만든 `siteadmin` 그룹이 있거나 어느 테넌트에든 직접 만든 `pod_admin` 그룹(특히 `computed` 그룹)이 있다면 업그레이드 전에 이름을 바꾸세요. 두 이름 모두 2.0에서 예약되어 있으며 충돌하면 migration이 중단됩니다. 이전 후 명확한 활성 관리자가 없는 테넌트는 `mix ankole.admin.recover HUMAN_UID OPERATOR REASON --identity-verified --tenant SLUG`로 복구할 수 있습니다(`--tenant`를 생략하면 특권 테넌트의 `siteadmin`을 복구합니다).
   - **패스워드리스 자격 증명 사전 검사(`Ankole.CredentialUpgrade.preflight!/1`):** 파괴적 자격 증명 변환 전에 읽기 전용으로 실행되며, 퇴사 처리(offboarded)되지 않은 Human(active 또는 suspended)의 로그인 이메일이 비어 있거나 누락된 경우, 같은 테넌트의 두 유지 Principal이 동일한 정규화 로그인 이메일을 공유하는 경우, 또는 한 Principal이 여러 로그인 이메일을 가진 경우 실행을 중단합니다. 보고된 충돌 레코드를 1.x에서 정리한 뒤 다시 시도하세요. 변환 과정에서 브라우저 패스워드 증명은 철회됩니다(고유한 원래 증명에 일대일 대응되는 오프라인 OIDC 세션은 증거를 유지하고, 나머지는 재인가가 필요합니다). `LocalPassword`를 사용하던 사이트는 이전된 `email_otp` 사용자가 로그인할 수 있도록 반드시 SMTP(Console의 `authn.email.mail`, `mix ankole.authn.mail.put FILE.json` 또는 `Ankole.Release.put_authn_mail/1`)나 허용된 엔터프라이즈 SSO 소스를 구성해야 합니다.
   - **Console 권한 부여 CEL `resource` 변수 검사:** `site_console:*` 또는 `tenant_console:*`로 다시 쓰이는 레거시 Console grant는 CEL `condition`에서 `resource` 변수를 참조할 수 없습니다. 사용자 지정 Console grant를 점검해 업그레이드 전에 `resource` 참조를 제거하세요.
4. 새 요청과 예약 작업을 중지하고 Agent를 비활성화한 뒤 진행 중인 작업이 끝날 때까지 기다리세요. 일시 중지된 인스턴스를 포함한 모든 이전 Worker를 정상 종료한 다음 이전 제어면 복제본을 모두 중지하세요. Worker를 멈추기 위해 Agent를 삭제하지 마세요.
5. 데이터베이스 서버가 **PostgreSQL 18+**(`server_version_num >= 180000`, `shared_preload_libraries`에 `pg_search` 포함, `pg_search` 및 `vector` 사용 가능)인지 확인하세요. PostgreSQL(구성된 전용 `BASE_DB_URLS` 샤드 데이터베이스 포함), 기존 파일 저장소, 모든 Agent Home, 배포 비밀을 함께 백업하고 로그인·테넌트 멤버십·OIDC 검증이 끝날 때까지 보관하세요. 먼저 복원된 데이터베이스 사본에서 2.0 migration을 실행해 유지보수 소요 시간을 확인하세요. Compose Home 복사는 이전 volume 사용량 이상의 추가 여유 공간이 필요합니다. [백업과 복원](../backup-and-restore/)을 참조하세요.

업그레이드는 테넌트 identity provider 설정을 다시 암호화하고 이전 Slack/Teams 공유 설정을 나누며 플랫폼 애플리케이션 ID를 확인합니다. 원래 키, 유효한 플랫폼 자격 증명, 해당 플랫폼으로의 네트워크 접근이 필요합니다. 실패 로그에 나온 설정을 고쳐 재시도하세요. 암호문을 새 scope에 직접 복사하지 마세요.

## Docker Compose 업그레이드

목표 버전의 [Compose 배포 파일](https://github.com/AgentBull/ankole/tree/main/tools/deploy/docker-compose)을 사용하세요. `compose.yaml`, `worker-providers.yaml`, `migrate-agent-homes.sh`가 필요합니다. 원래 `.env`와 project 이름을 유지하고 `ANKOLE_CONTROL_PLANE_IMAGE`와 `ANKOLE_FUNCTION_RUNTIME_IMAGE`를 목표 릴리스의 일치하는 이미지 또는 digest로 고정하세요(제어면 이미지가 일치하는 Worker 이미지를 지정합니다). `ANKOLE_DOCKER_GID`를 설정하고 원래 `ANKOLE_WORKER_INSTALLATION`을 유지하세요.

예시는 공식 `fs` 설정입니다. S3는 [드라이브 저장소](../drive-storage/)의 override를 준비하고 가져오기를 포함한 모든 Compose 명령에 같은 `-f`를 사용하세요.

`.env`에 `RELEASE_COOKIE`나 `ANKOLE_FUNCTION_RUNTIME_TOKEN`이 없다면 추가하세요.

```sh
grep -q '^RELEASE_COOKIE=' .env || printf 'RELEASE_COOKIE=%s\n' "$(openssl rand -hex 32)" >> .env
grep -q '^ANKOLE_FUNCTION_RUNTIME_TOKEN=' .env || printf 'ANKOLE_FUNCTION_RUNTIME_TOKEN=%s\n' "$(openssl rand -hex 32)" >> .env
```

첫 provider seed에는 `legacy_agents: true`가 필요하며 `provider_id`는 Home 이전 서비스의 `WORKER_PROVIDER`와 같아야 합니다. 공식 파일은 `docker`를 사용합니다. seed는 provider 테이블이 비었을 때만 가져옵니다. 이후 YAML 수정은 저장된 provider를 바꾸지 않습니다.

2.0은 **PostgreSQL 18+**(`pg_search` 0.25.11 및 `vector`)를 요구합니다. 기존 데이터베이스가 PostgreSQL 18 미만이면 먼저 주요 버전 업그레이드를 완료한 뒤 `pg_search` 확장을 업데이트하세요.

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

`migrate`는 schema와 설정 데이터를 옮깁니다. `migrate-agent-homes`는 이전 공유 volume을 사용하는 컨테이너를 중지하고 존재하는 Agent의 Home을 전용 volume에 복사하며 uid 1000 소유권을 설정합니다. 두 서비스가 성공해야 제어면이 시작됩니다. 완료 표시가 있어 재시도가 완료된 디렉터리를 덮어쓰지 않습니다. 이전 volume이 없으면 복사 없이 완료합니다.

Agent는 비활성화 상태로 유지하세요. 이전 버전에 드라이브가 없었다면 가져오기 프로세스가 이전 volume을 읽도록 준비하고 파일을 가져오세요. 다음은 기본 project 예시이며 사용자 지정 이름은 `ankole_agents_data`를 원래 volume으로 바꾸세요.

```sh
docker compose run --rm --no-deps --user root --entrypoint chmod \
  -v ankole_agents_data:/agents control-plane -R a+rX /agents
docker compose run --rm --no-deps -v ankole_agents_data:/agents:ro control-plane \
  /app/bin/ankole eval 'Ankole.Upgrade202610.import_agent_home("/agents")'
```

가져오기는 Skill, Automation 스크립트, 미전송 이전 Outbox 첨부 파일을 복사하며 기존 드라이브 경로를 덮어쓰지 않습니다. 다른 사용자 파일과 Session/Job 작업 공간은 Home에 남습니다. 보고서를 보관하고 `Skipped` 파일과 `main.ts`가 없는 Job을 수정해 다시 가져오세요. 파일 검사와 복원 연습이 끝날 때까지 이전 volume을 유지하세요.

## Kubernetes / Helm 업그레이드

1. 이전 제어면과 풀형 Worker Deployment를 0으로 줄이고 이전 Pod가 모두 사라질 때까지 기다리세요. 강제 삭제나 `--grace-period=0`을 사용하지 마세요.
2. 외부 또는 번들 데이터베이스가 **PostgreSQL 18+**인지 확인하세요. `secrets.existingSecret`(`ankole-bootstrap`)을 사용하는 경우 `helm upgrade` 전에 `ANKOLE_SECRET_BASE` 및 `DATABASE_URL`과 함께 `RELEASE_COOKIE`와 `ANKOLE_FUNCTION_RUNTIME_TOKEN`이 모두 포함되어 있는지 확인하세요.

```sh
kubectl -n ankole patch secret ankole-bootstrap --type merge -p "$(printf '{"stringData":{"RELEASE_COOKIE":"%s","ANKOLE_FUNCTION_RUNTIME_TOKEN":"%s"}}' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)")"
```

   (`ankole-bootstrap`에 아직 없는 키에 대해서만 실행하세요.)
3. 이전 공유 Agent Home PVC를 유지하고 `worker.agents.persistence.existingClaim`으로 지정하세요. 원래 `worker.installation`과 release 이름을 유지하세요. 이전 데이터베이스가 volume 루트에 있으면 원래 `postgresql.pgdata`(`\/var\/lib\/pgsql\/18\/data`)를 유지하세요. 새 디렉터리를 쓰면 빈 데이터베이스처럼 보일 수 있습니다.
4. 새 제어면을 시작하기 전에 Home 소유권과 권한을 준비하세요. 다음 명령은 Pod root가 `chown`할 수 있는 저장소용입니다. `OLD_AGENTS_PVC`를 실제 이름으로 바꾸세요.

```sh
kubectl -n ankole run ankole-agent-home-prepare --rm -i --restart=Never \
  --image=busybox:1.37 --overrides='{"apiVersion":"v1","spec":{
    "containers":[{"name":"prepare","image":"busybox:1.37",
      "securityContext":{"runAsUser":0},
      "command":["sh","-ec","chown -R 1000:1000 /agents; chmod 2777 /agents; chmod -R a+rX /agents"],
      "volumeMounts":[{"name":"agents","mountPath":"/agents"}]}],
    "volumes":[{"name":"agents","persistentVolumeClaim":{"claimName":"OLD_AGENTS_PVC"}}]}}'
```

기본 root-squash NFS에서는 Pod에서 이 `chown`을 할 수 없습니다. NFS 서버에서 파일을 준비하고 Worker root 쓰기와 소유권 변경을 허용하거나 모든 접근을 uid/gid 1000으로 매핑하세요. uid/gid 1000 EFS access point를 쓰는 파일은 소유권 변환이 필요 없습니다. [WorkerProvider와 캐시 디스크](../worker-providers/)를 참조하세요.

`values-production.yaml`에 버전을 맞춘 `controlPlane.image` 및 `functionRuntime.image` digest(Worker 이미지를 명시적으로 재정의할 때만 같은 리비전의 `worker.image` 지정), [드라이브 backend](../drive-storage/), 이전 PVC를 설정하고 실행하세요.

명령은 namespace와 release 이름 `ankole`, `fullnameOverride: ankole`를 가정합니다.

```sh
helm upgrade ankole ./tools/deploy/helm/ankole-agent \
  --namespace ankole --values values-production.yaml \
  --set files.importAgentHomeClaim=OLD_AGENTS_PVC --wait --timeout 15m
kubectl -n ankole exec deployment/ankole-control-plane -c control-plane -- \
  /app/bin/ankole eval 'Ankole.Upgrade202610.import_agent_home("/agents")'
```

Deployment는 `Recreate`를 사용하며 새 Pod의 `db-migrate` init container가 migration을 먼저 실행합니다. 가져오기가 완료될 때까지 Agent를 비활성화하세요. 보고서를 확인하고 `files.importAgentHomeClaim`을 제거한 뒤 다시 업그레이드하세요. Worker는 이전 Home PVC가 계속 필요하므로 유지하세요. 사용자 지정 release, namespace, Deployment 이름에 맞게 명령을 조정하세요. 전체 설정은 [Helm 가이드](https://github.com/AgentBull/ankole/blob/main/tools/deploy/helm/ankole-agent/README.md)를 참조하세요.

## 검증과 복구

- Console의 `default` 테넌트에서 원래 Agent, identity provider, signal binding, Job을 확인하세요. 기존 Agent에 WorkerProvider가 할당되어야 합니다. 기본 provider는 새 Agent의 배치 선택에만 쓰입니다.
- Agent 하나를 활성화하고 실제 파일 작업과 Job을 실행하세요. 이전 Home 파일, Codex 스레드 복구, Skill, Automation 스크립트, 드라이브 업로드·다운로드, 첨부 전송을 확인한 후 다른 Agent와 예약 작업을 복구하세요.
- migration 실패 시 이전 제어면을 중지한 상태로 Compose `migrate` 또는 Kubernetes `db-migrate` 로그를 확인하세요. 키, 자격 증명, 이름 충돌, 저장소 권한을 수정하고 같은 버전의 migration을 다시 실행하세요.
- 보고서에 나온 삭제된 Agent의 디렉터리에서 새 Agent를 만들지 않습니다. 파일이 더 필요 없다고 확인한 후에만 이전 디렉터리나 volume을 삭제하세요.
- 롤백하려면 새 제어면, `ankole-function-runtime`, Worker를 모두 중지하고 업그레이드 전 PostgreSQL DB(구성된 `BASE_DB_URLS` 샤드 포함), 파일 저장소, Home, 설정, 원래 키를 함께 복원한 뒤 해당 이전 이미지를 시작하세요. `helm rollback`이나 이미지 변경만으로는 파괴적인 패스워드리스 변환이나 schema 이전을 되돌릴 수 없으며, 별도로 내보내지 않은 새 쓰기를 보존할 수 없습니다.

후속 운영은 [Worker](../worker-management/), [드라이브 저장소](../drive-storage/), [재해 복구](../disaster-recovery/)를 참조하세요.
