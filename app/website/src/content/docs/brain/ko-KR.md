---
title: Brain
description: Ankole 배포 인스턴스의 장기 memory — 큐레이션된 knowledge, 소스 채팅 회상, dreaming, 인간 검토. PostgreSQL 행이 진실이고 Markdown은 그 투영(projection)이다.
section: Developer guide
order: 104
---

Brain은 책임을 지는 하나의 principal의 장기 memory입니다. Brain은 세 가지를 동시에 담습니다: agent가 작업의 기반으로 삼는 큐레이션된 knowledge, 소스 채팅에서 실제로 말해진 내용으로 돌아가는 회상 경로, 그리고 원시 이력을 인덱싱된 에피소드와 제안 knowledge로 바꾸는 dreaming 프로세스입니다. 제안은 사실이 되기 전에 인간이 검토합니다. 이 페이지는 그 모델을 `Ankole.Brain`의 실제 코드에 대응시킵니다.

결정적인 속성을 먼저 밝힙니다: 구조화된 knowledge가 지속적인 진실이고, Markdown은 그 진실의 투영(projection)입니다 — 그 반대가 아닙니다. Brain은 evidence, 큐레이션, 현재 knowledge, 인간 검토를 조정합니다. 채팅 evidence는 여전히 SignalsGateway가 소유하고, Brain은 보존된 소스 바이트, 큐레이션된 knowledge, dreaming 상태, 복구 기록을 소유합니다.

## 범위: 누가 무엇을 볼 수 있나

모든 Brain 읽기와 쓰기는 `Brain.Scope`를 거칩니다. 그 scope는 AIGateway 대화의 선언 — 구체적으로는 `conversation.metadata["brain"]` — 에서만 파생됩니다. channel 이벤트, provider 메타데이터, 주변 런타임 상태는 폴백으로 참조되지 않습니다. scope는 `owner_uid`, `readable_store_keys` 집합, 하나의 `writable_store_key`, `current_channel`을 담습니다. principal을 아우르는 knowledge를 위한 특별한 공유 owner인 `brain-shared`가 존재합니다.

이 라우팅 선택은 의도적입니다. 권한 경계를 운영자가 보고 변경할 수 있는 대화 선언 위에 둠으로써, memory가 마지막으로 말한 사람에게 흘러가도록 두지 않습니다.

## 지속적인 진실과 투영(projection)

이 모델은 명확한 분리에 기반합니다:

- **구조화된 knowledge** — 엔트리, 블록, 관계, 인용 — 은 append-only 감사와 함께 트랜잭션 연산으로 쓰이는 지속적인 진실입니다. 배치는 변경 사항과 감사를 함께 커밋하거나, 부분 상태를 남기지 않습니다.
- **Markdown 투영, 검색 결과, 주입된 컨텍스트**는 그 진실에서 재구성되는 더 저렴한 뷰입니다. 투영을 잃는 것은 불편일 뿐이지만, knowledge 행을 잃는 것은 agent가 믿는 내용의 변화입니다.

모든 읽기는 SQL에서 owner와 readable-store 조건을 적용하므로, scope는 호출자가 우회할 수 있는 애플리케이션 코드가 아니라 데이터베이스 경계에서 강제됩니다.

## 회상: 세 개의 channel, 하나의 결과

agent 턴이 memory를 필요로 할 때, 회상은 두 evidence 소스에 대해 병렬로 실행되고 결과를 병합합니다:

- **채팅 회상**은 SignalsGateway가 미러링한 불변 엔트리를 대화가 볼 수 있는 channel로 범위를 한정해 읽습니다. 회상된 메시지는 신뢰할 수 없는 이력 데이터로 취급되며 결코 지시로 취급되지 않습니다 — 그 취지의 고지가 모든 결과 집합에 함께 실립니다.
- **knowledge 회상**은 큐레이션된 Brain 엔트리와 블록을 읽고, BM25 키워드 후보와 벡터 후보를 임베딩에 대해 모두 사용한 다음, 결과 token 예산 안에서 병합하고 재순위화합니다.
- **검색**은 병합된 진입점입니다. 두 channel을 병렬로 실행하고, 새로운 evidence가 우선되도록 시간 감쇠를 적용한 다음, 각 항목의 출처가 표시된 하나의 순위화된 집합을 반환합니다.

에피소드는 채팅과 knowledge 사이의 다리입니다. 에피소드는 불변의 채팅 계층 사실에 대한 시간 주소 지정이 가능한 요약 인덱스입니다 — topic, 요약, 다루는 소스 엔트리 id, 시간 범위, 임베딩을 담습니다. 에피소드는 명시적으로 탐색 인덱스이며, 함께 제공되는 고지는 모델에게 원본 메시지가 권위 있는 것임을 알려줍니다.

## Dreaming: 이력을 인덱싱된 memory로 바꾸기

Dreaming은 모델 단계에 인간을 개입시키지 않고 원시 채팅 이력을 에피소드와 제안 knowledge로 변환하는 오프라인 프로세스입니다. 빈도와 Job이 다른 두 단계로 실행됩니다.

**Stage A**는 channel 수준의 요약기입니다. 처리되지 않은 엔트리가 있는 channel을 스캔하고 에피소드 요약 Job을 큐에 넣습니다. 각 Job은 가벼운 모델 프로필에 채팅의 한 윈도우를 요약하여 에피소드로 만들도록 요청합니다. channel을 볼 수 있는 agent에 사용 가능한 가벼운 프로필이 없으면 에피소드는 조용히 건너뛰어지지 않고 사용 불가로 보고됩니다. 설정으로 비활성화된 dreaming은 해당 단계를 깔끔하게 중지합니다.

**Stage B**는 빈도가 낮은 principal 수준의 knowledge 큐레이션입니다. 트랜잭션 밖에서 모델 추론을 실행한 다음, 검증된 작은 연산, skill 오버레이 업데이트, 두 material high-water mark를 함께 커밋합니다 — 그래서 부분적으로 적용된 실행은 조용히 건너뛰어지지 않고 재시도됩니다. 출력은 evidence가 딸린 제안 knowledge이며, knowledge 베이스에 대한 조용한 편집이 아닙니다.

두 단계로 나뉜 이유는 Job의 비용과 위험 프로필이 다르기 때문입니다. Stage A는 저렴하고 빈번하며 탐색 보조물을 만듭니다. Stage B는 비싸고 드물며 사실을 제안합니다. 분리해 두면 비싼 Job이 저렴한 Job을 막지 않습니다.

## 쓰기 권한: 누가 무엇을 쓸 수 있나

knowledge 쓰기는 명시적인 `WriteAuthority`를 담고 다섯 가지 모드 중 하나를 가집니다: `:human`, `:agent`, `:dreaming`, `:source_learning`, `:mechanical`. 모드는 쓰기가 무엇을 인용할 수 있고 어떤 document id를 건드릴 수 있는지를 결정합니다. 작성자가 있는 쓰기는 owner, store, 작성자를 신뢰된 scope와 actor에서 파생하며, 연산 페이로드는 이를 덮어쓸 수 없습니다. 작성자가 없는 두 기계적 연산 — `create_entry`와 `delete_block` — 은 내용을 작성할 수 없고 명시적인 인과 표면(causal surface)을 요구합니다.

이것이 Brain이 dreaming과 source-learning 출력이 인간의 결정인 척하지 못하게 하는 방식입니다. dreaming 제안은 dreaming 쓰기이며, 그렇게 표시되고 evidence가 첨부됩니다 — 권위 있는 knowledge로의 조용한 승격은 결코 아닙니다.

## 인간 검토

모델은 감독 없이 knowledge를 편집하지 않으며 자신의 출력을 사실로 제시하지 않습니다. 검토 표면은 console 범위 라우트 뒤에 있습니다:

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/brain/entries` | 큐레이션된 knowledge 엔트리 나열 |
| `GET` | `/brain/entries/:id` | 엔트리 하나 읽기 |
| `POST` | `/brain/entry-operations` | knowledge 연산 배치 적용 |
| `GET` | `/brain/sources` | 보존된 소스 나열 |
| `POST` | `/brain/sources` | 소스 추가 |
| `POST` | `/brain/sources/:document_id/learning-runs` | 소스 학습 실행 |
| `GET` | `/brain/audit-log` | append-only 감사 추적 읽기 |
| `POST` | `/brain/audit-log/:audit_id/restorations` | 감사된 변경 하나 복원 |
| `POST` | `/brain/dreaming-runs` | dreaming 실행 트리거 |
| `GET` | `/brain/dreaming-fitness` | dreaming이 실행 가능한지 검사 |
| `GET` | `/brain/status` | Brain 상태 및 구성 상태 |

감사 로그는 append-only이며 모든 복원 자체도 감사되므로, agent가 무엇을 믿었는지 — 그리고 누가 그것을 바꿨는지 — 의 이력은 재구성 가능합니다. 소스 회수(withdrawal)는 보존된 소스를 깔끔하게 제거합니다. agent가 더 이상 읽을 수 없는 바이트를 인용하는 상태를 남기지 않습니다.

## Brain이 아닌 것

Brain은 채팅 로그를 덧붙인 벡터 저장소가 아닙니다. 행이 진실이고, 벡터와 Markdown은 그 위의 편의물입니다. 모델이 원하는 대로 쓸 수 있는 공간도 아닙니다 — 쓰기는 권한, evidence, 감사를 담습니다. 그리고 채팅 evidence의 소유자도 아닙니다. 그것은 SignalsGateway에 남아 있습니다. Brain의 경계는 지속적이고 검토되며 owner-scope인 memory와, 거기에 무엇을 넣을지 제안하는 오프라인 기계 장치입니다.

## 다음 단계

- Brain이 회상하는 채팅 evidence에 대해서는 [SignalsGateway](../signals-gateway/) 페이지를 읽으세요.
- Brain의 범위를 정하는 대화 선언에 대해서는 [AIGateway API](../ai-gateway/)를 읽으세요.
- 회상된 memory가 실행 중인 턴에 도달하는 방법에 대해서는 [Actor Runtime](../actor-runtime/) 페이지를 읽으세요.