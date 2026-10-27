---
title: Worker
description: Console에서 각 Agent의 Worker를 확인하고, control plane이 이를 관리하는 방식을 이해하고, 흔한 장애를 해결하는 방법.
section: User guide
order: 52
---

각 Agent는 전용 Worker와 `/workspace` 아래의 영구 Home을 가집니다. Worker provider의 플랫폼 유형과 YAML 설정은 Console에서 구성하며 자격 증명은 별도 암호화 필드에 저장합니다. Agent에 연결할 provider는 생성 시점에 결정되며 나중에 다른 provider로 바꿀 수 없으므로, 다른 인스턴스 사양이 필요하면 별도의 provider를 등록하세요.

## Worker pool

Worker provider 하나가 하나의 Worker pool을 정의합니다. 각 pool은 사이트 범위에 속하며 플랫폼 유형, YAML 구성, 별도로 암호화된 자격 증명을 가집니다. 서로 다른 테넌트의 Agent들이 같은 pool을 선택할 수 있지만, 실행 시에는 Agent마다 전용 Worker 인스턴스, 영구 Home, 로컬 캐시, Worker 인증 자격 증명이 완전히 분리됩니다.

1. **Console → Settings → Worker providers**에서 **New Worker provider**를 선택합니다.
2. 플랫폼 유형을 고르고 제공된 YAML 예시를 바탕으로 컨테이너 이미지, 인스턴스 사양, 스토리지, 연결 엔드포인트를 작성합니다.
3. 별도의 자격 증명 입력란에 플랫폼 인증 키를 넣어 저장한 뒤 연결 테스트를 실행합니다.
4. pool 하나를 사이트 기본값으로 지정하거나, 새 Agent를 만들 때 사용할 pool을 직접 선택합니다(둘 다 없으면 Agent 생성이 실패합니다).

사이트 전체에서 기본 pool은 최대 하나만 지정할 수 있습니다. 기본 pool을 바꾸더라도 이후 새로 만드는 Agent에만 적용되며, 기존 Agent는 처음 할당된 provider를 그대로 유지합니다. 사양이나 리전이 다른 환경이 필요하면 같은 플랫폼 유형이라도 pool을 여러 개 나누어 만들 수 있습니다. 한번 생성된 뒤에는 provider ID, 플랫폼 유형, 스토리지 위치 및 기존 Agent의 provider 할당을 변경할 수 없으며, 참조 중인 Agent Worker 행이 하나라도 남아 있는 pool은 삭제할 수 없습니다.

pool은 지정된 플랫폼 위에서 인스턴스 수명 주기를 관리하며, 한 Agent의 컴퓨터를 다른 Agent에 재할당하지 않습니다. Agent 생성 절차는 [Agents](../agents/)를, 내부 실행 및 복구 메커니즘은 [Agent Computer Worker](../agent-computer-worker/)를 참조하세요.

## Agent마다 Worker 하나

새 Agent를 만들 때는 선택한 provider 정보와 Worker 메타데이터 행만 저장할 뿐 실제 인스턴스를 즉시 띄우지는 않습니다. 이후 환경 도구나 Codex Job, Automation Job 실행이 실제로 요청될 때 비로소 control plane이 Worker를 기동합니다. 일반 채팅 대화와 Workflow 모델 호출은 control plane에서 직접 처리되므로 Worker가 떠 있지 않아도 정상 진행됩니다.

같은 Agent 안에서 실행되는 여러 Session과 Job은 동일한 컴퓨터와 Home을 공유하되 Home 내부의 서로 다른 하위 workspace 디렉터리를 사용합니다. 열려 있는 환경 workspace 하나와 실행 중인 Codex turn 하나는 각각 Worker slot을 1개씩 차지하며, 단일 Worker의 전체 슬롯 용량은 `ANKOLE_MAX_CONCURRENT_SLOTS`로 결정됩니다. 새 pool을 추가하거나 다른 Agent를 더 만든다고 해서 특정 Agent의 Worker slot 수나 별도 설정인 Background Agent Job 동시 실행 한도가 늘어나지는 않습니다.

## Worker 보기

**Console → Workers** 화면에서는 각 Agent의 할당 provider, 현재 상태, 슬롯 부하, 최근 heartbeat, 플랫폼 오류 메시지를 확인할 수 있습니다.

| 상태 | 의미 |
| --- | --- |
| `absent` | 실행 중인 인스턴스가 없으며 작업이 들어올 때 새로 생성됨 |
| `starting` | 새 generation이 기록되었고 인스턴스 생성 또는 연결 승인을 기다리는 중 |
| `ready` | 연결이 완료되어 Turn 작업을 받을 수 있는 상태 |
| `stale` | 기존 연결이 끊어진 상태 |
| `paused` | 프로세스와 메모리 상태를 보존한 채 일시 중지됨 |
| `draining` | 유휴 반납 또는 새 설정 교체를 위해 기존 작업 종료를 기다리는 중 |
| `deleting` | 인스턴스와 연결된 스토리지 삭제 완료를 기다리는 중 |

인스턴스 생성 요청이 타임아웃되면 동일한 generation 번호로 기동을 재시도합니다. 이전 요청의 성공 여부가 불확실한 상태에서는 두 번째 쓰기 인스턴스를 중복 생성하지 않고 확인될 때까지 대기합니다. 설정을 성급히 고치기 전에 화면의 **Reason** 필드를 먼저 확인하세요.

## Provider와 스토리지

플랫폼별 세부 제약, 자격 증명, 네트워크 구성, SQLite 캐시 요건은 [WorkerProvider와 캐시 디스크](../worker-providers/)에서 다루며, 1.x 환경에서 이전하는 절차는 [1.0에서 2.0으로 업그레이드](../upgrade-to-2/)를 참조하세요.

| 유형 | 영구 Home 저장 위치 | 유휴 시 처리 방식 |
| --- | --- | --- |
| Docker | Agent별 전용 로컬 볼륨 | 컨테이너 삭제 |
| Kubernetes | 전용 PVC 또는 공유 PVC 내 하위 디렉터리 | Pod 삭제 |
| Cloudflare | R2 디렉터리 스냅샷 백업 | 백업 완료 후 컨테이너 삭제 |
| Vercel | Agent별 전용 Drive | 샌드박스 삭제 |
| Lambda MicroVMs | EFS 내 Agent 디렉터리 | 메모리를 보존한 채 일시 중지 |
| Function Compute | Agent별 AgenticSpace 또는 OSS prefix | 메모리를 보존한 채 일시 중지 |

Vercel의 `sessionTimeoutSeconds`는 사용 중인 계정의 허용 한도 안에서 지정하세요(기본값은 `86400`초이며, 45분 제한 계정이라면 `2700`초로 설정). AWS Lambda 환경에서는 실행 중이거나 일시 중지된 Worker뿐 아니라 스토리지 삭제용 보조 인스턴스가 사용할 메모리 할당량까지 여유를 두어야 합니다. Alibaba Function Compute에서는 일시 중지 후 재개할 때 Worker 이미지 안의 OSS 재연결 도우미를 실행하므로, 반드시 버전이 일치하는 Worker 이미지와 control plane을 함께 배포하세요.

영구 Home 데이터는 인스턴스가 삭제되거나 이미지가 업데이트되어도 그대로 유지됩니다. Codex 스레드는 `/workspace/.codex`에, SQLite 캐시는 `/var/cache/ankole/codex`에 분리 저장되며, 재구축 작업을 실행하면 캐시만 초기화됩니다. 다만 Docker 로컬 볼륨은 호스트 장비 장애 시 함께 유실될 수 있고, Cloudflare에서도 컨테이너가 비정상 강제 종료되면 마지막 백업 이후 변경분이 유실될 수 있으므로 Home과 [Agent 드라이브](../file-management/)를 모두 주기적으로 백업하세요.

## 해제, 교체, 삭제

- 유휴 회수 대기 시간은 provider YAML의 `idleReleaseAfter`로 지정합니다. 6개 플랫폼 모두 기본값은 `15m`이며, `never`로 설정해 유휴 회수를 끌 수도 있습니다.
- 메모리 보존형 일시 중지를 지원하는 provider는 유휴 상태가 되면 Worker를 일시 중지하고, 나머지 provider는 인스턴스를 삭제하되 영구 스토리지와 구성된 캐시 볼륨은 남겨 둡니다.
- 컨테이너 이미지나 인스턴스 사양을 바꾸면 Worker가 유휴 상태가 될 때 교체되며, 프로토콜 버전이 바뀌면 즉시 교체됩니다. 이전 설정으로 일시 중지되어 있던 인스턴스는 새 작업을 받기 전에 먼저 새 설정으로 교체됩니다.
- `agent_computer.worker.ready_timeout`의 기본값은 `600`초입니다. 이미 연결이 관측된 적 있는 인스턴스에 대해서만 재구축을 수행하며, 생성 결과가 아직 불확실한 인스턴스를 임의로 종료된 것으로 간주하지 않습니다.
- Agent를 삭제하면 먼저 모든 실행 인스턴스가 완전히 내려간 것을 확인한 뒤 Home과 캐시 스토리지를 지우고, 맨 마지막에 Worker 메타데이터 행을 삭제합니다. Agent UID는 서버가 매번 새로 발급하며 절대 재사용하지 않습니다.

## 준비되지 않은 Worker 확인

Worker가 `ready` 상태로 올라오지 않으면 먼저 provider 자격 증명, 스토리지 마운트, 플랫폼 할당량, `endpoints` 주소를 점검하세요. 플랫폼별로는 Docker의 `ANKOLE_DOCKER_GID`, Kubernetes의 RBAC Role·Pod 이벤트·PVC 바인딩, Cloudflare의 이미지 매핑과 어댑터 토큰, Lambda의 이미지 빌드 상태·빌드 IAM 역할·VPC 커넥터·EFS 연결을 중점적으로 확인합니다.

수동 조치가 필요할 때는 provider 레이블로 대상 인스턴스가 맞는지 먼저 확인하고, 내리기 전에 컨테이너 로그를 확보하세요. Kubernetes에서는 Pod가 정상 종료될 때까지 기다려야 하며, 노드 장애 상황에서 강제 삭제나 유예 시간 `0`(`--grace-period=0`)으로 우회해서는 안 됩니다. Docker에서는 다음 순서로 정상 중지한 뒤 제거합니다.

```bash
docker stop CONTAINER_NAME
docker rm CONTAINER_NAME
```

기존 컨테이너가 내려가면 다음 작업 요청 시 control plane이 새 인스턴스를 띄우며, 기존 Home과 캐시 볼륨은 그대로 재연결됩니다. 도중에 끊긴 Turn 작업은 각 경로의 재시도 정책에 따라 처리됩니다. 만약 상태가 `ready`인데도 작업이 대기열에 머문다면 현재 슬롯 사용량과 Turn 동시 실행 한도를 대조해 보세요. `ANKOLE_MAX_CONCURRENT_SLOTS`는 provider YAML 내 환경 설정이므로 값을 수정하면 유휴 시점에 Worker가 교체되면서 반영됩니다. 자세한 용량 계산은 [성능 조정](../performance-tuning/)을 참조하세요.
