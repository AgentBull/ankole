---
title: Worker
description: Console에서 Agent Computer Worker의 상태, 용량, heartbeat를 확인하고 흔한 장애를 해결하는 방법.
section: User guide
order: 52
---

Agent Computer Worker는 Agent가 실제로 작업을 수행하는 컴퓨터입니다. control plane은 지속적인 도메인 상태와 감독을 소유하며 작업을 관리하고 배정합니다. Worker는 worker 로컬 상태에서 Agent, 도구, 파일 작업을 실행합니다. 하나의 배포 인스턴스가 하나 이상의 Worker에 연결될 수 있습니다.

## Worker 보기

**Console → Workers**를 여세요. 각 행에 다음이 표시됩니다:

- **State:** Worker가 새 작업을 받을 수 있는지 여부;
- **Slots:** 동시에 실행할 수 있는 Agent 턴의 최대 수;
- **Active turns:** 지금 실행 중인 턴;
- **Last heartbeat:** control plane이 Worker 상태를 마지막으로 받은 시각;
- **Version:** Worker의 Ankole 버전.

control plane은 Worker가 하나 이상 ready인 동안 작업을 배정할 수 있습니다. 최근 heartbeat가 없는 Worker는 보통 컨테이너가 중지되었거나, 네트워크 문제가 있거나, Worker와 control plane 사이에 인증 실패가 있는 경우입니다.

**Browse files**를 선택해 해당 Worker의 Agent 파일을 검사하세요. 절차는 [File management](../file-management/)를 참조하세요.

## ready Worker가 없을 때

다음 항목을 순서대로 확인하세요:

1. Worker 컨테이너 또는 Pod가 실행 중입니다.
2. Worker 로그에 control-plane 주소, 인증, 연결 오류가 없습니다.
3. control plane과 Worker가 같은 `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY`를 사용합니다.
4. Worker가 control plane Runtime Fabric 주소에 도달할 수 있습니다.
5. control plane과 Worker가 호환되는 Ankole 버전을 사용합니다.

Docker Compose:

```bash
docker compose ps agent-computer-worker
docker compose logs agent-computer-worker
```

Kubernetes:

```bash
kubectl -n ankole get pods
kubectl -n ankole logs deployment/ankole-agent-computer-worker
```

정확한 리소스 이름은 릴리스 이름에 따라 달라집니다. 명령이 객체를 찾지 못하면 `kubectl -n ankole get deployments`로 찾으세요.

## Worker는 ready인데 작업이 대기 상태로 남을 때

**Active turns**와 **Slots**를 비교하세요. 모든 Worker가 모든 슬롯을 사용하면 새 작업은 용량을 기다립니다.

짧은 대기는 정상입니다. 지속적인 대기열이면 먼저 LLM Provider가 느리지 않은지 확인하세요. 그런 다음 Worker를 추가할지, Worker당 용량을 늘릴지, 동시 작업을 줄일지 결정하세요. [Performance tuning](../performance-tuning/)을 참조하세요.

## Worker 재시작

Worker가 응답하지 않고 로그가 복구할 수 없음을 보여 줄 때만 재시작하세요.

Docker Compose:

```bash
docker compose restart agent-computer-worker
```

Kubernetes:

```bash
kubectl -n ankole rollout restart deployment/ankole-agent-computer-worker
```

재시작은 해당 Worker에서 실행 중인 턴을 중단시킵니다. control plane은 재시도 정책에 따라 그 턴들을 처리합니다. 재시작 후 **Console → Conversations** 또는 **Background Agent Jobs**에서 결과를 확인하세요.