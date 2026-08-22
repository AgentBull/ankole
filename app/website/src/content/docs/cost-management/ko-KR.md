---
title: 비용 관리
description: Ankole이 지출하는 금액을 통제하는 레버 — model-profile 계층, reasoning effort, web 도구 게이팅, agent-loop 예산, background-job 재시도 및 슬롯 상한.
section: Guides
order: 314
---

Ankole이 지출하는 비용의 대부분은 model token이며, 그중 대부분은 사용자가 통제할 수 없는 사용량이 아니라 소수의 구성 레버(configuration lever)에 의해 결정됩니다. 이 페이지는 각 레버의 이름과 각각이 어떤 비용을 들이고 무엇을 절약하는지, 그리고 청구 금액이 너무 높을 때 잡아당겨야 할 순서를 설명합니다. 여기 나오는 모든 레버는 control plane의 실제 노브(knob)이며, “Agent를 덜 사용하라”는류의 조언은 없습니다.

중요한 속성을 먼저 밝히자면, 비용은 *어떤 model이 몇 번, 얼마나 오래 실행되는지*의 함수입니다. 레버는 이 세 가지에 대응합니다. model-profile 계층은 model을 선택하고, agent-loop 예산은 반복 횟수를 제한하며, job 재시도 및 슬롯 상한은 폭주하는 경우를 묶어 둡니다. 지출이 발생하는 지점에 맞는 레버를 당기세요.

## 레버 1: model-profile 계층

10개의 profile 슬롯이 가장 큰 레버입니다. 각 슬롯은 model 선택이며, model 선택이 token 비용을 좌우합니다.

| 슬롯 | 실행 시점 | 비용 레버 |
|---|---|---|
| `primary` | 주요 reasoning model — 대부분의 turn | 단일 최대 비용 항목 |
| `light` | 대량·저위험 경로 | 저렴해야 함 |
| `heavy` | 어려운 종합(synthesis) 작업 | 비쌈. `primary`가 잘 조정되면 거의 사용되지 않음 |
| Background Agent Jobs(내부적으로는 `coding`) | 모든 Background Agent Job | 지속적인 백그라운드 작업의 provider와 model을 선택 |
| `vision_fallback` | `primary`가 이미지를 처리할 수 없을 때 | agent가 이미지를 볼 때만 바인딩 |
| `embedding`, `rerank` | memory 및 검색(retrieval) | 호출당 과금, 보통 소액 |
| `web_search`, `web_fetch` | web 도구 | 레버 3 참조 |
| `image_generate` | 이미지 생성 | 호출당 비쌈. 사용할 때만 바인딩 |

가장 많이 절약하는 두 가지 조치:

- **`light`를 저렴한 model에 바인딩하세요.** 이 슬롯은 대량 처리 경로를 위해 존재합니다. `primary`와 비슷한 비용의 `light`는 슬롯의 의미를 무너뜨립니다.
- **기본적으로 `primary`를 낮추지 올리지는 마세요.** “비싸게 느껴지는” agent는 실제로 수행하는 작업에 비해 너무 무겁게 바인딩된 `primary`인 경우가 많습니다. 품질이 요구할 때만 올리세요.

agent가 사용하지 않는 슬롯은 바인딩을 해제하세요. 그러면 `vision_fallback`에서 호출이 발생할 수 없습니다. 비어 있는 `image_generate` profile도 메인 provider가 해당 기능을 선언하면 네이티브 이미지 생성(native image generation)을 계속 사용할 수 있습니다. Background Agent Jobs는 다릅니다. profile이 설정되어 있지 않아도 Job은 AIGateway를 통해 Agent의 `heavy` profile을 폴백으로 사용하여 실행됩니다. Job에 다른 provider나 model이 필요할 때 이 profile을 구성하세요.

## 레버 2: reasoning effort

Codex reasoning effort를 지원하는 provider에서 `model_reasoning_effort`는 7단계 다이얼입니다: `minimal | low | medium | high | xhigh | max | ultra`. 낮은 effort는 더 저렴하고 빠르며, 높은 effort는 어려운 문제에서 더 좋은 결과를 내고 비용이 더 듭니다. 기본값은 `high`입니다.

이것은 model을 바꾸는 것보다 더 세밀한 레버입니다. `primary`가 `medium`으로 충분한데 `high`로 설정된 agent는 눈에 보이는 이득 없이 더 많은 비용을 지출합니다. `primary` profile에서 agent의 실제 작업에 맞게 설정하고, 어려운 종합 작업을 하는 한 agent에게만 올리세요. 모든 agent에 올리면 안 됩니다.

## 레버 3: web 도구, 필요할 때만

`web_search`와 `web_fetch`는 독립적인 profile이며 호출할 때마다 비용이 듭니다. 두 가지 조치:

- **agent가 web이 필요하지 않으면 바인딩을 해제하세요.** 내부 전용 assistant는 `web_search`가 바인딩되어 있으면 안 됩니다. 슬롯이 존재한다는 것 자체가 호출 허가증이 됩니다.
- **URL을 알고 있으면 `web_search`보다 `web_fetch`를 사용하세요.** 알려진 소스를 fetching하는 것은 한 번의 호출입니다. 검색은 한 번의 호출에 더해 agent가 하기로 결정한 fetch가 추가됩니다.

`worker.rendered_fetch_idle_ttl_ms` AppConfigure 키는 렌더링된 fetch 결과가 캐시되는 시간을 제어합니다. TTL이 높을수록 같은 URL의 반복 fetch를 절약하지만 데이터가 오래될(staleness) 수 있습니다.

## 레버 4: agent-loop 예산

세 개의 AppConfigure 키가 turn당 지출을 제한합니다:

| 키 | 제한 대상 |
|---|---|
| `ai_agent.max_iterations` | turn당 agent loop의 iteration 예산 |
| `ai_agent.max_output_tokens` | turn당 output token 상한 |
| `ai_agent.inactivity_timeout_ms` | turn이 회수되기 전까지 비활성 상태로 있을 수 있는 시간 |

`max_iterations`는 수다스러운 agent loop를 제한하는 키입니다. 두 번이면 충분할 자리에 열 번 도구를 호출하는 loop는 model을 열 번 사용합니다. 상한을 낮추면 agent가 수렴하게 됩니다. `max_output_tokens`는 각 응답의 크기를 제한합니다. 이것들은 instance 전체의 기본값입니다. 일반적인 turn의 형태에 맞게 설정하고, 어려운 turn이 상한에 걸려 “가지고 있는 내용을 종합하라”는 최종 답변이 나올 수 있다는 점을 받아들이세요.

## 레버 5: background-job 재시도 및 슬롯 상한

Background job은 재시도에 token을 쓸 수 있으며, 그 상한이 레버입니다:

| 상한 | 값 | 효과 |
|---|---|---|
| `max_execution_attempts` | 5 | 최대 5회 재시도 후 `failed` |
| `max_consecutive_turn_failures` | 5 | job이 포기하기 전 연속 turn 실패 횟수 |
| `max_running_per_agent` | 3 | agent당 최대 3개의 실행 중인 job |
| retry delay | ~30s | 재시도 사이의 최소 간격 |
| `agent_computer.background_agent_job.max_turns_per_worker` | 구성 가능 | job에 대한 worker별 turn 상한 |

일시적으로 다섯 번 실패하는 job은 다섯 번 실행한 만큼의 token을 소비합니다. 대부분의 경우 상한이 보호해 줍니다. 구성 오류는 빠르게 실패하고 실패 상태로 유지됩니다. 주의할 레버는 세 번째입니다. 동시에 세 개의 job을 실행하는 agent는 한 번에 세 개의 model loop를 돌리는 것입니다. 그런 병렬성이 필요 없다면 persona(“한 번에 한 가지 일을 하라”)가 상한이 허용하는 것보다 더 저렴합니다.

## 지출이 실제로 발생하는 곳

model이나 동시성을 바꾸기 전에 Console을 사용하여 호출을 발생시킨 Agent, conversation 또는 Background Agent Job을 찾으세요:

- `GET /ai-gateway/conversations`는 최근 turn이 수행한 model 호출을 보여 줍니다. 어떤 profile이 해석되었는지, 몇 번 호출했는지, 어떤 provider인지. 이것은 지출이 `primary`(볼륨), `heavy`(몇 번의 비싼 호출) 또는 `web_search`(많은 소액 호출) 중 어디에 있는지 확인하는 가장 빠른 방법입니다.
- `GET /background-agent-jobs`는 job의 `attempts`를 보여 줍니다. `attempts: 5`인 job은 다섯 번 실행된 것입니다.
- 구조화된 control-plane 로그에는 provider 호출의 이벤트 이름과 필드가 포함됩니다. 로그 수집기(log ingester)에서 provider별, agent별로 집계할 수 있습니다.

해결 방법은 결코 “Agent를 덜 사용하라”가 아닙니다. “이 특정 agent의 작업에 대해 이 특정 레버가 잘못 설정되어 있다”가 해결 방법입니다.

## 실제 사례

deployment instance의 청구 금액이 일주일 만에 두 배가 되었습니다. conversations 화면에서 `primary` 호출은 정상이지만 `web_search` 호출은 10배로 늘었습니다. `may_intervene`가 설정된 팀 어시스턴트 agent가 모든 channel 메시지에서 검색을 시작한 것입니다. 해결 방법은 비용 레버가 아니라 persona(“누군가 사실 질문을 할 때만 검색하라”)입니다. 청구 금액은 판단 문제의 증상이었고, 판단이 사는 곳은 persona입니다.

이것이 패턴입니다. 비용 문제는 흔히 위장된 행동 문제이며, 행동 레버는 token 상한이 아니라 persona 또는 binding policy입니다.

## 비용 관리가 아닌 것

이것은 실시간 지출 대시보드가 아닙니다. Ankole은 그러한 대시보드를 제공하지 않습니다. 달러 금액으로 지출을 상한하는 방법도 아닙니다. 레버는 *호출과 반복 횟수*를 제한하며, 달러 금액은 provider의 요율에 그것들을 곱한 값입니다. 그리고 conversations 화면을 읽는 것의 대체재도 아닙니다. 어떤 레버가 잘못 설정되었는지 알아야만 레버를 당길 가치가 있습니다.

## 다음 단계

- Agent의 model profile에 대해서는 [Agents](../agents/#모델-구성) 문서를 읽으세요.
- agent-loop 노브와 해당 키에 대해서는 [Environment variables](../environment-variables/) 문서를 읽으세요.
- 관련 conversation 및 Job 엔드포인트에 대해서는 [Console API reference](../console-api/) 문서를 읽으세요.
- Job 상한에 대해서는 [Background Agent Jobs](../background-jobs/) 문서를 읽으세요.