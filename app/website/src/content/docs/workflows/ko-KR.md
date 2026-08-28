---
title: Workflows
description: 고정되고 유한한 JavaScript로 독립적인 서브에이전트 task를 병렬로 실행하고 구조화된 결과를 결합합니다.
section: User guide
order: 19
---

Workflow는 Main Agent가 한 번 시작하는 유한한 서브에이전트 orchestration입니다. 제어 플레인은 고정된 JavaScript, 각 task, 구조화된 결과를 PostgreSQL에 저장합니다. run이 완료되거나 실패하면 원래 대화를 한 번 다시 깨웁니다.

서로 독립적인 항목을 병렬로 조사하거나, 수집–검증–종합처럼 단계가 명확한 작업에 Workflow를 사용하세요. 작업 중에 사용자의 판단, 후속 메시지, 지속적인 workspace가 필요한 하나의 긴 작업은 [Background Agent Job](../background-jobs/)으로 실행하세요.

## 어떤 실행 방식을 선택할지

| 작업 형태 | 선택 | 이유 |
|---|---|---|
| 하나의 짧은 작업 | 현재 turn에서 직접 실행 | 다음 답변에 완료된 결과를 담을 수 있음 |
| 크기가 고정된 배치 또는 유한한 다단계 분석 | Workflow | 여러 서브에이전트 task를 병렬로 실행하고 코드로 결과를 결합함 |
| 지속적인 컨텍스트가 필요한 하나의 긴 작업 | Background Agent Job | 고유한 Codex thread와 workspace를 유지하고 후속 메시지와 사용자 질문을 처리함 |
| 반복 가능한 기계적 이벤트 처리 | Automation Job | Agent Home의 결정적 Bun script가 schedule이나 webhook delivery를 처리함 |

Workflow는 scheduler, YAML 단계 목록, 플랫폼 DAG 또는 범용 이벤트 버스가 아닙니다. 외부 상태를 폴링하거나 시간을 기다리는 용도로 사용하지 마세요.

## Agent에게 Workflow 요청

채팅에서 입력 범위, 각 task가 반환할 결과, 최대 동시성을 명확히 적으세요. 예:

```text
이 20개 공급업체를 Workflow로 비교해 줘. 각 공급업체를 독립적으로 조사하고,
가격 구조, 증거 URL, 주요 위험을 구조화된 결과로 받아 최종 비교표를 만들어.
동시성은 8, 총 task 상한은 20으로 설정해.
```

Agent는 `workflow` tool로 run을 생성하고 `run_id`와 초기 `running` 상태를 즉시 받습니다. 원래 대화는 run이 완료될 때까지 폴링할 필요가 없습니다. 사용자는 같은 대화에서 계속 이야기할 수 있고, 완료 또는 실패 이벤트가 도착하면 Agent가 결과를 이어서 보고합니다.

## Workflow가 실행되는 방식

1. 제어 플레인이 `script`, JSON object `args`, 실행 상한을 PostgreSQL에 저장합니다. `script`와 `args`는 생성 후 바뀌지 않습니다.
2. 고정된 JavaScript가 `agent(prompt, opts)`를 호출하면 제어 플레인이 각 호출을 독립적인 task turn으로 디스패치합니다.
3. 서브에이전트가 `submit_result`로 schema에 맞는 값을 제출합니다. Provider가 strict schema를 적용하고 제어 플레인이 값을 다시 검증합니다.
4. 제어 플레인이 저장된 결과를 memo로 다시 실행하여 다음 단계를 찾습니다. 먼저 성공한 task는 새 task로 다시 만들지 않습니다.
5. script가 최종 값을 반환하면 run이 `completed`가 됩니다. script 또는 replay가 계약을 위반하면 run이 `failed`가 됩니다.

한 단계의 호출은 `Promise.all`로 병렬 실행할 수 있습니다. 다음 단계는 이전 호출의 가장 긴 연속 전체가 종료된 후에만 시작합니다. 각 `agent()` 호출이 재시도 예산을 모두 사용해도 실패하면 `null`을 반환하므로 script가 그 경우를 명시적으로 처리해야 합니다.

## 작업을 잘 나누는 방법

- 각 task에 하나의 완결된 판단, 요약 또는 사실 집합을 요청하세요. 소스 전체를 그대로 반환하게 하지 마세요.
- `label`은 `collect:security`, `verify:pricing`, `panel:risk`처럼 역할과 파티션을 나타내도록 짧고 안정적으로 작성하세요.
- 서로 독립적인 작업은 함께 시작하고, 후속 단계에는 이전 단계의 작은 구조화된 결과만 넘기세요.
- 모든 반복문에 script에서 보이는 명시적인 상한을 두세요. 서브에이전트 출력에서 무제한 반복을 만들지 마세요.

다음은 각 항목을 독립적으로 분석한 뒤 실패한 task를 제외하는 예시입니다.

```js
const rows = await Promise.all(
  args.items.slice(0, 20).map((item, index) =>
    agent(`이 항목의 핵심 위험을 분석해: ${JSON.stringify(item)}`, {
      label: `risk:${index}`,
      schema: {
        type: "object",
        properties: {
          finding: { type: "string", maxLength: 1200 },
          severity: { type: "integer", minimum: 1, maximum: 5 }
        },
        required: ["finding", "severity"],
        additionalProperties: false
      }
    })
  )
);
return { findings: rows.filter((row) => row !== null) };
```

## 결과 schema

task schema의 최상위 및 중첩 노드는 `object`, `array`, `string`, `number`, `integer`, `boolean` 중 하나의 null이 아닌 type을 가져야 합니다. `$ref`, nullable, union, `oneOf`, `anyOf`, `allOf`는 지원하지 않습니다.

모든 object schema는 `properties`, `required`, `additionalProperties: false`를 명시해야 합니다. `required`는 모든 property 이름을 정확히 한 번씩 포함해야 하므로 optional object property는 지원하지 않습니다. object 하나는 최대 128개 property를 가질 수 있고, schema 깊이는 최대 16입니다.

지원되는 제약 조건:

- 모든 type: `title`, `description`, 같은 type의 비어 있지 않은 `enum`;
- array: 필수 `items`, 선택 `minItems`/`maxItems`;
- string: `minLength`, `maxLength`, `pattern`;
- number: `minimum`, `maximum`;
- integer: `minimum`, `maximum`, 양의 정수 `multipleOf`.

성공한 task result는 null이 아니어야 하며 JSON 인코딩 후 24 KiB를 넘을 수 없습니다. schema가 값을 거부하면 task turn은 종료되지 않고 서브에이전트가 값을 고쳐 다시 제출할 수 있습니다.

## 상태 확인과 취소

Main Agent는 다음 tool로 자신이 소유한 Workflow를 관리합니다.

- `show_workflow`는 구체적인 상태, task 계수, 최대 10개의 실패 요약, 종료 오류를 반환합니다. `completed` run의 결과는 `result_offset: 0`에서 시작하여 안정적인 UTF-8 byte offset으로 나누어 읽습니다. 한 세그먼트의 직렬화된 tool 결과는 최대 8,000 bytes입니다.
- `list_workflows`는 기본적으로 `running` run을 최신순으로 한 페이지에 최대 32개 반환합니다. `done`은 `completed`, `failed`, `cancelled`를 포함합니다. `next_page`는 같은 turn에서만 사용하세요.
- `cancel_workflow`는 멱등적입니다. 새 task를 막고 실행 중인 task turn에 stop을 요청하며, 늦게 도착한 result가 run을 다시 시작하지 못하게 합니다. stop 요청은 비동기이므로 실행 중인 model이 즉시 종료된다고 보장하지 않습니다. `cancelled` run은 완료 알림을 보내지 않습니다.

현재 Workflow는 대화에서 Main Agent가 사용하는 tool을 통해 관리합니다. Workflow 전용 Console 보드나 공개 HTTP API는 제공하지 않습니다.

## task 도구와 실행 경계

각 task는 `wf_task:<call_id>` session의 독립 conversation에서 실행됩니다. 사용 가능한 도구는 Web tools, Brain이 활성화된 경우의 읽기 전용 `recall`/`get_page`, 그리고 `submit_result`입니다. task는 shell, 파일, MCP, Skill, Brain 쓰기, Workflow, Background Agent Job tool을 받지 않습니다. Workflow의 중첩 깊이는 1입니다.

Workflow JavaScript는 파일, 네트워크, import, timer API가 없는 bare V8 isolate에서 실행됩니다. `Date.now()`와 `Math.random()`은 replay에서 같은 결과를 내는 결정적 shim을 사용합니다. 외부 시계, 네트워크 응답 또는 파일 내용에서 호출 인수를 만들지 마세요. replay의 `agent()` 순서나 전체 인수가 저장된 memo와 다르면 run이 `workflow_replay_diverged`로 실패합니다.

## 용량과 비용 상한

| 한계 | 기본값 | 하드 상한 |
|---|---:|---:|
| run 하나가 요청하는 동시 task | 8 | 32 |
| Agent 하나에서 실행 중인 Workflow task | 8 | 64 |
| run 하나의 `agent()` 호출 | 256 | 1,024 |
| 저장된 script | — | 256 KiB |
| 저장된 `args` JSON | — | 64 KiB |
| `agent()` 호출 하나의 전체 argument object | — | 8 KiB |
| 성공한 task result 값 하나 | — | 24 KiB |
| 지속 memo | — | 6 MiB |
| 최종 result text | — | 1 MiB |

각 task attempt는 완전한 model turn 하나입니다. 호출 하나는 재시도 가능한 실패가 지속되면 최대 3번의 attempt를 사용할 수 있습니다. Workflow v1에는 run 전체의 token 또는 금액 예산이 없으며, 각 task는 일반 turn의 model iteration, output-token, inactivity 상한을 그대로 적용받습니다. 운영자는 [AppConfigure](../app-configuration/)에서 하드 범위 안의 배포 상한을 설정할 수 있지만, run 요청으로 배포 상한을 높일 수는 없습니다.

## 복구 및 실패 처리

PostgreSQL이 run, task, result의 권위 있는 저장소입니다. 제어 플레인이 재시작하면 `running` run의 driver를 다시 만듭니다. 이미 성공한 task result는 memo에서 재사용되며 새 task로 다시 실행되지 않습니다.

하지만 Workflow task는 exactly-once로 실행되지 않습니다. Worker 중단이나 retryable 실패로 끝난 task는 재시도될 수 있고, 세 번째 실패 후 `failed`가 됩니다. 한 시간 watchdog가 오래된 `running` task에 동일한 보상 규칙을 적용합니다. 도중에 실패한 `agent()` 호출을 script가 `null`로 처리하고 최종 값을 반환하면 run 자체는 완료될 수 있습니다.

run이 `completed` 또는 `failed`가 되면 제어 플레인이 남은 `queued`/`running` task를 같은 transaction에서 `cancelled`로 바꿉니다. transaction이 commit된 뒤 기존의 실행 중인 task turn에 stop을 요청합니다. 종료된 run의 script를 수정하거나 제자리에서 재개할 수는 없으므로, 수정된 입력과 script로 새 run을 시작하세요.

## 운영자 설정

**Console → AppConfigure**에서 다음 인스턴스 설정을 관리합니다.

- `workflow.max_concurrency_per_run`: run별 task 동시성, 기본값 `8`, 범위 `1`–`32`;
- `workflow.max_running_per_agent`: Agent별 실행 중 Workflow task, 기본값 `8`, 범위 `1`–`64`;
- `workflow.max_agent_calls_per_run`: run별 총 `agent()` 호출, 기본값 `256`, 범위 `1`–`1,024`.

## 다음 단계

- 지속적인 서브에이전트 작업은 [Background Agent Jobs](../background-jobs/)를 참조하세요.
- 모델 호출 비용과 동시성 상한은 [비용 관리](../cost-management/)를 참조하세요.
- 설정 적용과 초기화는 [AppConfigure](../app-configuration/)를 참조하세요.
- turn별 tool 조립과 `submit_result` schema 처리는 [Tool 런타임](../tools-runtime/)을 참조하세요.
