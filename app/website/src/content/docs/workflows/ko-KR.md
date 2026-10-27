---
title: Workflows
description: 유한한 작업을 병렬 서브에이전트로 나누어 실행하고 원래 대화에서 하나의 구조화된 결과를 수집합니다.
section: User guide
order: 19
---

Workflow는 메인 Agent가 상한이 정해진 유한한 오케스트레이션 프로그램을 작성해 독립적인 하위 작업들을 여러 서브에이전트에 병렬 위임하는 기능입니다. 다수의 후보 안건을 동시에 검토하거나, 정해진 문서 집합에서 동일한 필드를 추출하고, 독립적인 평가를 대조한 뒤 최종 종합 전에 검증 단계를 거치는 업무에 적합합니다.

현재 대화방에서 Workflow를 시작하면 즉시 `run_id`가 반환되므로, 백그라운드에서 하위 작업들이 도는 동안에도 대화를 멈추지 않고 이어갈 수 있습니다. 이후 Workflow 실행이 완료되거나 실패하면 Ankole이 원래 대화를 깨워 메인 Agent가 집계 결과를 읽고 후속 응답을 이어가게 합니다.

## 알맞은 실행 방식 선택하기

| 필요한 작업 성격 | 권장 방식 | 선택 이유 |
|---|---|---|
| 현재 대화 맥락만 있으면 충분한 짧은 단일 작업 | 메인 Agent 턴 | 현재 대화 컨텍스트와 메인 턴의 전체 도구를 그대로 사용할 수 있습니다. |
| 개수가 정해진 독립 검토 또는 고정 다단계 분석 | Workflow | 유한한 서브에이전트 작업을 병렬로 실행해 구조화된 집계 결과 하나를 반환합니다. |
| 파일 편집, 전용 워크스페이스, 중간 대화 개입이나 사용자 입력이 필요한 장기 상태 유지 작업 | [Background Agent Job](../background-jobs/) | 일시 중지하고 다시 이어갈 수 있는 영속 Codex 스레드를 소유합니다. |
| 스케줄이나 웹훅으로 구동되는 기계적 처리 스크립트 | [Automation Job](../automation-jobs/) | 모델 판단이 필요 없는 구간에서 트리거가 결정론적 코드를 곧바로 실행합니다. |

Workflow는 범용 DAG 워크플로 엔진이나 스케줄러, 이벤트 버스가 아닙니다. 실행 도중 외부 이벤트를 직접 구독하거나 사용자의 실시간 결정을 기다려 분기할 수 없으므로, 진행 중에 방향을 유연하게 바꾸어야 하는 작업에는 Background Agent Job을 사용하십시오.

## Agent에게 Workflow 시작 요청하기

처리할 유한한 입력 범위, 각 서브에이전트가 맡을 독립 작업, 완료 기준, 최종 출력 형식을 구체적으로 알려 주십시오. 예시는 다음과 같습니다.

```text
Run this as a Workflow. Review these 40 proposals in parallel against the five
criteria below. Return one JSON result with every verdict, the failed reviews,
and a final shortlist. Do not expand beyond these 40 proposals.
```

오케스트레이션 코드는 메인 Agent가 직접 작성해 실행하므로 사용자가 JavaScript를 짜거나 API를 직접 호출할 필요가 없습니다. 실행 시 메인 Agent는 실행당 동시 작업 수, 최대 서브에이전트 호출 횟수, 그리고 자신에게 허용된 커스텀 모델 프로필을 지정할 수 있으며, 별도 프로필을 고르지 않으면 `primary` 프로필이 사용됩니다.

Workflow가 시작되면 실행 ID와 `running` 상태가 즉시 반환되며, 메인 Agent는 루프를 돌며 상태를 폴링하지 않습니다. 사용자는 같은 채팅방에서 다른 대화를 계속 나누다가 필요할 때 진행 상황만 물어보면 됩니다.

## 오케스트레이션 실행 방식

오케스트레이션 프로그램은 고정된 JSON `args`를 입력받아 `agent(prompt, options)` 함수를 호출합니다. `Promise.all`로 묶은 호출들은 병렬로 실행되며, 앞 단계 결과를 받아 일반 JavaScript 조건문으로 후속 검증이나 종합 단계를 이어갈 수 있습니다. 단, 모든 배열과 반복문에는 코드 상에서 확인 가능한 유한한 상한이 있어야 합니다.

아래 예시 프로그램은 최대 20개 항목을 병렬 검토한 뒤, 실패한 항목(`null`)을 걸러 내고 성공한 검토 결과만 모아 최종 요약을 작성합니다.

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

한번 실행이 시작되면 프로그램 코드와 입력 `args`는 바꿀 수 없습니다. 제어 플레인은 오케스트레이션 진행 단계마다 무상태 서비스인 `ankole-function-runtime`의 `POST /v1/program/run`을 호출합니다. 각 단계는 네트워크, 파일시스템, 환경 변수, 하위 프로세스, FFI 권한이 모두 차단된 깨끗한 격리 워커에서 실행되며 결정론적인 `Math.random()` 및 `Date.now()` 값을 사용합니다. 하위 서브에이전트 작업이 도는 동안 이 함수 워커가 메모리에 상주해 기다리지는 않습니다.

제어 플레인이 재시작되더라도 최대 6 MiB의 영구 memo 예산 안에 기록된 완료 작업 결과를 바탕으로 동일 프로그램을 처음부터 리플레이해 상태를 복원합니다. 이미 성공해 저장된 `agent()` 호출은 다시 실행되지 않으며, 만약 리플레이 도중 호출 순서나 인수가 저장된 기록과 달라지면 실행이 실패 처리됩니다. 진행 중 중단된 개별 작업은 재시도될 수 있으므로 서브에이전트 실행을 정확히 한 번(exactly-once) 보장으로 가정하지 마십시오.

## 각 서브에이전트가 접근할 수 있는 범위

각 `agent()` 호출은 Agent Worker 슬롯을 쓰지 않고 제어 플레인 위의 독립된 대화(`wf_task:<call_id>`)로 실행됩니다. 서브에이전트에는 해당 Agent의 정체성과 미션 문서, 그리고 전달된 작업 프롬프트만 주어지며, 오케스트레이션 코드가 후속 프롬프트에 직접 넣어 주지 않는 한 원래 채팅방의 대화 기록이나 다른 병렬 작업의 결과는 볼 수 없습니다.

도구 범위 역시 제한됩니다. 각 서브에이전트는 Web 도구를 쓸 수 있고 Brain이 켜져 있으면 읽기 전용인 `recall`과 `get_page`를 호출할 수 있지만, 셸·파일 도구, MCP, Skill, Brain 쓰기, 스케줄 도구는 직접 사용할 수 없으며 하위에서 또 다른 Workflow를 중첩 생성할 수도 없습니다(오케스트레이션 최대 중첩 깊이는 `1`).

만약 워크스페이스 파일 작업이나 수 시간에 걸친 실행이 필요하다면, 서브에이전트가 [Background Agent Job](../background-jobs/) 도구(`create_background_job`, `show_background_job_details`, `send_message_to_background_job`, `stop_background_job`)로 작업을 위임한 뒤 `sleep`(1분~48시간, 단일 호출당 최대 16회)을 호출해 동시성 슬롯을 반납한 채 대기할 수 있습니다. 이후 위임한 Job의 수명 주기 이벤트가 발생하거나 메인 세션에서 작업 메시지를 보내거나 지정한 대기 기한에 도달하면 다시 깨어납니다. 이때 `sleep`에 `attention: true`를 주면 메인 Agent에 알림이 전달되어 대기 메모를 확인하고 응답할 수 있습니다. 최종 결과가 준비되면 `submit_result`를 호출해 작업을 마칩니다.

깨어난 각 실행 구간마다 단일 호출은 최대 3회까지 시도할 수 있습니다. 정상 제출된 호출은 해당 결과값으로 귀결되고, 재시도 한도를 모두 소진한 호출은 전체 Workflow를 곧바로 중단시키는 대신 `null`을 반환합니다. 따라서 오케스트레이션 코드에서 일부 실패 항목을 기록해 두고 나머지 결과만으로 종합을 마칠 수 있습니다.

## 구조화된 결과 요구하기

`agent()` 호출에 결과 `schema`를 지정하면 Ankole이 생성된 `submit_result` 도구를 Provider의 strict 모드로 전달하고 제어 플레인에서도 제출된 값을 다시 검증합니다. 스키마 검증에 맞지 않는 값을 제출하더라도 작업이 바로 종료되지 않으므로 서브에이전트가 오류를 확인해 값을 고쳐 다시 제출할 수 있습니다.

여기서 허용되는 `schema`는 전체 JSON Schema가 아니라 OpenAPI 3 JSON Schema의 닫힌 부분집합입니다. 최상위 및 하위 값 타입은 `object`, `array`, `string`, `number`, `integer`, `boolean` 중 null이 아닌 단일 타입이어야 하며, 중첩 객체를 포함한 모든 `object`는 반드시 `properties`를 선언하고 모든 키를 `required`에 넣은 뒤 `additionalProperties: false`를 지정해야 합니다. 선택적(optional) 프로퍼티, nullable 타입, union, `$ref`, `oneOf`/`anyOf`/`allOf`는 지원하지 않습니다.

별도 `schema`를 선언하지 않으면 서브에이전트는 일반 문자열을 반환합니다. 오케스트레이션 프로그램 역시 최종 집계 값을 반환해야 하며, 반환값이 문자열이면 그대로 최종 텍스트가 되고 그 외 JSON 값은 직렬화된 JSON 문자열로 저장됩니다.

## 실행 조회, 작업 메시지 전송, 목록 확인 및 취소

진행 상태 확인이나 제어가 필요할 때는 메인 Agent에게 요청하십시오(내부적으로 아래 도구들이 사용됩니다).

- `show_workflow`: 현재 상태, 전체·완료 작업 수, 최대 32개의 활성 작업(`sleep` 중인 작업의 `note`, `attention`, 깨어남 기한 포함), 최대 10개의 실패 요약 및 종료 오류를 조회합니다. 완료된 최종 결과는 바이트 오프셋 `0`부터 최대 8,000 UTF-8 바이트 단위 세그먼트로 나누어 읽습니다.
- `send_message_to_workflow_task`: `run_id`와 `call_seq`로 지정한 활성 작업에 비동기 메시지를 전달해 `sleep` 중인 작업을 즉시 깨우거나 `attention: true` 요청에 답합니다.
- `list_workflows`: 해당 Agent의 실행 중이거나 종료된(`completed`, `failed`, `cancelled`) Workflow 목록을 한 번에 최대 32개까지 조회합니다.
- `cancel_workflow`: 멱등하게 동작하는 취소 도구입니다. 추가 작업 생성을 막고 뒤늦게 도착한 결과가 실행 상태를 되살리지 못하게 차단한 뒤, 현재 돌고 있는 작업 턴과 위임된 Background Agent Job에 중지 신호를 보냅니다(진행 중인 모델 호출이 완전히 멈추기까지 잠시 시간이 걸릴 수 있습니다).

정상 완료되거나 실패한 실행은 원래 대화를 자동으로 깨우지만, 직접 취소한 실행은 별도의 완료 알림 이벤트를 보내지 않으므로 확인이 필요하면 Agent에게 상태를 조회해 달라고 요청하십시오.

Console 홈 화면의 백그라운드 활동 영역에서도 읽기 전용으로 Workflow 현황(`site_console:agent:<agent_uid>:workflow` 권한 기준 활성 호출, 상태별 개수, 대기 메모, 기한, `attention` 표시, 오류 요약)을 볼 수 있습니다. 새 실행 시작, 작업 메시지 전송, 전체 결과 본문 조회, 실행 취소는 메인 Agent의 Workflow 도구를 통해 수행합니다.

## 비용과 용량 제어하기

개별 작업 시도 하나하나는 독립된 모델 턴을 온전히 소비하며 유료 Web 검색·추출 호출을 동반할 수도 있습니다. 동시 실행 수를 늘리면 전체 완료 시간은 단축되지만 총 모델 호출 횟수가 줄어드는 것은 아니므로, 입력 규모에 맞춰 적절한 호출 상한을 걸고 개별 작업 프롬프트와 반환 스키마를 간결하게 유지하십시오.

| 제한 항목 | 기본값 | 하드 상한 |
|---|---:|---:|
| 단일 실행 내 동시 작업 수 | 8 | 32 |
| 단일 Agent 전체에서 실행 중인 Workflow 작업 수 | 8 | 64 |
| 단일 실행 내 총 서브에이전트 호출 수 | 32 | 1,024 |
| 깨어남 구간당 최대 시도 횟수 | 최대 3 | 3 |
| 단일 서브에이전트 호출당 최대 `sleep` 횟수 | — | 16 |
| 단일 `sleep` 지속 시간 | — | 1분~48시간 |
| 저장 가능한 프로그램 코드 크기 | — | 256 KiB |
| 저장 가능한 입력 `args` 크기 | — | 64 KiB |
| 단일 호출 인수 객체 크기 | — | 8 KiB |
| 상위 세션에서 보내는 단일 작업 메시지 크기 | — | 8 KiB |
| 단일 작업이 제출하는 결과값 크기 | — | 24 KiB |
| 영구 memo 누적 예산 | — | 6 MiB |
| 최종 집계 결과 크기 | — | 1 MiB |

표의 처음 세 가지 인스턴스 기본 한도는 관리자가 [AppConfigure](../app-configuration/)에서 하드 상한 이내로 조정할 수 있으며, 개별 실행 요청에서 인스턴스 배포 한도를 넘어서는 값을 지정할 수는 없습니다. Workflow 전체를 묶는 별도의 토큰·금액 총량 예산은 없으며, 대신 각 서브에이전트 작업마다 일반 턴의 최대 반복 횟수, 출력 토큰, 비활성 타임아웃 제한이 동일하게 적용됩니다. 비용 통제 전반은 [비용 관리](../cost-management/)를 참조하십시오.

실행 중 데이터 크기 한도에 걸리면 병렬 팬아웃 수를 줄이거나 각 서브에이전트가 더 압축된 요약만 반환하게 수정하고, 입력이 크다면 여러 번의 Workflow로 나누어 실행하십시오. 오케스트레이션 코드나 입력 데이터를 고쳐야 할 때는 새 Workflow 실행을 시작해야 하며, 이미 실패한 실행의 코드를 수정해 중간부터 이어갈 수는 없습니다.
