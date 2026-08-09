---
title: Audit trail(감사 기록)
description: Ankole의 audit 표면 읽는 방법 — Brain audit log, control-plane 구조화 log, 그리고 각 표면이 누가 무엇을 언제 변경했는지를 어떻게 기록하는지 설명합니다.
section: Developer guide
order: 125
---

audit trail은 누가 무엇을 언제 변경했는지에 대한 내구성 있는 기록입니다. Ankole에는 audit log가 하나만 있는 것이 아닙니다. 여러 표면이 있으며, 각 표면은 서로 다른 subsystem이 소유하고, 각자에게 중요한 결정을 기록합니다. 이 페이지는 운영자를 위한 표면 지도입니다 — 각 표면이 무엇을 기록하는지, 읽는 방법, 함께 사용하는 방법을 다룹니다.

핵심 속성을 먼저 밝히면, 모든 audit 표면은 **내구성 있는 PostgreSQL 상태 또는 구조화된 log**이며, 휘발성 메트릭이 아닙니다. 기록된 행은 이를 기록한 프로세스가 사라져도 남습니다. 기록되지 않은 행은 재구성할 수 없습니다.

## Brain 감사 로그

가장 구조화된 audit 표면입니다. 모든 Brain 지식 쓰기 — 새 항목, 블록 편집, 삭제, 복원 — 는 append-only audit 행을 만듭니다. 읽는 방법은 다음과 같습니다.

```bash
curl https://ankole.example.com/api/v1/brain/audit-log \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

또는 하나의 항목으로 좁힐 수 있습니다.

```bash
curl https://ankole.example.com/api/v1/brain/entries/<id>/audit-log \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

각 행은 누가 변경했는지(actor), 어떤 종류의 actor인지(human, agent, dreaming, source_learning, mechanical), 어떤 작업이 수행되었는지, 그리고 언제인지를 기록합니다. 복원(restoration) 자체도 감사 대상입니다 — 이전 상태를 복원하면 새 audit 행이 추가되며, 되돌려지는 변경을 만든 행은 지워지지 않습니다.

이것이 “왜 agent가 그렇게 믿는가?”에 대한 표면입니다 — 답은 모델의 현재 출력이 아니라 audit trail에 있습니다.

## AuthZ grant 기록

모든 permission grant는 `permission_grants`의 durable 행입니다. grant의 `principal_uid` 또는 `group_id`가 소유자를 지정하고, `resource_pattern`과 `action`이 허용 대상을 지정하며, timestamp가 생성 시점과 마지막 업데이트 시점을 기록합니다. grant 전용 별도 audit log는 없습니다 — grant는 대부분 추가(append)만 되고 변경이 행 업데이트로 보이기 때문에 grant 테이블 자체가 기록입니다.

grant는 `GET /principals/:uid/grants`와 `GET /principal-groups/:name/grants`로 읽으십시오. 추가되었다가 나중에 제거된 grant는 테이블 히스토리에 나타납니다(PostgreSQL point-in-time recovery를 유지하는 경우). 지금 존재하는 grant가 시스템이 강제하는 것입니다.

## 구조화된 control-plane log

control plane은 안정적인 형식의 구조화된 log를 내보냅니다 — event 이름, 사람이 읽을 수 있는 메시지, 구조화된 필드, 그리고 `debug`부터 `error`까지의 심각도입니다. 이것이 운영 event에 대한 audit 표면입니다.

- provider 호출(어떤 provider, 어떤 모델, 결과)
- worker lifecycle(worker 시작, turn 시작, turn 완료 또는 오류)
- signal event(무엇이 도착했는지, 필터링되었는지 수락되었는지)
- schedule 실행(언제, 어떤 결과)

log는 PostgreSQL이 아닙니다 — log ingester가 받는 모든 것이 log입니다. 감사에 필요하다면 실시간으로 내구성 있는 저장소(log index, S3 archive)로 전송하십시오. 전송되지 않은 log는 프로세스와 함께 사라집니다.

log 설정은 [Environment variables](../environment-variables/)를, 진단 방법은 [Read Ankole logs](../log-reading/)를 참조하십시오.

## actor-event 및 delivery 행

모든 actor event(session을 구동하는 durable inbox)와 모든 delivery 시도는 PostgreSQL의 행입니다. 이들은 일반적으로 감사용으로 읽히지는 않습니다 — 운영 상태이기 때문입니다 — 그러나 시스템이 무엇을 하도록 요청받았고 전달되었는지에 대한 기록을 형성합니다. Console의 `/background-agent-jobs/:id` 라우트는 job의 `attempts`와 `error`를 보여 주고, `/ai-gateway/conversations` 라우트는 turn이 수행한 model 호출을 보여 줍니다.

## 함께 사용하기

실제 감사 질문은 보통 둘 이상의 표면에 걸쳐 있습니다.

| 질문 | 확인할 곳 |
|---|---|
| “왜 agent가 X를 믿는가?” | Brain 감사 로그 |
| “누가 이 agent에게 Y 작업 권한을 주었는가?” | `permission_grants` + `/principals/:uid/grants` |
| “이 turn에서 agent가 무엇을 했는가?” | `/ai-gateway/conversations/:id/messages` |
| “schedule이 실행되었는가?” | `/cron-schedules/:id/runs` |
| “job의 실패가 재시도되었는가?” | `/background-agent-jobs/:id` (`attempts`, `error`) |
| “그 시점에 worker가 무엇을 로그했는가?” | 구조화된 control-plane log |

## 이 가이드가 아닌 것

이 가이드는 컴플라이언스 프레임워크가 아닙니다 — Ankole이 표면을 제공하며, 이를 얼마나 오래 보존할지는 사용자의 컴플라이언스 체계가 결정합니다. SIEM 통합 가이드도 아닙니다 — log는 구조화된 JSON이며 ingester는 사용자가 선택합니다. 그리고 검증된 backup의 대체재도 아닙니다 — audit trail은 PostgreSQL에 있으며, 복원할 수 없는 database는 trail도 함께 가져갑니다.

## 다음 단계

- Brain audit 표면은 [Brain](../brain/)을 읽으십시오.
- 권한 모델은 [Principal and AuthZ](../principal-authz/)를 읽으십시오.
- log 설정과 진단은 [Environment variables](../environment-variables/)와 [Read Ankole logs](../log-reading/)를 읽으십시오.
- trail을 보호하는 backup은 [Backup and restore](../backup-and-restore/)를 읽으십시오.