---
title: Agent Computer Worker
description: Bun과 TypeScript Worker가 control plane이 각 turn을 fence하는 동안 model loop, tool, 파일, 터미널 상태, 스트리밍 출력을 실행하는 방식.
section: Developer guide
order: 108
---

Agent Computer Worker는 Agent의 실행 노드입니다. 대화가 깨어나면 Actor Runtime이 fence된 turn을 Worker에 부여합니다. Worker는 model loop, tool, 파일, 터미널 작업을 실행한 후 결과를 control plane에 반환합니다. 이 페이지는 `app/agent_computer`가 구현하는 경계를 설명합니다.

핵심 속성을 먼저 말하면, worker는 라이브 실행과 다시 만들 수 있는(rebuildable) worker 로컬 상태만 소유하며 그 이상은 없습니다. 영구 상태(transcript, fence, 최종 commit)는 control plane에 남습니다. worker는 교체 가능하며, 늦게 도착했거나 잘못된 worker 쓰기는 fence 검사에 실패하여 버려집니다.

## 소유권 경계

구분은 worker 자체 계약에 명시되어 있습니다. Agent Computer Worker는 라이브 실행과 rebuildable worker 로컬 상태를 소유합니다. Elixir control plane은 PostgreSQL 상태, actor 및 delivery fence, 최종 commit 권한, provider outbox, 런타임 자격 증명, 복구 사실을 소유합니다. worker는 영구 control-plane 상태를 만들어서는 안 됩니다.

이것이 실제로 배제하는 것: `DATABASE_URL`, `ANKOLE_AGENT_UID`, `ANKOLE_SESSION_ID`, `ANKOLE_ACTOR_EPOCH`는 worker 입력이 아닙니다. actor 신원은 environment가 아닌 `turn_start`로 전달됩니다. worker는 `WORKER_ID`, `ANKOLE_RUNTIME_FABRIC_ENDPOINT`, 그리고 별도의 `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` secret으로 RuntimeFabric에 인증합니다. `ANKOLE_AGENTS_ROOT`는 공유 workspace의 위치를 지정합니다. worker는 database 연결을 보유하지 않으며 자신이 누구를 대신해 행동하는지 결정하지 않습니다.

## 턴 펜스

worker가 실행하는 모든 turn은 `activation_uid`, `actor_epoch`, `actor_event_id`의 세 필드를 가진 `ActorTurnRef`로 고정됩니다. 하나의 worker 실행은 정확히 하나의 `actor_event_id`를 처리합니다. worker는 `${activation_uid}:${actor_event_id}`를 키로 하여 메모리 내 활성 turn 상태를 관리하며, control plane으로 보내는 모든 envelope에는 해당 ref가 포함됩니다.

이것은 [Actor Runtime](../actor-runtime/) 삼중 fence의 worker 측입니다. control plane은 들어오는 각 worker 쓰기를 activation, epoch, delivery 행과 대조하여 검사합니다. activation이 대체되었거나, lease가 만료되었거나, 이벤트가 더 높은 epoch로 재시도되어 worker의 ref가 더 이상 일치하지 않으면 쓰기는 stale로 거부됩니다. worker는 더 이상 소유하지 않는 turn에 commit할 수 없습니다.

## 모델 루프

agent loop은 AIGateway의 stateful transport를 통한 worker 주도 Responses loop이며 의도적으로 작게 유지됩니다. 네 단계로 이루어집니다.

1. turn 범위의 OpenAI Responses adapter를 통해 model을 호출합니다.
2. 응답에 function-call 항목이 있으면 로컬에서 실행합니다.
3. function-call 출력을 AIGateway를 통해 기록합니다.
4. 더 이상 function-call 항목이 오지 않을 때까지 기록된 journal anchor에서 계속합니다.

worker는 loop 종료와 로컬 반복 예산을 소유합니다. history 확장, compaction, continuation anchor, 영구 응답 상태는 소유하지 **않으며** 이들은 AIGateway에 남습니다. loop가 끝나면 결과는 둘 중 하나입니다. `loop_finished`(model이 더 이상 tool 호출 없이 응답) 또는 `iteration_exhausted`(worker가 반복 한도에 도달했고 model이 더 많은 tool을 호출하는 대신 최종 답변을 종합하도록 유도됨). worker는 turn 전체의 결과를 control plane에 보고하고 control plane이 이를 기록합니다.

## Tool: worker 내부에서 실행되는 것

tool은 loop 중에 model이 구동할 수 있는 로컬 작업입니다. worker는 이를 각각 실제 worker 코드로 구현된 범주로 제공합니다.

- **Computer** — bubblewrap 제한 아래의 shell 명령, 파일 읽기와 patch, apply-patch, 그리고 실제 브라우저 데스크톱을 구동하는 v4a computer-use tool. 터미널 상태와 파일 편집이 여기에서 관리됩니다.
- **Web** — worker를 통해 라우팅되는 web search와 web fetch.
- **schedule, todo, clarify** — agent가 계획하고, 연기하고, 질문하는 데 사용하는 더 작은 구조화된 tool.
- **Codex** — Background Agent Job에 위임된 작업을 위한 CodexRunner job tool.
- **Library 및 mcporter** — 활성화된 Skill과 호출 범위의 MCP dependency config에 대한 액세스.
- **Background Agent Job** — 영구 job을 만들거나 이어가는 handoff tool.

worker가 생성하는 모든 tool 결과는 직접 commit되지 않고 AIGateway를 통해 function-call 출력으로 기록됩니다. model은 결과를 보고, control plane이 무엇이 영구적인지 결정합니다.

## 파일시스템 계약

영구 공유 쓰기 가능 런타임 마운트는 `/agents`이며 actor key별로 다음과 같이 배치됩니다.

```text
/agents/<agent-key>/
├── .codex/
├── SOUL.md
├── MISSION.md
├── DESIGN.md
├── user-files/
├── installed-skills/
├── sessions/<workspace-id>/
└── jobs/<job-id>/
    ├── .codex/config.toml
    ├── .ankole/skills/
    └── temp/
```

model은 절대 컨테이너 경로를 봅니다. Worker는 경로를 변환하지 않습니다. `SOUL.md`와 `MISSION.md`는 Agent의 행동과 책임을 정의합니다. `DESIGN.md`는 시각 작업을 위한 디자인 시스템입니다. [Agent Library](../agent-library/)가 세 파일을 모두 관리합니다. `installed-skills/`, `sessions/`, `jobs/`에는 Skill, 대화 workspace, Background Agent Job workspace가 들어 있습니다. PostgreSQL은 각 Session에 10000부터 시작하는 안정적인 숫자 workspace ID를 부여합니다.

## 스트리밍과 진행 상황

turn이 실행되는 동안 worker는 best-effort, 비중첩(non-overlapping) envelope로 진행 상황을 게시합니다. 일정 간격마다 checkpoint를 보내고, 유용한 내용이 있으면 활동 요약을 보냅니다. 진행 상황은 의도적으로 내구성 메커니즘이 아닙니다. 막힌 진행 상황 전송이 타이머를 쌓거나 그것이 설명하는 loop를 막으면 안 됩니다. model과 tool이 생성하는 스트리밍 출력은 동일한 RuntimeFabric lane을 통해 돌아오며, 무엇이 영구가 될지는 worker가 스트리밍하는 시점이 아니라 commit 시점에 control plane이 결정합니다.

worker는 또한 작은 admission hint(메모리 내 상태에서 남은 turn 용량)를 게시하여 control plane이 가득 찬 프로세스에 작업을 보내지 않게 합니다. 스케줄링은 control plane에 남아 있으며, hint는 그저 힌트일 뿐입니다.

## Agent Computer Worker가 아닌 것

이것은 독립 실행형 로컬 CLI가 아닙니다. Linux worker image 안에서 실행되며, image가 native kernel 바인딩, bubblewrap, Chromium, Python/Jupyter와 문서 툴링, ZeroMQ, 공유 agent 파일시스템을 제공합니다. 영구 상태를 만들어내는 장소도 아닙니다. worker의 일은 fence된 turn을 실행하고 보고하는 것이며 모든 영구 결정은 control plane의 몫입니다. 두 번째 스케줄러도 아닙니다. Actor Runtime이 waking, leasing, retrying을 소유합니다. 경계는 명확합니다. control plane이 turn의 정체성과 진실을 소유하고, worker가 turn의 실행을 소유합니다.

## 다음 단계

- worker를 하나의 activation에 고정하는 fence는 [Actor Runtime](../actor-runtime/) 페이지를 참조하세요.
- loop가 호출하는 stateful Responses transport는 [AIGateway API](../ai-gateway/)를 참조하세요.
- worker가 `/agents`에서 읽는 skill과 문서는 [Agent Library](../agent-library/) 페이지를 참조하세요.
