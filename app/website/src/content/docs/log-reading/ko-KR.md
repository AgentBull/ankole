---
title: 로그 읽기
description: Docker Compose, Kubernetes 또는 Cloudflare에서 Ankole 로그를 가져오고, 이벤트 이름과 컨텍스트 필드로 장애를 찾는 방법.
section: User guide
order: 57
---

Console에 요청 실패만 표시되거나 Agent가 아무 응답도 하지 않을 때는 로그를 확인해 장애 원인이 control plane, Worker, 채팅 채널, LLM Provider 중 어디에 있는지 파악할 수 있습니다.

Ankole은 기본적으로 구조화된 JSON 형식으로 로그를 남기며, 각 레코드에는 심각도, 이벤트 이름, 메시지, 관련 컨텍스트가 담깁니다. 먼저 이벤트 이름으로 관련 로그를 찾은 뒤, Agent UID나 Provider ID, 실패 사유로 대상을 좁혀 나가세요.

## 로그 가져오기

Docker Compose 환경에서는 다음 명령을 사용합니다.

```bash
docker compose logs --since 30m control-plane
docker ps -a --filter label=ankole.installation=ankole
docker logs --since 30m CONTAINER_NAME
```

control plane은 Agent마다 전용 Worker 컨테이너를 하나씩 생성합니다. 두 번째 명령으로 Worker 컨테이너 목록을 조회할 수 있으며, `ankole.agent-uid` 레이블에서 각 컨테이너가 어느 Agent에 속하는지 확인할 수 있습니다.

Kubernetes 환경에서는 다음 명령을 사용합니다.

```bash
kubectl -n ankole logs deployment/ankole-control-plane --since=30m
kubectl -n ankole get pods -l ankole.io/installation=ankole
kubectl -n ankole logs POD_NAME -c worker --since=30m
```

리소스 이름은 Helm 릴리스 이름에 따라 달라질 수 있으므로, 위 명령으로 객체를 찾지 못하면 먼저 `kubectl -n ankole get deployments`를 실행해 실제 이름을 확인하세요. Worker Pod의 `ankole.io/installation` 레이블 값은 `worker.installation`을 별도로 지정하지 않는 한 릴리스 이름과 같으며, `ankole.io/agent-uid` 어노테이션에 대상 Agent UID가 기록됩니다.

Cloudflare 환경(`tools/deploy/cloudflare/agent-workers` 디렉터리에서 실행)에서는 다음 명령을 사용합니다.

```bash
bunx wrangler tail ankole-agent-workers
```

어댑터는 Worker가 시작되거나 중지될 때, 그리고 스냅샷을 찍을 때마다 JSON 로그를 한 줄씩 남깁니다.

만약 Agent의 Worker 자체가 기동되지 않는다면 **Console → Workers** 화면에서 현재 상태와 백엔드가 보고한 최신 사유를 먼저 확인할 수 있습니다. 자세한 내용은 [Workers](../worker-management/)를 참조하세요.

문제를 재현하기 전에는 대략적인 시각, 대상 Agent, 채팅 채널, 수행한 작업을 메모해 두세요. 그러면 프로세스 시작 시점부터 전체 로그를 뒤지는 대신 해당 시간대만 빠르게 좁혀서 살펴볼 수 있습니다.

## 레코드 하나 읽기

```json
{
  "severity": "warning",
  "event": "signals.webhook.dispatch_failed",
  "message": "provider webhook dispatch failed",
  "handler_id": "lark",
  "reason": "..."
}
```

- `severity`: 로그의 심각도 수준을 나타냅니다.
- `event`: 검색이나 집계를 수행할 때 가장 기준이 되는 이벤트 식별자입니다.
- `message`: 사람이 읽을 수 있는 요약 설명입니다.
- 그 밖의 필드: 대상 Agent, 채널, Job, 요청 등의 컨텍스트를 식별합니다.

실제 원인을 파악할 때는 오류 직전과 직후에 찍힌 `warning` 및 `info` 레코드에 전체 흐름이 드러나는 경우가 많습니다. 따라서 마지막 오류 줄 하나만 떼어 보지 말고, 실패 전후의 연관 레코드를 함께 보관해 확인하세요.

## 유용한 검색 순서

1. 문제가 발생한 시간대로 로그 조회 범위를 먼저 좁힙니다.
2. `error`, `warning` 또는 Console에 표시된 오류 코드를 검색합니다.
3. 관련 이벤트를 찾으면 Agent UID(해당 Agent의 Worker ID와 동일), Provider ID 또는 채팅 어댑터 기준으로 필터링합니다.
4. 찾은 로그 레코드를 **Console → Conversations** 또는 **Background Agent Jobs**에 표시된 상태와 대조합니다.

로그에는 복호화된 모델 자격 증명, 채널 시크릿, Worker 자격 증명이 기록되지 않습니다. 다만 기술 지원을 위해 로그를 외부에 공유하기 전에는 사용자 메시지나 내부 URL, 그 밖의 업무 데이터가 포함되어 있지 않은지 반드시 검토하세요.

## 로그 상세 수준 임시 증가

로그 상세 수준은 `ANKOLE_LOG_LEVEL` 환경 변수로 제어하며 기본값은 `info`입니다. 원인을 찾기 까다로운 문제를 재현해야 할 때는 값을 일시적으로 `debug`로 바꾼 뒤 관련 서비스를 재시작해 보세요.

재현과 분석이 끝나면 로그가 과도하게 쌓이지 않도록 다시 원래 수준으로 되돌려 두세요.

전체 환경 변수 목록은 [배포 환경 참조](../environment-variables/)에서, 증상별 점검 순서는 [FAQ](../faq/)에서 확인할 수 있습니다.
