---
title: 비용 관리
description: Ankole의 비용 지출을 제어하는 핵심 레버 — 모델 프로필 계층, 추론 강도(reasoning effort), 웹 도구 활성화 조건, 에이전트 루프 예산, Workflow 팬아웃, 백그라운드 작업 재시도 및 슬롯 상한을 안내합니다.
section: Guides
order: 314
---

Ankole에서 발생하는 지출의 대부분은 모델 토큰 비용이며, 통제하기 어려운 돌발 사용량보다는 몇 가지 핵심 구성 레버를 어떻게 설정하느냐에 따라 좌우됩니다. 이 문서에서는 각 레버의 역할과 절감 효과, 그리고 청구 금액이 예상보다 높을 때 어떤 순서로 점검하고 조정해야 하는지 설명합니다. 여기에 소개하는 레버는 모두 컨트롤 플레인에 실제로 마련된 제어 수단이며, 막연히 “Agent를 덜 쓰라”는 식의 조언은 다루지 않습니다.

먼저 기본 원리를 짚자면, 비용은 *어떤 모델이, 몇 번, 얼마나 길게 실행되는가*에 비례합니다. 일곱 가지 레버는 이 세 변수에 각각 대응합니다. 모델 프로필 계층은 투입할 모델을 결정하고, 에이전트 루프 예산은 턴당 반복 횟수를 제한하며, Workflow 및 백그라운드 작업 상한은 병렬 확산(fanout)과 재시도 횟수를 제어합니다. 실제로 지출이 집중되는 구간에 맞춰 알맞은 레버를 조정하세요.

## 레버 1: model-profile 계층

모델 프로필(Model Profile)은 **Console → Model Profiles**의 3계층 희소 상속 체인(`Site -> Pod -> Agent/System`)을 따라 해석됩니다. 각 Agent는 8개의 기본 슬롯(언어 모델 5개와 `web_search`, `web_fetch`, `image_generate`)을 제공하며, Site·Pod 및 내장 `system` Principal(`ankole_brain`, `system`)은 `rerank`와 `decision` 슬롯을 추가로 제공합니다. 비워 둔 슬롯은 Pod와 Site 기본값을 상속하며 `coding -> heavy -> primary` 및 `light -> primary` 슬롯 간 폴백이 적용됩니다.

| 슬롯 | 실행 시점 | 비용 레버 |
|---|---|---|
| `primary` | 주력 추론 모델 — 대부분의 일반 턴 | 단일 최대 비용 항목 |
| `light` | 대량 처리·저위험 경로(미설정 시 `primary`로 폴백) | 대량 작업이 `primary` 단가로 과금되지 않도록 저렴한 모델을 연결해야 함 |
| `heavy` | 고난도 종합(synthesis) 작업 및 Dreaming | 단가가 높음. `primary`가 적절히 설정되어 있으면 드물게 호출됨 |
| Background Agent Jobs(내부 키 `coding`) | 모든 Background Agent Job(`coding -> heavy -> primary` 폴백) | 장기 백그라운드 작업에 사용할 프로바이더와 모델 선택 |
| `vision_fallback` | `primary` 모델이 이미지를 처리할 수 없을 때 | Agent가 이미지를 읽어야 할 때만 바인딩 |
| `web_search`, `web_fetch` | 웹 도구 | 레버 3 참조 |
| `image_generate` | 이미지 생성 | 호출당 단가가 높음. 실제로 사용할 때만 바인딩 |
| `rerank`(Site / Pod / `system`) | Brain 회상 재순위화 및 `/rerank` 기본 경로 | 빠르고 저렴한 전용 리랭커 모델 연결 권장 |
| `decision`(Site / Pod / `system`) | `/decisions`의 확률 포함 답변 | 결정 모델 연결 권장. 비워 두면 `light` 모델이 답변 |

컨트롤 플레인 서브시스템의 모델 호출은 내장 `system` Principal 명의로 실행되므로 백그라운드 유지보수나 Applet이 포그라운드 Agent의 토큰 할당량을 소모하지 않습니다.

- **`ankole_brain`**: 모든 Company Brain 모델 호출을 실행하고 사용량을 `ankole_brain`에 기록합니다. 대화 및 Source 사실 추출에는 `light`(미설정 시 `primary`), Dreaming과 Skill 교훈 재검토에는 `heavy`(미설정 시 `primary`), URL Source 가져오기에는 `web_fetch`, 회상 재순위화에는 `rerank` 프로필을 해석하며, 임베딩 생성에는 [AppConfigure](../app-configuration/)의 사이트 단위 `brain.embedding_model` 키를 읽습니다. Brain 유지보수 예산을 포그라운드 Agent와 분리하고 싶다면 **Console → Model Profiles**에서 `ankole_brain`의 각 슬롯을 개별 재정의할 수 있으며, **Brain → 상태** 화면에서 프로필 준비 상태를 확인할 수 있습니다(자세한 동작은 [Brain](../brain/) 참조).
- **`system`(Pod Applet `ctx.ai`)**: 무상태 Pod Applet `ctx.ai` 호출을 `system` Principal로 실행하며 유효 Pod/Site 언어 모델 프로필(`primary`, `light`, `heavy`, `coding`, `vision_fallback`)을 사용합니다.

가장 효과가 큰 두 가지 절감 조치는 다음과 같습니다.

- **Site 또는 Pod 수준에서 `light`에 저렴한 모델을 연결하세요.** `light`는 비워 두면 `primary`로 폴백하며, 대량 보조 경로와 `ankole_brain` 사실 추출을 모두 담당합니다. 기본 계층에서 경량 모델을 지정해 두면 이를 상속하는 모든 Agent와 `ankole_brain`의 비용이 함께 절감됩니다.
- **`primary`는 균형 잡힌 등급에서 시작하고, 꼭 필요한 전문 Agent만 상향하세요.** 유독 비용이 많이 나오는 Agent를 살펴보면 실제 맡은 업무에 비해 과도하게 무거운 모델이 `primary`에 연결된 경우가 많습니다. 결과 품질상 상위 모델이 꼭 필요한 전문 Agent에만 `primary`나 `heavy`를 재정의하세요.

Pod나 Agent가 쓰지 않는 선택적 capability 슬롯은 비워 두세요. 예를 들어 `vision_fallback`을 비워 두면 해당 경로로는 호출 자체가 일어나지 않습니다. 다만 `image_generate` 프로필은 비워 두더라도 주 프로바이더가 네이티브 이미지 생성을 지원한다고 선언하면 해당 기능을 사용할 수 있습니다. Background Agent Jobs(`coding`) 역시 비워 두면 AIGateway를 통해 `heavy -> primary` 순서로 폴백하여 실행되므로, 백그라운드 작업에 전용 코딩 모델이나 구독 풀을 지정하고 싶을 때 `coding` 슬롯을 구성하세요.

## 레버 2: reasoning effort

Codex 추론 강도 설정을 지원하는 프로바이더에서 `model_reasoning_effort`는 `minimal | low | medium | high | xhigh | max | ultra`의 7단계로 조절할 수 있습니다. 단계를 낮추면 응답이 빠르고 저렴해지며, 단계를 높이면 까다로운 문제에서 더 정교한 결과를 얻는 대신 토큰 비용이 늘어납니다. 기본값은 `high`입니다.

이 설정은 모델 자체를 교체하는 것보다 훨씬 세밀하게 비용을 조절할 수 있는 수단입니다. `medium`으로도 충분한 일상 업무를 처리하는 Agent에 `high`를 그대로 두면 체감 품질 차이는 거의 없는데 비용만 더 지출하게 됩니다. 각 Agent의 `primary` 프로필에서 실제 업무 난도에 맞게 단계를 낮추고, 깊은 종합 추론을 맡는 특정 Agent에만 높은 단계를 부여하세요. 모든 Agent에 일괄로 높여 두는 것은 피해야 합니다.

## 레버 3: web 도구, 필요할 때만

`web_search`와 `web_fetch`는 각각 독립된 프로필이며 호출할 때마다 비용이 발생합니다. 다음 두 가지 원칙으로 관리하세요.

- **웹 접근이 필요 없는 Agent에서는 바인딩을 해제하세요.** 사내 데이터만 다루는 어시스턴트에는 `web_search`를 연결하지 않는 편이 좋습니다. 프로필이 연결되어 있으면 모델은 언제든 해당 도구를 호출할 수 있는 것으로 간주합니다.
- **확인할 URL을 이미 알고 있다면 `web_search` 대신 `web_fetch`를 사용하세요.** 정해진 주소를 바로 가져오면 호출 한 번으로 끝나지만, 검색을 실행하면 검색 호출 비용에 더해 결과 페이지를 읽으려는 후속 `web_fetch` 호출까지 연달아 붙습니다.

참고로 `agent_workers.rendered_fetch_idle_ttl_ms` AppConfigure 키는 렌더링 기반 `web_fetch`에 쓰이는 유휴 브라우저 사이드카 라우트를 정리하기까지의 대기 시간(idle timeout)을 제어할 뿐, URL 응답 캐시로 동작하지는 않습니다.

## 레버 4: agent-loop 예산 및 콜드 웨이크 세션 회전

테넌트 범위(`scope: :tenant`) [AppConfigure](../app-configuration/) 키는 단일 턴 지출 상한을 제어하고 장기 스레드에서 프롬프트 캐시 만료 후 전체 이력이 반복 재과금되는 현상을 방지합니다.

| 키 | 제어 대상 |
|---|---|
| `ai_agent.max_iterations` | 턴당 에이전트 루프의 최대 반복(iteration) 횟수 |
| `ai_agent.max_output_tokens` | 턴당 최대 출력 토큰 수 |
| `ai_agent.inactivity_timeout_ms` | 무응답 상태인 턴을 회수하기까지의 유휴 허용 시간 |
| `sessions.wake_recycle` | 콜드 웨이크 모델 대화 회전 정책(`min_cold_gap_seconds`: `3600`, `min_context_tokens`: `128000`, `im_max_idle_seconds`: `259200`) |

불필요하게 길어지는 에이전트 루프를 잡아 주는 핵심 키는 `max_iterations`입니다. 도구를 두 번만 호출하면 끝날 일에 열 번씩 도구를 호출하면 모델 호출도 열 번 발생합니다. 이 상한을 낮추면 Agent가 제한된 횟수 안에 결론을 정리하도록 유도할 수 있습니다. `max_output_tokens`는 한 번에 생성하는 응답 길이를 제한합니다. 이 `ai_agent.*` 키들은 테넌트 범위 기본값(`scope: :tenant`, 테넌트 재정의가 없으면 사이트 기본값 상속)으로 동작합니다. 평소 일반적인 턴의 길이에 맞춰 설정하되, 복잡한 턴이 반복 상한에 도달하면 “지금까지 확보한 정보를 바탕으로 정리한 최종 답변” 형태로 마무리될 수 있다는 점을 감안하세요.

한편 업스트림 프로바이더의 프롬프트 캐시가 만료된 뒤 거대한 누적 컨텍스트를 그대로 재개하면 다음 턴에서 전체 입력 토큰이 캐시 미적용 단가로 다시 청구됩니다. `sessions.wake_recycle`은 이러한 콜드 캐시 재과금을 막아 줍니다. Session이 `min_cold_gap_seconds`(기본 `1`시간) 이상 유휴 상태였다가 `min_context_tokens`(기본 `128,000` 토큰) 이상의 컨텍스트로 깨어나거나, 외부 메신저 채널에서 `im_max_idle_seconds`(기본 `72`시간) 이상 지난 뒤 재개되면, Ankole은 공개 채팅방 메시지 기록을 그대로 유지한 채 핵심 맥락을 담은 `<wake-briefing>`으로 새 AIGateway 모델 대화 브랜치를 시작합니다.

## 레버 5: Workflow fanout 및 task 시도

Workflow에서 실행되는 각 `agent()` 시도는 완전한 모델 턴 하나와 같습니다. 호출 하나당 최대 3회까지 재시도할 수 있으므로, 메인 대화에서는 Workflow를 한 번만 실행했더라도 내부에서 수많은 호출을 뻗어 내면 모델 및 웹 도구 사용량이 크게 증폭될 수 있습니다.

| AppConfigure 키 | 기본값 | 최대값 | 제어 대상 |
|---|---:|---:|---|
| `workflow.max_concurrency_per_run` | 8 | 32 | 단일 run에서 동시에 실행할 수 있는 task 수 |
| `workflow.max_running_per_agent` | 8 | 64 | 단일 Agent의 여러 run에 걸쳐 동시에 실행 중인 Workflow task 수 |
| `workflow.max_agent_calls_per_run` | 32 | 1,024 | 단일 run에서 생성할 수 있는 총 서브에이전트 호출 수 |

동시 실행 수(concurrency)를 높이면 전체 소요 시간만 줄어들 뿐 총 모델 호출 횟수는 줄어들지 않습니다. 입력 규모를 먼저 제한해 총 호출 한도를 정하고, 동시성은 배포 환경에 꼭 필요한 수준으로만 요청하세요. 개별 run 생성 요청에서 더 낮은 `concurrency`와 `max_agent_calls` 값을 지정할 수는 있지만, 여러 run에 걸친 한도인 `workflow.max_running_per_agent`를 덮어쓰거나 AppConfigure에 설정된 상한보다 높은 값을 요청할 수는 없습니다.

Workflow 전체를 묶는 별도의 일괄 토큰 한도나 금액 예산은 없으며, 각 task에는 일반 턴과 동일한 반복 횟수, 출력 토큰, 유휴 시간 상한이 적용됩니다. 각 task에는 좁고 명확한 프롬프트와 간결한 구조화 출력을 지정하고, `null` 실패 반환을 안전하게 처리하며, 집계 대상이 너무 크면 여러 번의 run으로 나누어 실행하세요. 세부 task 및 결과 크기 한도는 [Workflows](../workflows/)를 참조하세요.

## 레버 6: background-job 재시도 및 슬롯 상한

백그라운드 작업은 재시도 과정에서도 토큰을 소비하므로 다음 상한 값들이 비용 제어 레버 역할을 합니다.

| 상한 | 값 | 효과 |
|---|---|---|
| `max_execution_attempts` | 5 | 최대 5회 시도 후 `failed` 처리 |
| `max_consecutive_turn_failures` | 5 | 작업을 중단하기 전 허용하는 연속 턴 실패 횟수 |
| `max_running_per_agent` | 3 (기본값) | Agent당 동시 실행 Job 상한. 테넌트별로 `background_agent_jobs.max_running_per_agent`(`1..64`)에서 조정 가능 |
| retry delay | ~30s | 재시도 사이의 최소 대기 간격 |

일시적인 오류로 다섯 번 연속 실패하는 작업은 다섯 번 실행한 만큼의 토큰을 소비합니다. 일반적인 상황에서는 기본 상한만으로도 과도한 재시도를 막을 수 있으며, 설정 오류는 즉시 실패 처리된 뒤 멈춥니다. 특히 눈여겨볼 항목은 세 번째인 `max_running_per_agent`입니다. 한 Agent가 세 개의 Job을 동시에 돌리면 세 개의 모델 루프가 한꺼번에 토큰을 소비합니다. 그만한 병렬 처리가 필요하지 않다면 상한 값을 낮추거나 페르소나에 “한 번에 하나의 작업만 진행하라”고 명시하는 편이 훨씬 경제적입니다.

## 레버 7: Agent별 token quota

앞선 여섯 가지 레버가 개별 턴이나 작업 단위의 지출을 조절한다면, 토큰 할당량(token quota)은 누적 총량을 제한합니다. 특정 Agent가 지정된 반복 주기 동안 소비할 수 있는 총 토큰 수를 정해 두면, 사용량이 한도에 도달하는 순간부터 현재 주기가 끝날 때까지 AIGateway가 해당 Agent의 모델 호출을 차단합니다.

이 설정은 Agent 상세 페이지에서 구성하며 주기(일 단위), 주기 시작 시각, 토큰 한도를 입력합니다. 화면에는 한도 대비 현재 사용률과 이번 주기의 종료 시각이 표시됩니다. 한도에 도달한 상태에서 채팅 메시지가 들어오면 Ankole은 현재 사용한 토큰 수, 설정된 한도, 주기 종료 시각을 안내하는 답장을 보냅니다. 한도가 소진된 상태에서 실행되는 Background Agent Job은 대기하지 않고 즉시 실패 처리됩니다. 정당한 업무량 급증으로 당장 실행을 이어 가야 한다면 **주기 재설정**을 눌러 새 주기를 즉시 시작할 수 있습니다.

토큰 할당량은 세밀한 예산 배분 도구가 아니라 과금 폭주를 막는 안전장치로 활용하세요. 한도에 가까워진다고 해서 Agent가 스스로 호출 빈도를 늦추지는 않으며, 이미 시작된 호출 하나는 그 호출에서 쓴 토큰만큼 한도를 살짝 넘긴 뒤 종료될 수 있습니다. 아래 방법으로 평소 사용량을 먼저 파악한 뒤, 정상적인 최대 사용 주간보다 여유 있게 한도를 잡는 것이 좋습니다. 세부 설정 필드는 [Agents](../agents/)를 참조하세요.

## 지출이 실제로 발생하는 곳

모델이나 동시성 설정을 바꾸기 전에 먼저 어떤 Agent, 대화, Workflow, 또는 Background Agent Job에서 호출이 집중되었는지 확인하세요.

- `GET /api/v2/ai-gateway/conversations`를 조회하면 최근 턴들이 수행한 모델 호출 내역을 볼 수 있습니다. 어떤 프로필이 선택되었는지, 몇 번 호출되었는지, 어느 프로바이더로 나갔는지를 바로 파악할 수 있어 비용 원인이 `primary`(호출량 과다), `heavy`(소수의 고비용 호출), `web_search`(다수의 소액 검색 호출) 중 어디에 있는지 가장 빠르게 가려낼 수 있습니다.
- Workflow 상태는 메인 Agent에게 조회를 요청하세요. 생성된 task 수를 보면 전체 팬아웃 규모와 실패한 호출 비중을 파악할 수 있습니다(별도의 Workflow 전용 콘솔 화면이나 run당 금액 합산 기능은 제공되지 않습니다).
- `GET /api/v2/background-agent-jobs`에서는 각 Job의 `attempts` 횟수를 확인할 수 있습니다. `attempts: 5`로 표시된 Job은 재시도를 포함해 다섯 번 실행된 작업입니다.
- 구조화된 컨트롤 플레인 로그에는 프로바이더 호출 이벤트 이름과 세부 필드가 기록되므로, 로그 수집 시스템에서 프로바이더별·Agent별로 손쉽게 집계할 수 있습니다.

결국 올바른 해법은 막연히 “Agent 사용을 줄이는 것”이 아니라, “특정 Agent의 업무 특성에 맞지 않게 잡혀 있는 레버를 찾아 바로잡는 것”입니다.

## 실제 사례

한 배포 환경에서 일주일 만에 청구 금액이 두 배로 뛴 사례가 있었습니다. conversations 내역을 확인해 보니 `primary` 호출 수는 평소와 같았지만 `web_search` 호출이 10배로 급증해 있었습니다. 원인은 `may_intervene`가 켜진 팀 어시스턴트 Agent가 채널에 올라오는 모든 메시지마다 웹 검색을 돌리기 시작한 데 있었습니다. 이때 필요한 조치는 토큰 상한 조정이 아니라 페르소나 수정(“사용자가 사실 확인 질문을 했을 때만 검색하라”)이었습니다. 높은 청구 금액은 모델의 판단 기준이 잘못 잡혔다는 신호였고, 그 판단 기준을 정의하는 곳이 바로 페르소나이기 때문입니다.

비용 문제의 상당수는 이 패턴을 따릅니다. 겉으로는 요금 문제처럼 보이지만 실제로는 Agent의 행동 방식 문제인 경우가 많으며, 행동을 교정하는 수단은 토큰 한도가 아니라 페르소나와 바인딩 정책입니다.

## 비용 관리가 아닌 것

여기서 설명한 기능은 실시간 요금 대시보드가 아니며, Ankole은 별도의 금액 대시보드를 내장하고 있지 않습니다. 또한 달러 등 통화 단위로 지출 상한을 직접 걸어 두는 기능도 아닙니다. 각 레버가 제어하는 대상은 *호출 횟수와 반복 횟수*이며, 실제 청구 금액은 여기에 각 프로바이더의 단가가 곱해져 결정됩니다. 마지막으로, 어떤 레버도 conversations 호출 내역 확인을 대신해 주지는 않습니다. 어디서 비용이 새고 있는지 먼저 파악해야 레버 조정도 효과를 발휘합니다.

## 다음 단계

- Agent의 모델 프로필 구성은 [Agents](../agents/#모델-구성) 문서를 참조하세요.
- `ai_agent.*`를 비롯한 런타임 설정 키는 [AppConfigure](../app-configuration/) 문서를 참조하세요.
- 관련 conversation 및 Job 조회 엔드포인트는 [Console API reference](../console-api/) 문서를 참조하세요.
- 서브에이전트 팬아웃 제어와 실행 한도는 [Workflows](../workflows/) 문서를 참조하세요.
- 백그라운드 작업 상한은 [Background Agent Jobs](../background-jobs/) 문서를 참조하세요.
