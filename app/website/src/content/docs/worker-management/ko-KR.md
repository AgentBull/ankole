---
title: Worker
description: Console에서 각 Agent의 Worker를 확인하고, control plane이 이를 관리하는 방식을 이해하고, 흔한 장애를 해결하는 방법.
section: User guide
order: 52
---

각 Agent는 전용 Worker와 `/workspace`의 영구 Home을 가집니다. Console에서 Worker provider의 유형과 YAML 설정을 지정하고 자격 증명은 따로 저장합니다. Agent 생성 시 provider를 선택하며 이후에는 바꿀 수 없습니다. 인스턴스 사양이 다르면 별도 provider를 만드세요.

## Worker pool

Worker provider 하나가 Worker pool 하나를 정의합니다. pool에는 플랫폼 유형, YAML 설정과 별도로 암호화한 자격 증명이 있으며 site에 속합니다. 서로 다른 tenant의 Agent가 같은 pool을 선택할 수 있지만 각 Agent는 전용 Worker, 영구 Home, 캐시와 Worker 자격 증명을 유지합니다.

1. **Console → Settings → Worker providers**에서 **New Worker provider**를 선택합니다.
2. 유형을 선택하고 YAML 예제로 이미지, 인스턴스 사양, 스토리지와 연결 주소를 설정합니다.
3. 별도 자격 증명 필드에 플랫폼 키를 입력하고 저장한 뒤 연결 검사를 실행합니다.
4. pool 하나를 기본값으로 지정하거나 Agent 생성 시 pool을 선택합니다. 둘 다 없으면 Agent 생성이 실패합니다.

site에는 기본 pool이 최대 하나 있습니다. 기본값을 바꾸면 이후 생성하는 Agent에만 적용되며 기존 Agent는 선택한 provider를 유지합니다. 사양이나 위치가 다르면 별도 pool을 만드세요. 같은 유형의 pool도 여러 개 만들 수 있습니다. 생성 후 provider ID, 유형, 스토리지 위치와 Agent의 provider 선택은 바꿀 수 없습니다. Agent Worker 행이 참조하는 pool은 삭제할 수 없습니다.

pool은 선택한 플랫폼에서 인스턴스를 관리하며 한 Agent의 컴퓨터를 다른 Agent에 할당하지 않습니다. 생성은 [Agents](../agents/), 실행과 복구는 [Agent Computer Worker](../agent-computer-worker/)를 참조하세요.

## Agent마다 Worker 하나

Agent 생성 시 provider 선택과 Worker 행을 저장하며 인스턴스는 시작하지 않습니다. 환경 도구, Codex Job 또는 Automation Job이 필요할 때 control plane이 Worker를 시작합니다. 주 대화와 Workflow 모델 호출은 control plane에서 실행되므로 Worker 없이도 진행할 수 있습니다.

같은 Agent의 Session과 Job은 Home 안의 별도 workspace를 사용하며 컴퓨터와 Home을 공유합니다. 열린 환경 workspace와 실행 중인 Codex turn은 각각 Worker slot 하나를 사용합니다. `ANKOLE_MAX_CONCURRENT_SLOTS`는 해당 Worker의 용량을 설정합니다. pool이나 다른 Agent를 추가해도 기존 Agent의 Worker slot이나 별도로 설정하는 Background Agent Job 동시 실행 한도는 늘어나지 않습니다.

## Worker 보기

**Console → Workers**에서 Agent, provider, 상태, 부하, heartbeat와 최근 플랫폼 오류를 확인합니다.

| 상태 | 의미 |
| --- | --- |
| `absent` | 인스턴스 없음. 필요할 때 생성 |
| `starting` | generation 저장 완료. 생성 또는 접속 승인을 기다림 |
| `ready` | 연결되어 Turn 실행 가능 |
| `stale` | 이전 연결이 끊김 |
| `paused` | 프로세스와 메모리를 유지하며 일시 중지 |
| `draining` | 해제 또는 교체를 기다림 |
| `deleting` | 인스턴스와 스토리지 삭제를 기다림 |

생성 요청이 시간 초과되면 같은 generation으로 재시도합니다. 결과가 불확실하면 기다리며 두 번째 쓰기 인스턴스를 만들지 않습니다. 설정을 바꾸기 전에 **Reason**을 확인하세요.

## Provider와 스토리지

플랫폼 제한, 자격 증명, 네트워크, SQLite 캐시는 [WorkerProvider와 캐시 디스크](../worker-providers/)를 참조하세요. 이전 배포는 [1.0에서 2.0으로 업그레이드](../upgrade-to-2/)를 참조하세요.

| 유형 | 영구 Home | 유휴 시 동작 |
| --- | --- | --- |
| Docker | Agent별 로컬 volume | 컨테이너 삭제 |
| Kubernetes | 전용 PVC 또는 공유 PVC의 디렉터리 | Pod 삭제 |
| Cloudflare | R2 디렉터리 백업 | 백업 후 삭제 |
| Vercel | Agent별 Drive | sandbox 삭제 |
| Lambda MicroVMs | EFS의 Agent 디렉터리 | 메모리를 유지하며 중지 |
| Function Compute | Agent별 AgenticSpace 또는 OSS prefix | 메모리를 유지하며 중지 |

Vercel `sessionTimeoutSeconds`는 계정 제한 내에서 설정하세요. 기본값은 86400초이며, 45분 제한이면 2700초로 설정합니다. Lambda는 실행 중이거나 일시 중지된 Worker 외에 스토리지 삭제용 인스턴스의 메모리 할당량도 확보해야 합니다. Function Compute 재개는 Worker 이미지의 OSS 재연결 도우미를 사용하므로 버전이 일치하는 Worker 이미지와 control plane을 함께 배포하세요.

Home은 인스턴스 삭제와 이미지 변경 후에도 유지됩니다. Codex 스레드는 `/workspace/.codex`, SQLite 캐시는 `/var/cache/ankole/codex`에 있습니다. 재구축은 캐시만 삭제합니다. Docker 로컬 volume은 호스트 손실을 견디지 못합니다. Cloudflare가 강제로 중지되면 마지막 백업 이후 쓰기가 손실될 수 있습니다. Home과 [Agent 드라이브](../file-management/)를 모두 백업하세요.

## 해제, 교체, 삭제

- provider YAML의 `idleReleaseAfter`를 설정합니다. 6종 모두 기본값은 `15m`이며 `never`도 설정할 수 있습니다.
- 메모리 중지를 지원하는 provider는 유휴 Worker를 중지합니다. 나머지는 인스턴스를 삭제하고 영구 스토리지와 설정된 캐시 volume을 유지합니다.
- 이미지나 인스턴스 설정 변경은 유휴 시 교체합니다. 프로토콜 변경은 즉시 교체합니다. 오래된 중지 인스턴스는 작업을 받기 전에 교체합니다.
- `agent_computer.worker.ready_timeout` 기본값은 600초입니다. 이미 관측한 인스턴스만 재구축하며 결과가 불확실한 생성을 종료로 간주하지 않습니다.
- Agent 삭제는 모든 인스턴스가 사라진 뒤 Home과 캐시를 삭제하고 마지막에 Worker 행을 삭제합니다. Agent UID는 서버에서 생성하며 재사용하지 않습니다.

## 준비되지 않은 Worker 확인

provider 자격 증명, 스토리지, 용량, `endpoints`를 확인하세요. Docker는 `ANKOLE_DOCKER_GID`, Kubernetes는 Role, Pod 이벤트와 PVC, Cloudflare는 이미지 설정과 token, Lambda는 이미지 빌드, 빌드 역할, VPC connector와 EFS 연결을 확인합니다.

provider 라벨로 대상을 확인하고 중지 전에 로그를 읽으세요. Kubernetes는 정상 삭제가 끝날 때까지 기다려야 하며 노드 장애를 grace 0으로 우회하면 안 됩니다. Docker는 먼저 중지한 뒤 삭제합니다.

```bash
docker stop CONTAINER_NAME
docker rm CONTAINER_NAME
```

필요하면 control plane이 새 인스턴스를 만듭니다. Home과 캐시 volume은 남습니다. 실행 중인 Turn은 중단되며 각 재시도 정책을 따릅니다. ready인데도 대기한다면 부하와 Turn 용량을 비교하세요. `ANKOLE_MAX_CONCURRENT_SLOTS`는 provider YAML의 환경 설정이며 변경 후 유휴 시 교체됩니다. [성능 조정](../performance-tuning/)을 참조하세요.
