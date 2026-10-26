---
title: Principal 및 AuthZ
description: Ankole deployment instance의 권한 경계 — 책임 주체로서의 Principal, 권한 부여(permission grant), 그룹 멤버십, 그리고 프롬프트 관례가 아닌 런타임 강제.
section: Developer guide
order: 106
---

Ankole의 모든 작업 — 사람의 로그인, agent의 turn 실행, job이 소유자를 깨우는 것 — 은 Principal이 수행하며, 그 Principal이 무엇을 할 수 있는지는 작업이 일어나는 순간 AuthZ가 결정합니다. 이 페이지는 그 경계를 `Ankole.Principals`와 `Ankole.AuthZ`의 실제 코드에 대응시켜 설명합니다.

중요한 속성을 먼저 밝히자면, 인가(authorization)는 model에게 요청되는 관례가 아니라 경계에서 강제되는 런타임 사실입니다. Principal은 지속 가능한(durable) 책임 주체이며, 그 부여(grants)는 PostgreSQL에 저장되고, 검사되는 모든 작업은 kernel이 명시적 스냅샷을 기준으로 평가하며, 호출자는 그 결정을 반드시 따라야 합니다.

## Principal: 하나의 책임 주체

Principal은 인간, Agent, 시스템 서비스가 공유하는 영속적인 책임 주체입니다. 각 Principal은 정확히 하나의 테넌트에 속하며 전역에서 고유한 불투명 `uid`를 가집니다. `principals` 행의 `type`은 `:human`, `:agent`, `:system`이고, `status`는 `:active` 또는 `:disabled`이며, `:human`의 경우 `:member` 또는 `:guest`의 `membership`(`:agent`와 `:system`은 `nil`)을 가집니다.

인간 Principal은 하나의 `HumanUser` 행, 0개 이상의 사이트 범위 `SiteCredential` 행(`principal_site_credentials`, 검증된 이메일 OTP 주소 등), 그리고 0개 이상의 테넌트 범위 `ExternalIdentity` 행(`principal_external_identities`, Identity Provider에서 페더레이션한 ID)을 가집니다. agent Principal은 하나의 `Agent` 행을 가집니다. 모든 주체를 하나의 테이블로 통합하면 책임 추적성이 단일 형태로 유지되어 모든 audit 행, grant, 그룹 멤버십이 동일한 안정적인 Principal `uid`를 가리킵니다.

인간의 `membership`은 테넌트 내 협업 경계를 제어합니다. 내부 `member`는 계산된 `all_humans` 그룹에 포함되지만, 외부 `guest`는 명시적인 Pod 페이지 공유 또는 Agent grant가 필요하며 내장 관리자 그룹(`siteadmin` 또는 `pod_admin`)에 참여하거나 Private space를 사용할 수 없고 Brain의 `world` 범위도 받지 않습니다.

비활성화된 Principal은 부분적으로 사용할 수 없습니다. kernel의 결정은 비활성화된 주체에 대해 `principal_disabled`를 반환하므로, Principal을 비활성화하면 모든 grant를 일일이 찾아다닐 필요 없이 instance 전체에서 그 권한이 제거됩니다.

## Grant: 누가 무엇을 할 수 있는가

`permission_grants`의 각 행은 다음 세 가지 수혜자 소유자 중 정확히 하나만 가집니다(`num_nonnulls(principal_uid, group_id, source_page_id) = 1`, `Ankole.AuthZ.Validations.GrantShape`와 PostgreSQL check constraint로 강제됨):

- Principal(`principal_uid`),
- Principal group(`group_id`), 또는
- **Pod 페이지 Userset**(`source_page_id`와 `page_view`, `page_write_records`, `page_edit`, `page_manage` 중 하나의 정확한 `source_action` 쌍).

Pod ACL grant는 `target_page_id`와 `target_scope`(하위 트리 상속을 위한 `container`, 또는 대상 페이지 단독인 `self`)도 저장합니다. 모든 grant는 다음을 포함합니다:

- `resource_pattern` — `Input.validate_resource_pattern_syntax`로 검증되며, 콜론으로 구분된 통합 네임스페이스를 다룹니다: `site_console:**`(Site Console), `tenant_console:**`(Pod 관리), `agent:<uid>` 및 `agent:<uid>:tool:<fn>`(런타임 Agent 및 도구 호출), `pod:**`(`pod:space:**`, `pod:private:<uid>:**`, `pod:**:<page-id>:**`, `pod:**:<page-id>:page`). 단독 `"**"` 패턴은 유효하지 않습니다;
- `action` — 콜론이 허용되지 않는 정확한 작업 문자열;
- `condition` — 기본값 `"true"`인 CEL 불리언 표현식이며, `Input.validate_condition_syntax`로 검증됩니다;
- operator가 읽기 쉽도록 하는 `description`과 `metadata`.

별도의 부분 고유 인덱스가 Principal, 그룹, Userset grant 각각의 자연 키(`owner + resource_pattern + action + condition`) 유일성을 보장합니다. grant의 생성, upsert, 업데이트는 control-plane 작업이며, 데이터베이스는 유효하지 않은 owner 형태나 잘못된 규칙을 거부합니다.

## 그룹: 정적 및 계산된 멤버십

Principal group은 Principal에 grant를 부여할 수 있는 이름 있는 컬렉션입니다. 그룹은 `domain`(`:operator`, `:directory`, `:im_group`, `:signal_source`), `kind`(`:static` 또는 `:computed`), 그리고 computed 그룹용 CEL `computed_condition`을 가집니다.

모든 테넌트에는 계산 조건이 `principal.type == "human" && principal.membership == "member" && principal.status == "active"`인 내장 computed 그룹 `all_humans`와 해당 Pod 내 `tenant_console:**` 작업을 부여하는 내장 static 그룹 `pod_admin`이 있습니다. 특권 사이트 테넌트에는 내장 static 그룹 `siteadmin`(`site_console:**` 및 `tenant_console:**`)도 포함됩니다. 활성(`active`) 상태의 human `member` principal만 `siteadmin` 또는 `pod_admin`에 참여할 수 있습니다. Site Console에서 다른 데이터 테넌트를 선택해도 운영자의 identity나 `siteadmin` 조회 대상은 바뀌지 않습니다. 정적 멤버십은 `principal_group_memberships`에 저장하고 계산 멤버십은 권한 snapshot으로 평가합니다. 외부 디렉터리와 IM 채널은 `principal_group_external_bindings`를 통해 그룹을 동기화합니다.

## 결정이 내려지는 방식

control plane과 kernel은 의도적으로 작업을 나눕니다. 그리고 이 역할 분담이 AuthZ가 조언이 아니라 강제 가능한 이유입니다:

- **control plane이 영속 상태, Ash 인가 강제 및 스냅샷 조립을 담당합니다.** 보호된 Ash 작업은 `Ankole.AuthZ.Extension`으로 컴파일 타임 규칙을 선언하고 런타임에 `Ankole.AuthZ.Authorizer`가 `%Ankole.AuthZ.Actor{principal, interactive_principal, turn_authority, authn, interactive_authn}`을 사용해 강제합니다. 검증된 브라우저, OIDC, Worker 인증 사실은 CEL 조건에서 읽을 수 있도록 `context.request.authn`에 기록됩니다. `interactive_principal`이 존재하는 경우(예: 사람이 시작시킨 Agent 턴)에는 Agent와 사람 모두가 검사를 통과해야 합니다(`Human ∩ Agent`).
- **kernel과 PostgreSQL이 결정론적 규칙 평가를 담당합니다.** 일반 검사에서는 `Ankole.AuthZ.Snapshot`이 단일 SQL 문으로 Principal, 그룹 멤버십, 후보 grant를 로드하고 Rust kernel이 리소스 패턴, computed 그룹, CEL 조건을 평가합니다. Pod 페이지의 경우 4비트 ACL 앵커 그래프(`page_view=1`, `page_write_records=2`, `page_edit=4`, `page_manage=8`; 역할 마스크 `view=1`, `contribute=3`, `edit=7`, `manage=15`)가 요청 의존 CEL 조건을 Rust kernel에서 한 번 평가한 뒤, PostgreSQL의 `WITH RECURSIVE`(`UNION` 최소 고정점)로 직접 grant, 그룹, 컨테이너 상속, Userset 간선을 결합합니다.

`Ankole.AuthZ`의 공개 진입점은 `authorize(subject, resource, action, context)`, 불리언을 반환하는 `allowed?/4`, 단일 작업의 전체 결정 맵을 반환하는 `authorize_decision/4`, 하나의 리소스에 대한 작업 목록을 일괄 평가하는 `authorize_all_decision/4`, 단일 스냅샷으로 여러 독립적인 리소스/작업 검사를 수행하는 `authorize_checks/3`, 그리고 Pod 컨텍스트 평가용 `evaluate_pod_context/2`입니다. 어느 진입점도 Principal의 권한에 대한 호출자의 주장을 신뢰하지 않습니다.

## 결정 상태

결정은 네 가지 상태 중 하나로 반환되며, 각 상태는 호출자의 의무에 대응합니다:

- **`allow`** — 작업이 허용됨. 진행하세요.
- **`deny`** — 작업이 금지되며 `deniedAction`이 명명됩니다. 호출자는 그 작업을 수행해서는 안 됩니다.
- **`principal_disabled`** — 주체가 비활성화됨. 특정 원인이 있는 거부로 처리됩니다.
- **`invalid_request`** — 요청 자체가 잘못된 형식임. 호출자는 무작정 재시도하는 대신 요청을 수정합니다.

각 결정에 대해 진단(diagnostics)이 발행되므로 거부는 관찰 가능합니다. `Ankole.AuthZ.Decision.result/1`은 결정 맵을 `:ok | {:error, reason}`로 변환하며, 호출자는 이 형태를 기준으로 분기합니다.

## 강제가 실제로 적용되는 지점

AuthZ는 agent가 우회할 수 있는 계층이 아닙니다. 런타임이 중요한 경계에서 AuthZ를 참조하기 때문입니다:

- AIGateway는 검증된 token에서 모든 호출의 주체(subject)를 해석하며, 주체의 grant가 도달할 수 있는 model selector와 provider를 결정합니다.
- 도구 준비 및 디스패치 단계에서 `agent:<uid>:tool:<fn>`(`invoke` 작업과 정규화된 `context.request.args`)을 평가하고, 사람에서 비롯된 턴의 Pod 작업에는 `Human ∩ Agent` 권한 교집합을 적용합니다.
- 실행 세션 Driver는 commit 전에 영속 fence를 확인합니다. Worker의 Job 작업은 영속 Job attempt fence와 인증된 연결 identity를 확인합니다.
- Site Console(`/api/v2`) 및 Pod 관리(`/api/v2/pod/admin`) 작업은 검증된 브라우저 증명, CSRF 보호, 그리고 현재 유효한 `site_console:**` 또는 `tenant_console:**` grant를 요구합니다.

model은 “나는 허용되어 있다”고 주장할 수 없습니다. 경계는 Principal과 grant를 확인하고 결정에 따라 행동합니다.

## Operator 표면

`/api/v2` 아래의 Site Console JSON:API 라우트가 Principal, 그룹, grant 관리(`site_console:**`)를 노출하며, Pod 관리자는 `/api/v2/pod/admin/*`(`tenant_console:**`)에서 테넌트 멤버, 초대, 설정, Identity Provider를 관리합니다:

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/api/v2/principals` | Principal 목록 |
| `POST` | `/api/v2/principals` | human 내부 멤버 Principal 사전 생성 |
| `GET` | `/api/v2/principals/:uid` | 하나의 Principal 읽기 |
| `PATCH` | `/api/v2/principals/:uid` | human Principal 프로필(`display_name`) 업데이트 |
| `PATCH` | `/api/v2/principals/:uid/membership` | human Principal의 `membership`(`member` 또는 `guest`) 변경 |
| `GET` | `/api/v2/principals/:uid/access` | human 접근 상태, 제한 사항 및 복구 검토 투영 조회 |
| `POST` | `/api/v2/principals/:uid/access-disables` | human Principal 일시 중지(`suspended`) 또는 퇴사 처리(`offboarded`) |
| `POST` | `/api/v2/principals/:uid/access-restorations` | 제한 해제 후 비활성화된 human Principal 복구 |
| `GET` | `/api/v2/principals/:uid/groups` | Principal의 그룹 목록 |
| `GET` | `/api/v2/principals/:uid/grants` | Principal의 grant 목록 |
| `GET` | `/api/v2/principal-groups` | 그룹 목록 |
| `POST` | `/api/v2/principal-groups` | operator 그룹 생성 |
| `GET` | `/api/v2/principal-groups/:name` | 그룹 읽기 |
| `PATCH` | `/api/v2/principal-groups/:name` | 그룹 업데이트 |
| `DELETE` | `/api/v2/principal-groups/:name` | operator 그룹 삭제 |
| `POST` | `/api/v2/principal-groups/computed-member-previews` | computed 그룹의 멤버 미리 보기 |
| `POST` | `/api/v2/permission-grants` | operator 권한 grant 생성(`/api/v2/permission-grants/:id`에서 `PATCH`/`DELETE`) |

grant와 멤버십 관리는 `Ankole.AuthZ`를 통해 이루어지며, 행이 쓰이기 전에 owner 형태, resource-pattern 문법, CEL condition 문법을 검증합니다. PostgreSQL check constraint와 부분 고유 인덱스가 저장소 계층에서도 동일한 불변 조건을 강제합니다.

## Principal 및 AuthZ가 아닌 것

AuthZ는 프롬프트 지시도 희망도 아닙니다. model에게 책임을 물어보지 않고, Principal을 확인하고 답을 강제합니다. Principal은 하나의 instance를 별도의 엔터프라이즈 경계로 나누지 않으며, 요청별 역할도 아닙니다. 권한이 부여되고, 그룹화되고, 평가되는 안정적이고 책임 있는 주체입니다. kernel은 operator가 구성하는 두 번째 정책 엔진이 아닙니다. control plane이 조립한 스냅샷을 결정적으로 평가하며, 호출자는 그 결정을 따라야 합니다.

## 다음 단계

- AIGateway 가장자리에서 검증된 token이 Principal로 해석되는 방식에 대해서는 [AIGateway API](../ai-gateway/) 문서를 읽으세요.
- agent Principal의 Driver fence이 turn을 펜싱하는 방식에 대해서는 [Sessions](../sessions/) 문서를 읽으세요.
