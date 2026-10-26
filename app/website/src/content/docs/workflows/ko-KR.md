---
title: Workflows
description: 유한한 작업을 병렬 서브에이전트로 나누어 실행하고 원래 대화에서 하나의 구조화된 결과를 수집합니다.
section: User guide
order: 19
---

Workflow는 메인 Agent가 고정되고 유한한 프로그램을 실행해 독립적인 작업을 여러 서브에이전트에 위임하는 기능입니다. 다수의 후보 검토, 유한한 소스 집합에서 동일한 필드 추출, 독립적인 판단 비교, 최종 종합 전 검증 단계 실행에 적합합니다.

Workflow는 현재 대화에서 시작되며 즉시 `run_id`를 반환합니다. 작업이 실행되는 동안에도 현재 대화를 계속 사용할 수 있습니다. Workflow가 완료되거나 실패하면 Ankole이 원래 대화를 깨워 메인 Agent가 결과를 읽고 작업을 이어가게 합니다.

## 알맞은 실행 방식 선택하기

| 필요한 작업 | 선택 | 이유 |
|---|---|---|
| 현재 대화가 필요한 짧은 단일 작업 | 메인 Agent 턴 | 현재 컨텍스트와 메인 턴의 전체 도구 세트를 그대로 유지합니다. |
| 유한한 독립 검토 또는 고정된 다단계 분석 | Workflow | 유한한 서브에이전트 작업을 병렬로 실행하고 하나의 집계 결과를 반환합니다. |
| 파일, 작업 공간, 후속 메시지 또는 사용자 입력이 필요한 장기 상태 유지 작업 | [Background Agent Job](../background-jobs/) | 일시 중지하고 재개할 수 있는 영구 Codex thread를 소유합니다. |
| 스케줄 또는 웹훅으로 실행되는 기계적 스크립트 | [Automation Job](../automation-jobs/) | 모델 판단이 필요 없을 때 트리거가 결정론적 처리를 바로 실행합니다. |

Workflow는 범용 DAG 엔진, 스케줄러 또는 이벤트 버스가 아닙니다. 외부 이벤트나 사용자의 결정을 직접 기다릴 수 없으므로, 시작 후에 작업 방향을 바꾸어야 한다면 Background Agent Job을 사용하십시오.

## Agent에게 Workflow 시작 요청하기

유한한 입력 집합, 각 독립 작업, 완료 조건 및 최종 결과 형식을 설명하십시오. 예:

```text
Run this as a Workflow. Review these 40 proposals in parallel against the five
criteria below. Return one JSON result with every verdict, the failed reviews,
and a final shortlist. Do not expand beyond these 40 proposals.
```

메인 Agent가 오케스트레이션 프로그램을 작성해 시작하므로 직접 JavaScript를 작성하거나 API를 호출할 필요가 없습니다. Agent는 실행당 동시성 한도, 최대 서브에이전트 호출 수, 그리고 자신이 사용할 수 있는 커스텀 모델 프로필을 지정할 수 있습니다. 프로필을 선택하지 않으면 Workflow 작업은 `primary`를 사용합니다.

시작 작업은 실행 ID와 현재 `running` 상태를 반환합니다. 메인 Agent는 실행 상태를 폴링하지 않습니다. 같은 대화에서 계속 이야기를 나누고 나중에 진행 상태를 물어볼 수 있습니다.

## 오케스트레이션 실행 방식

프로그램은 고정된 JSON `args`를 받아 `agent(prompt, options)`를 호출할 수 있습니다. `Promise.all` 안의 호출은 병렬로 실행되며, 앞 단계 호출이 끝난 뒤 일반 JavaScript 조건문으로 검증 또는 종합 단계를 선택할 수 있습니다. 모든 컬렉션과 반복문에는 코드에서 확인 가능한 유한한 상한이 있어야 합니다.

다음 단순화된 프로그램은 최대 20개 항목을 검토하고, 실패한 호출은 `null`로 유지한 뒤 성공한 결과를 종합합니다.

```js
const items = args.items.slice(0, 20)
const reviews = await Promise.all(
  items.map(item =>
    agent(`Review this item: ${JSON.stringify(item)}`, {
      label: `review-${item.id}`,
      schema: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          verdict: { type: 'string', enum: ['accept', 'reject'] },
          reason: { type: 'string' }
        },
        required: ['id', 'verdict', 'reason'],
        additionalProperties: false
      }
    })
  )
)

const successful = reviews.filter(review => review !== null)
const summary = await agent(`Summarize these reviews: ${JSON.stringify(successful)}`, {
  label: 'summary'
})

return { reviews, summary }
```

프로그램과 `args`는 실행이 시작된 뒤 바뀌지 않습니다. 제어 플레인은 각 오케스트레이션 단계를 무상태 `ankole-function-runtime` 서비스의 `POST /v1/program/run`으로 보냅니다. 각 단계는 네트워크, 파일 시스템, 환경 변수, 프로세스, FFI 권한이 모두 거부된 새 워커에서 실행되며, 결정론적인 `Math.random()` 및 `Date.now()` 값을 사용합니다. 작업이 실행되는 동안 이 워커는 상주하지 않습니다.

제어 플레인이 재시작되면 6 MiB 영구 memo 예산 안에서 저장된 작업 결과를 바탕으로 고정 프로그램을 리플레이합니다. 이미 저장된 성공 작업은 다시 생성되지 않으며, 리플레이 중 `agent()` 호출 순서나 인수가 저장된 기록과 달라지면 실행이 실패합니다. 중단된 작업은 재시도될 수 있으므로 작업 실행을 정확히 한 번(exactly-once)으로 간주하지 마십시오.

## 각 서브에이전트가 접근할 수 있는 범위

각 `agent()` 호출은 Agent Worker 슬롯을 점유하지 않고 제어 플레인 위의 독립 대화(`wf_task:<call_id>`)에서 실행됩니다. 서브에이전트는 Agent의 정체성과 미션, 그리고 작업 프롬프트를 받으며, 프로그램이 후속 프롬프트에 명시적으로 포함하지 않는 한 원래 대화 기록이나 다른 작업의 결과는 받지 않습니다.

Workflow 작업은 Web 도구를 사용할 수 있고, Brain이 활성화된 경우 읽기 전용 `recall` 및 `get_page` 도구를 사용할 수 있습니다. 셸, 파일, MCP, Skill, Brain 쓰기, 스케줄 도구는 직접 받지 않으며, 또 다른 Workflow를 생성할 수도 없습니다(오케스트레이션 중첩 깊이는 1입니다).

작업 공간 실행이나 여러 시간에 걸친 처리가 필요한 경우, 작업은 [Background Agent Job](../background-jobs/)(`create_background_job`, `show_background_job_details`, `send_message_to_background_job`, `stop_background_job`)을 위임하고 `sleep`(1분~48시간, 호출당 최대 16회)을 호출해 동시성 슬롯을 점유하지 않은 채 대기할 수 있습니다. 위임한 Job의 수명 주기 이벤트, 메인 세션 메시지 또는 마감 시각이 도달하면 다시 깨어납니다. `sleep`에 `attention: true`를 설정하면 메인 Agent에게 알림을 보내 대기 메모를 확인하고 응답하게 합니다. 작업 결과가 준비되면 `submit_result`를 호출해 종료합니다.

각 깨어남 구간에서 호출 하나는 최대 3번까지 작업을 시도할 수 있습니다. 성공한 호출은 제출된 값으로 확인됩니다. 시도 횟수를 모두 소진한 호출은 `null`로 확인되므로, 프로그램이 실패를 기록하고 계속 진행하거나 최종 결과에서 누락 사유를 설명할 수 있습니다. 작업 하나가 실패하더라도 전체 Workflow가 자동으로 실패하지는 않습니다.

## 구조화된 결과 요구하기

`agent()` 호출은 결과 schema를 선언할 수 있습니다. Ankole은 생성된 `submit_result` 도구를 Provider strict 모드로 전송하고 제어 플레인에서도 제출된 값을 다시 검증합니다. schema 검증에서 거부되더라도 작업은 활성 상태로 유지되므로 서브에이전트가 값을 수정해 다시 제출할 수 있습니다.

이 schema는 전체 명세가 아니라 OpenAPI 3 JSON Schema의 닫힌 부분집합입니다. 결과는 `object`, `array`, `string`, `number`, `integer`, `boolean` 중 하나의 null이 아닌 타입을 가집니다. 중첩 객체를 포함한 모든 객체는 `properties`를 선언하고 모든 속성을 `required`에 나열하며 `additionalProperties: false`를 설정해야 합니다. 선택적 객체 필드, nullable 값, union, `$ref`, `oneOf`/`anyOf`/`allOf`는 지원하지 않습니다.

schema를 지정하지 않으면 작업은 문자열을 반환합니다. 프로그램은 최종 집계 결과를 반환해야 하며, 문자열은 최종 텍스트가 되고 그 외 JSON 값은 JSON 텍스트로 직렬화됩니다.

## 실행 조회, 작업 메시지 전송, 목록 확인 및 취소

메인 Agent에게 다음 작업을 요청하십시오.

- `show_workflow`는 상태, 작업 수, 최대 32개의 활성 작업(`sleep`의 `note`, `attention`, 깨어남 마감 시각 포함), 최대 10개의 실패 요약 및 종료 오류를 보고합니다. 완료된 결과는 바이트 오프셋 `0`부터 최대 8,000 UTF-8 바이트 세그먼트 단위로 읽습니다.
- `send_message_to_workflow_task`는 `run_id`와 `call_seq`로 지정한 활성 작업에 비동기 메시지를 추가해 대기 중인 작업을 깨우거나 `attention: true`로 대기한 작업에 응답합니다.
- `list_workflows`는 해당 Agent의 진행 중이거나 종료된 실행을 한 번에 최대 32개까지 나열합니다. 종료된 실행에는 `completed`, `failed`, `cancelled`가 포함됩니다.
- `cancel_workflow`는 멱등적입니다. 새 작업 생성과 뒤늦게 도착한 결과로 인해 실행이 되살아나는 것을 막은 뒤, 실행 중인 작업 턴과 위임된 Background Agent Job에 중지를 요청합니다. 모델 호출이 멈추기까지 짧은 시간이 걸릴 수 있습니다.

완료되거나 실패한 실행은 원래 대화를 깨웁니다. 취소된 실행은 완료 이벤트를 보내지 않으므로, 확인이 필요하면 Agent에게 상태를 확인하라고 요청하십시오.

Console에서는 홈의 백그라운드 활동 영역이 읽기 전용 Workflow 활동(`site_console:agent:<agent_uid>:workflow` 권한 아래 활성 호출, 상태 수, 대기 메모, 마감 시각, `attention` 플래그 및 유한한 오류 요약)을 표시합니다. 실행 시작, 작업 메시지 전송, 전체 결과 읽기 및 실행 취소는 메인 Agent의 Workflow 도구를 사용합니다.

## 비용과 용량 제어하기

모든 작업 시도는 완전한 모델 턴 하나이며 유료 Web 호출을 수행할 수도 있습니다. 동시성은 소요 시간만 바꿀 뿐 전체 호출 수는 줄이지 않습니다. 유한한 입력 크기에 맞춰 호출 한도를 설정하고 각 작업 프롬프트와 결과를 간결하게 유지하십시오.

| 경계 | 기본값 | 하드 상한 |
|---|---:|---:|
| 단일 실행의 동시 작업 수 | 8 | 32 |
| 단일 Agent에서 실행 중인 Workflow 작업 수 | 8 | 64 |
| 단일 실행의 서브에이전트 호출 수 | 32 | 1,024 |
| 깨어남 구간당 시도 횟수 | 최대 3 | 3 |
| 단일 서브에이전트 호출의 `sleep` 횟수 | — | 16 |
| 단일 `sleep` 지속 시간 | — | 1분~48시간 |
| 저장된 프로그램 | — | 256 KiB |
| 저장된 `args` | — | 64 KiB |
| 단일 호출 인수 객체 | — | 8 KiB |
| 단일 상위 세션 작업 메시지 | — | 8 KiB |
| 단일 제출 결과 값 | — | 24 KiB |
| 영구 memo 예산 | — | 6 MiB |
| 최종 집계 결과 | — | 1 MiB |

관리자는 [AppConfigure](../app-configuration/)에서 하드 상한 범위 내로 처음 세 가지 인스턴스 한도를 설정할 수 있습니다. 개별 실행 요청으로 배포 한도를 높일 수는 없습니다. Workflow에는 배치 전체에 걸친 토큰이나 금액 예산이 없으며, 각 작업에는 일반 턴의 반복 횟수, 출력 토큰 및 비활성 시간 한도가 그대로 적용됩니다. 관련 제어 방법은 [비용 관리](../cost-management/)를 참조하십시오.

실행이 크기 경계를 초과하면 팬아웃을 줄이거나, 더 짧은 작업 요약을 반환하게 하거나, 입력을 여러 Workflow로 나누십시오. 프로그램이나 입력을 바꾸어야 할 때는 새 실행을 생성하십시오. 실패한 실행을 다른 코드로 편집하거나 재개할 수는 없습니다.
