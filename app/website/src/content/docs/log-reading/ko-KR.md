---
title: 로그 읽기
description: Docker Compose, Kubernetes 또는 Cloudflare에서 Ankole 로그를 가져오고, 이벤트 이름과 컨텍스트 필드로 장애를 찾는 방법.
section: User guide
order: 57
---

Console이 실패한 요청만 표시하거나 Agent가 답변하지 않을 때, 로그는 장애가 control plane에 있는지, Worker에 있는지, 채팅 채널에 있는지, LLM Provider에 있는지 보여 줄 수 있습니다.

Ankole은 기본적으로 구조화된 JSON 로그를 작성합니다. 각 레코드는 심각도, 이벤트 이름, 메시지, 관련 컨텍스트를 가집니다. 먼저 이벤트를 찾으세요. 그런 다음 Agent UID, Provider ID 또는 실패 이유로 레코드를 좁히세요.

## 로그 가져오기

Docker Compose:

```bash
docker compose logs --since 30m control-plane
docker ps -a --filter label=ankole.installation=ankole
docker logs --since 30m CONTAINER_NAME
```

control plane은 Agent마다 Worker 컨테이너를 하나 만듭니다. 두 번째 명령이 그 목록을 보여 주며, 레이블 `ankole.agent-uid`가 각 컨테이너의 Agent를 나타냅니다.

Kubernetes:

```bash
kubectl -n ankole logs deployment/ankole-control-plane --since=30m
kubectl -n ankole get pods -l ankole.io/installation=ankole
kubectl -n ankole logs POD_NAME -c worker --since=30m
```

리소스 이름은 릴리스 이름에 따라 달라질 수 있습니다. 명령이 객체를 찾지 못하면 먼저 `kubectl -n ankole get deployments`를 실행하세요. Worker Pod 레이블 `ankole.io/installation`의 값은 `worker.installation`이 다른 값을 설정하지 않는 한 릴리스 이름이며, Pod 어노테이션 `ankole.io/agent-uid`가 그 Pod의 Agent를 나타냅니다.

Cloudflare(`tools/deploy/cloudflare/agent-workers`에서 실행):

```bash
bunx wrangler tail ankole-agent-workers
```

어댑터는 Worker의 시작, 중지, 스냅샷마다 JSON 한 줄을 씁니다.

Agent의 Worker가 시작되지 않으면 **Console → Workers**에 그 상태와 그 백엔드가 보고한 최신 이유가 표시됩니다. [Workers](../worker-management/)를 참조하세요.

문제를 재현하기 전에 대략적인 시간, Agent, 채팅 채널, 사용자 작업을 기록하세요. 그러면 프로세스 시작부터 읽는 대신 작은 시간 창만 검사할 수 있습니다.

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

- `severity`는 레코드가 얼마나 심각한지 보여 줍니다.
- `event`는 검색과 집계에 가장 좋은 필드입니다.
- `message`는 읽을 수 있는 설명을 제공합니다.
- 다른 필드는 Agent, 채널, Job 또는 요청을 식별합니다.

오류 근처의 warning과 정보 레코드가 전체 시퀀스를 보여 주는 경우가 많습니다. 마지막 줄만 복사하지 마세요. 실패 전후의 관련 레코드를 모두 유지하세요.

## 유용한 검색 순서

1. 로그를 문제가 발생한 시간으로 제한합니다.
2. `error`, `warning` 또는 Console의 오류 코드를 검색합니다.
3. 관련 이벤트를 찾은 후 Agent UID(그 Agent의 Worker ID이기도 함), Provider ID 또는 채팅 어댑터로 필터링합니다.
4. 레코드를 **Console → Conversations** 또는 **Background Agent Jobs**의 상태와 비교합니다.

로그에는 복호화된 모델 자격 증명, 채널 비밀, Worker 자격 증명이 포함되지 않습니다. 지원을 위해 로그를 공유하기 전에도 사용자 메시지, URL, 기타 비즈니스 데이터가 있는지 여전히 확인하세요.

## 로그 상세 수준 임시 증가

`ANKOLE_LOG_LEVEL`은 상세 수준을 제어하며 기본값은 `info`입니다. 어려운 문제를 재현하려면 일시적으로 `debug`로 설정하고 관련 서비스를 재시작할 수 있습니다.

재현 후 이전 값으로 복원해 계속해서 늘어나는 로그를 피하세요.

모든 변수는 [배포 환경 참조](../environment-variables/)를 참조하세요.

증상별로 정리한 확인 항목은 [FAQ](../faq/)를 참조하세요.
