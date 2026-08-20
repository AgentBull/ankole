---
title: Principal 및 AuthZ
description: Ankole deployment instance의 권한 경계 — 책임 주체로서의 Principal, 권한 부여(permission grant), 그룹 멤버십, 그리고 프롬프트 관례가 아닌 런타임 강제.
section: Developer guide
order: 106
---

Ankole의 모든 작업 — 사람의 로그인, agent의 turn 실행, job이 소유자를 깨우는 것 — 은 Principal이 수행하며, 그 Principal이 무엇을 할 수 있는지는 작업이 일어나는 순간 AuthZ가 결정합니다. 이 페이지는 그 경계를 `Ankole.Principals`와 `Ankole.AuthZ`의 실제 코드에 대응시켜 설명합니다.

중요한 속성을 먼저 밝히자면, 인가(authorization)는 model에게 요청되는 관례가 아니라 경계에서 강제되는 런타임 사실입니다. Principal은 지속 가능한(durable) 책임 주체이며, 그 부여(grants)는 PostgreSQL에 저장되고, 검사되는 모든 작업은 kernel이 명시적 스냅샷을 기준으로 평가하며, 호출자는 그 결정을 반드시 따라야 합니다.

## Principal: 하나의 책임 주체

Principal은 인간, agent, 시스템 서비스가 공유하는 지속 가능한 책임 주체입니다. `principals` 테이블은 `uid`(타입이 있는 `PrincipalKey`, check constraint로 소문자 강제 및 필수)를 키로 가지며, 각 행은 `:human`, `:agent` 또는 `:system` 중 하나의 `type`과 `:active` 또는 `:disabled` 중 하나의 `status`를 가집니다.

인간 Principal은 하나의 `HumanUser`와 여러 개의 `ExternalIdentity` 행(operator가 페더레이션한 ID)을 가집니다. agent Principal은 하나의 `Agent` 행을 가집니다. 둘을 하나의 테이블로 라우팅하는 이유는 책임 추적성의 형태가 하나이기 때문입니다. 무언가를 한 사람이 누구든, 그 일을 한 Principal 행이 존재하며, 모든 audit 행, grant, 그룹 멤버십이 가리키는 안정적인 uid를 가집니다.

비활성화된 Principal은 부분적으로 사용할 수 없습니다. kernel의 결정은 비활성화된 주체에 대해 `principal_disabled`를 반환하므로, Principal을 비활성화하면 모든 grant를 일일이 찾아다닐 필요 없이 instance 전체에서 그 권한이 제거됩니다.

## Grant: 누가 무엇을 할 수 있는가

권한 grant는 정확히 하나의 Principal 또는 정확히 하나의 Principal group이 소유합니다. 둘 다이거나 둘 다 아닌 경우는 없으며, 이는 `validate_owner_shape`와 데이터베이스 check constraint로 강제됩니다. grant는 다음을 포함합니다:

- `resource_pattern` — grant가 적용되는 대상을 나타내며, 문법은 `Input.validate_resource_pattern_syntax`로 검증됩니다;
- `action` — grant가 허용하는 작업이며, 콜론은 허용되지 않습니다(콜론은 resource/action 구분을 위해 예약됨);
- `condition` — 기본값 `"true"`인 불리언 표현식이며, `Input.validate_condition_syntax`로 검증됩니다;
- operator가 읽기 쉽도록 하는 `description`과 `metadata`.

Grant는 정신적으로 append-only이며 소유자별로 natural key가 유일합니다(Principal당 하나, group당 하나, 자연 인덱스 기준). grant의 생성, upsert, 업데이트는 control-plane 작업입니다. 호출자는 데이터베이스가 거부할 owner 형태를 가리키는 grant를 만들 수 없습니다.

## 그룹: 정적 및 계산된 멤버십

Principal group은 Principal에 grant를 부여할 수 있는 이름 있는 컬렉션으로, Principal별 행 없이도 권한이 확장될 수 있게 합니다. 그룹은 `:operator`, `:directory` 또는 `:im_group` 중 하나의 `domain`, `:static` 또는 `:computed` 중 하나의 `kind`, 그리고 computed 그룹용 선택적 `computed_condition`을 가집니다.

두 개의 기본 제공 그룹이 deployment instance를 초기화합니다. `admin` 그룹은 operator 권한 표면입니다. `all_humans` 그룹은 `principal.type == "human" && principal.status == "active"`라는 computed condition을 가지므로, 누가 수동으로 목록을 관리하지 않아도 모든 활성 인간이 멤버가 됩니다. 정적 멤버십은 `principal_group_memberships`에 있으며, computed 멤버십은 스냅샷을 기준으로 평가됩니다. 외부 디렉터리(IdP, IM 플랫폼)는 external binding을 통해 그룹으로 동기화될 수 있으므로, operator는 이미 신뢰하는 디렉터리를 AuthZ가 가리키도록 할 수 있습니다.

## 결정이 내려지는 방식

control plane과 kernel은 의도적으로 작업을 나눕니다. 그리고 이 역할 분담이 AuthZ가 조언이 아니라 강제 가능한 이유입니다:

- **control plane이 상태와 스냅샷 조립을 담당합니다.** 검사되는 작업에 대해 Principal, 해당 grant, 그룹 멤버십, 관련 resource 컨텍스트를 로드하고 명시적인 authorization 스냅샷을 조립합니다.
- **kernel이 결정적 규칙 평가를 담당합니다.** 스냅샷의 grant와 조건을 평가하고 결정을 반환합니다. 입력이 명시적 스냅샷이고 규칙이 결정적이므로, 같은 스냅샷은 매번 같은 답을 주며, 인메모리 캐시가 어긋날(drift) 수 없습니다.

공개 진입점은 `AuthZ.authorize(principal_uid, resource, action, context)`, 불리언을 반환하는 `allowed?/4`, 하나의 resource에 대한 작업 묶음용 `authorize_all`, 그리고 전체 결정 맵을 반환하는 `_decision` 변형들입니다. 그것들 각각은 스냅샷을 구성해 kernel에 넘깁니다. 어느 것도 Principal이 무엇을 할 수 있는지에 대한 호출자의 주장을 신뢰하지 않습니다.

## 결정 상태

결정은 네 가지 상태 중 하나로 반환되며, 각 상태는 호출자의 의무에 대응합니다:

- **`allow`** — 작업이 허용됨. 진행하세요.
- **`deny`** — 작업이 금지되며 `deniedAction`이 명명됩니다. 호출자는 그 작업을 수행해서는 안 됩니다.
- **`principal_disabled`** — 주체가 비활성화됨. 특정 원인이 있는 거부로 처리됩니다.
- **`invalid_request`** — 요청 자체가 잘못된 형식임. 호출자는 무작정 재시도하는 대신 요청을 수정합니다.

각 결정에 대해 진단(diagnostics)이 발행되므로 거부는 관찰 가능합니다. `AuthZ.result/1`은 결정을 `:ok | {:error, reason}`로 변환하며, 호출자는 이 형태를 기준으로 분기합니다.

## 강제가 실제로 적용되는 지점

AuthZ는 agent가 우회할 수 있는 계층이 아닙니다. 런타임이 중요한 경계에서 AuthZ를 참조하기 때문입니다:

- AIGateway는 검증된 token에서 모든 호출의 주체(subject)를 해석하며, 주체의 grant가 도달할 수 있는 model selector와 provider를 결정합니다.
- Actor Runtime은 agent Principal이 소유한 activation으로 모든 turn을 펜싱합니다. 다른 주체의 응답은 펜스를 통과하지 못합니다.
- Console 작업은 검증된 admin token을 통해 수행되며, admin Principal의 그룹 멤버십이 무엇을 변경할 수 있는지 결정합니다.

model은 “나는 허용되어 있다”고 주장할 수 없습니다. 경계는 Principal과 grant를 확인하고 결정에 따라 행동합니다.

## Operator 표면

Console 범위의 라우트가 AuthZ model을 검사 및 관리용으로 노출합니다:

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/principals` | Principal 목록 |
| `GET` | `/principals/:uid` | 하나의 Principal 읽기 |
| `GET` | `/principals/:uid/groups` | Principal의 그룹 목록 |
| `GET` | `/principals/:uid/grants` | Principal의 grant 목록 |
| `GET` | `/principal-groups` | 그룹 목록 |
| `POST` | `/principal-groups` | 그룹 생성 |
| `GET` | `/principal-groups/:name` | 그룹 읽기 |
| `PATCH` | `/principal-groups/:name` | 그룹 업데이트 |
| `POST` | `/principal-groups/computed-member-previews` | computed 그룹의 멤버 미리 보기 |

grant와 멤버십 관리는 AuthZ facade를 통해 이루어지며, facade는 어떤 행이 쓰여지기 전에 owner 형태, resource-pattern 문법, condition 문법을 검증합니다. 데이터베이스 check constraint는 최후의 방어선입니다. owner 형태나 콜론 금지 규칙을 위반하는 행은 존재할 수 없습니다.

## Principal 및 AuthZ가 아닌 것

AuthZ는 프롬프트 지시도 희망도 아닙니다. model에게 책임을 물어보지 않고, Principal을 확인하고 답을 강제합니다. Principal은 하나의 instance를 별도의 엔터프라이즈 경계로 나누지 않으며, 요청별 역할도 아닙니다. 권한이 부여되고, 그룹화되고, 평가되는 안정적이고 책임 있는 주체입니다. kernel은 operator가 구성하는 두 번째 정책 엔진이 아닙니다. control plane이 조립한 스냅샷을 결정적으로 평가하며, 호출자는 그 결정을 따라야 합니다.

## 다음 단계

- AIGateway 가장자리에서 검증된 token이 Principal로 해석되는 방식에 대해서는 [AIGateway API](../ai-gateway/) 문서를 읽으세요.
- agent Principal의 activation이 turn을 펜싱하는 방식에 대해서는 [Actor Runtime](../actor-runtime/) 문서를 읽으세요.