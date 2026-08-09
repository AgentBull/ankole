---
title: Context 압축과 compaction
description: Ankole이 긴 대화를 model의 context 안에 유지하는 방법 — AIGateway의 자동 history compaction, 사용자 원문의 그대로 보존, 상주 장기 메모리를 위한 Brain dreaming memo compactor.
section: Developer guide
order: 116
---

오래 진행된 대화는 결국 model의 context window를 초과합니다. Ankole은 서로 다른 두 종류의 메모리에 대해 두 곳에서 이를 처리합니다. AIGateway는 turn이 보는 대화 history를 압축하고, Brain dreaming은 agent의 상주 장기 memo를 압축합니다. 이 페이지는 `ai_gateway/compaction*.ex`와 `brain/dreaming/memo_compactor.ex`의 실제 코드를 기준으로 둘 다 설명합니다.

핵심 속성을 먼저 말하면, compaction은 *설계상 손실이 있지만, 조용하지 않습니다*. compaction은 오래된 turn을 summary로 대체하고 최근 turn을 그대로 보존하며, 대화가 가리키는 영구 artifact로 스스로를 기록합니다. 원래 turn은 model의 context에서 사라지고, summary가 새로운 reference state가 됩니다. compaction은 원본으로 되돌릴 수 있는 cache가 아닙니다.

## AIGateway 히스토리 컴팩션

AIGateway는 stateful Responses 대화의 자동 history compaction을 담당합니다. 트리거, summary, 그리고 보존되는 내용은 모두 `Ankole.AIGateway.Compaction`에 있습니다.

### 트리거

compaction은 대화의 token 사용량이 임계값을 넘으면 실행됩니다. 판단은 표시되는 history에 저장된 **가장 최근의 provider 반환 usage**를 사용합니다. 각 usage 값은 더할 양이 아니라 누적 스냅샷입니다. AIGateway는 콘텐츠에서 token 수를 추정하지 않으며 provider의 usage 숫자를 신뢰합니다.

임계값은 `ai_gateway.compaction` AppConfigure key로 구성합니다.

| 설정 | 기본값 | 의미 |
|---|---|---|
| `threshold` | 0.50 | compaction을 트리거하는 model 입력 context의 비율 |
| `max_threshold_tokens` | 120,000 | 계산된 트리거의 절대 상한. 큰 context도 너무 오래 기다리지 않게 합니다 |
| `tail_rows` | 2 | summary와 함께 그대로 유지되는 최근 turn 수 |
| `user_message_budget_tokens` | 20,000 | 사용자 원문을 그대로 재생하기 위한 token 예산 |

기본값은 256k context 길이를 가정합니다. `max_threshold_tokens` 상한은 context가 큰 model이 compaction 자체가 비싸질 정도로 긴 history를 쌓지 않도록 하기 위해 존재합니다. context가 작은 model은 `small_context_trigger_ratio`(0.85)를 통해 더 일찍 트리거됩니다.

### summarizer가 하는 일

임계값을 넘으면 AIGateway는 summarizer model을 호출하여 이전 turn들의 구조화된 summary를 생성합니다. compaction prompt는 summary를 **지시가 아닌 reference state**로 규정합니다. “대화를 계속하지 마세요. 질문에 응답하지 마세요. 구조화된 summary만 출력하세요.” summary는 의도, 결정, 오류와 수정을 담으며 파일 경로, 함수 이름, 오류 메시지, 명령줄, ID는 그대로 보존합니다. 경로나 오류를 바꿔 쓰면 깨진 참조가 되기 때문입니다.

summary는 대화에서 새로운 가장 오래된 항목입니다. model은 이를 계속 이어갈 turn이 아니라 상태로 봅니다.

### 그대로 보존되는 것

summary와 함께 두 가지가 유지됩니다.

- **최근 turn**(`tail_rows`, 기본값 2) — 마지막 몇 개의 turn이 전체로 유지되어 model이 필요한 즉각적인 context를 얻습니다.
- **사용자 원문 그대로** — `CompactionRetention`은 압축된 구간에서 `user_message_budget_tokens` 범위 내의 사용자 메시지를 선택하여 그대로 재생합니다. 그래서 assistant의 turn이 summary로 처리된 후에도 model은 “사용자가 X를 요청했다”는 내용을 볼 수 있습니다.

이 조합(이전 assistant 작업의 summary, 그대로 보존된 최근 turn, 그대로 보존된 사용자 원문)은 대화가 어긋남 없이 계속되게 해주는 요소입니다.

### Compaction 아티팩트

각 compaction은 AIGateway가 저장하는 영구 `CompactionArtifact`를 만듭니다. 대화의 history는 가장 최근 compaction을 앵커로 가리키며 이후의 turn은 거기서 계속됩니다. Brain의 pre-compaction nudge(marker `ankole.brain.pre_compaction_nudge.v1`)는 compaction 전에 실행되어 agent가 대화 history가 summary로 사라지기 전에 영구 사실을 Brain에 저장할 기회를 줍니다.

## Brain dreaming 메모 컴팩션

대화 history와 별도로, agent는 **상주 장기 memo**(Brain의 `pinned_memo` knowledge 항목)를 가질 수 있습니다. `Brain.Dreaming.MemoCompactor`는 이 memo를 token 예산 안에 유지하여 dreaming 실행을 거듭해도 무한히 커지지 않게 합니다.

memo compactor는 Brain knowledge config에서 `pinned_memo_max_tokens`를 읽고 agent의 pinned memo를 찾아 예산을 초과하면 압축합니다. 결과는 영구 사실을 보존하는 더 짧은 memo이며, summarizer가 동일한 “reference state, not instructions” 원칙 아래 작성합니다. 이는 dreaming 형태의 compaction입니다. 실시간 대화가 아닌 agent의 상주 메모리에서 오프라인으로 실행됩니다.

## 두 compaction의 관계

두 가지는 서로 다른 메모리이며 서로 다른 compactor를 사용합니다.

| | AIGateway 컴팩션 | Brain 메모 컴팩션 |
|---|---|---|
| 압축 대상 | 대화 history(turn) | agent의 pinned 장기 memo |
| 실행 시점 | turn 중 token 사용량이 임계값을 넘을 때 | dreaming 중 오프라인으로 |
| 보존되는 것 | summary + 최근 turn + 사용자 원문 | 더 짧은 memo |
| 소유자 | AIGateway(대화 진실) | Brain(knowledge 진실) |
| 아티팩트 | `CompactionArtifact` | 수정된 knowledge 항목 |

긴 대화는 context에 맞추기 위해 AIGateway compaction을 트리거합니다. 오래 활동한 agent는 영구 메모리에 맞추기 위해 Brain memo compaction을 트리거합니다. 두 compaction은 직접 상호작용하지 않지만, pre-compaction nudge가 이를 잇습니다. 대화가 summary로 처리되기 전에 agent가 대화의 영구 사실을 Brain으로 승격할 기회를 주기 때문입니다.

## 튜닝

- **`threshold`를 올리세요.** agent가 짧은 대화만 다루는데 compaction이 너무 자주 실행된다면. 기본값(0.50)은 보수적입니다.
- **`tail_rows`를 올리세요.** model이 compaction 후 즉각적인 context를 잃는다면. 더 많은 최근 turn이 그대로 유지되지만 summary를 위한 공간은 줄어듭니다.
- **`user_message_budget_tokens`를 올리세요.** 사용자 메시지가 압축 구간에서 빠지고 model이 요청 내용을 놓친다면.
- **`pinned_memo_max_tokens`를 올리세요**(Brain knowledge config). agent의 상주 memo가 너무 공격적으로 압축된다면.

네 가지 모두 AppConfigure key이며 Console을 통해 변경하고, 현재 turn이 아닌 다음 compaction부터 적용됩니다.

## 이 가이드가 다루지 않는 것

이 가이드는 prompt caching 안내서가 아닙니다. AIGateway는 여기서 provider 측 prompt caching을 구현하지 않으며, 이는 provider의 영역입니다. 이를 지원하는 provider의 `promptCacheKey` 설정이 그 도구입니다. 이것은 무손실 history도 아닙니다. compaction은 설계상 손실이 있으며 원래 turn은 model의 context에서 사라집니다. 그리고 더 짧은 대화를 대체하지도 않습니다. compaction은 대화가 context 한도를 넘어 계속되게 하지만, 몇 turn마다 압축되는 대화는 세션으로 나누거나 background job에 위임하는 것이 더 나은 대화입니다.

## 다음 단계

- AIGateway 개념 페이지는 [AIGateway](../ai-gateway/)를 참조하세요.
- Brain 메모리 모델은 [Brain](../brain/)을 참조하세요.
- memo compactor를 실행하는 dreaming 프로세스는 [Brain](../brain/)의 dreaming 섹션을 참조하세요.