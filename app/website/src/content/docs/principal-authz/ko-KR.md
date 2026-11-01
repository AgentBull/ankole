---
title: Principal 및 AuthZ
description: Ankole deployment instance의 권한 경계 — 책임 주체로서의 Principal, 권한 부여(permission grant), 그룹 멤버십, 그리고 프롬프트 관례가 아닌 런타임 강제.
section: Developer guide
order: 106
---

사용자의 로그인부터 Agent의 턴 실행, 백그라운드 Job이 소유 세션을 깨우는 작업에 이르기까지 Ankole의 모든 동작은 Principal 주체 아래에서 수행되며, 해당 Principal이 무엇을 할 수 있는지는 실행 시점에 AuthZ가 판정합니다. 이 문서에서는 이 권한 경계가 `Ankole.Principals` 및 `Ankole.AuthZ`의 실제 코드와 어떻게 맞물리는지 설명합니다.

핵심 원칙은 인가(authorization)가 모델에 부탁하는 프롬프트 관례가 아니라 런타임 경계에서 강제되는 불변 규칙이라는 점입니다. Principal은 영속적인(durable) 책임 주체로서 모든 권한 부여(grant)가 PostgreSQL에 기록되며, 보호된 작업마다 Rust kernel이 명시적 스냅샷을 기준으로 권한을 평가하고 호출자는 그 판정 결과를 그대로 따라야 합니다.

## Principal: 하나의 책임 주체

Principal은 사람, Agent, 시스템 서비스가 공통으로 사용하는 영속적 책임 주체입니다. 모든 Principal은 정확히 하나의 테넌트에 소속되며 전역적으로 고유한 불투명 `uid`를 가집니다. `principals` 테이블 행에서 `type`은 `:human`, `:agent`, `:system` 중 하나이고 `status`는 `:active` 또는 `:disabled`이며, `:human` 주체는 `:member` 또는 `:guest` 값을 갖는 `membership` 필드를 가집니다(`:agent`와 `:system`은 `nil`).

사람(`:human`) Principal에는 `HumanUser` 행 하나와 0개 이상의 사이트 범위 `SiteCredential` 행(`principal_site_credentials`, 검증된 이메일 OTP 주소 등), 그리고 0개 이상의 테넌트 범위 `ExternalIdentity` 행(`principal_external_identities`, 외부 Identity Provider에서 연동된 계정)이 연결됩니다. Agent Principal에는 `Agent` 행 하나가 연결됩니다. 이처럼 모든 행위 주체를 단일 테이블로 통합해 두었기 때문에 감사 로그, grant, 그룹 멤버십이 모두 동일한 형태의 Principal `uid`를 가리키며 책임 추적 경로가 하나로 유지됩니다.

사람 Principal의 `membership` 구분은 테넌트 내 협업 범위를 결정합니다. 내부 구성원인 `member`는 계산형 그룹인 `all_humans`에 포함되지만, 외부 참여자인 `guest`는 명시적인 Pod 페이지 공유나 Agent grant가 있어야만 접근할 수 있고 내장 관리자 그룹(`siteadmin`, `pod_admin`) 참여나 Private 루트를 소유할 수 없으며 Brain의 `world` 범위 지식도 조회할 수 없습니다.

비활성화된(`:disabled`) Principal에는 부분적인 권한도 남지 않습니다. 비활성 주체에 대한 검사는 kernel에서 항상 `principal_disabled`를 반환하므로, 개별 grant를 일일이 찾아 지우지 않아도 Principal 상태만 비활성화하면 인스턴스 전체에서 즉시 권한이 차단됩니다.

## Grant: 누가 무엇을 할 수 있는가

`permission_grants` 테이블의 각 행은 다음 세 가지 수혜 주체 중 정확히 하나만 소유자로 가집니다(`Ankole.AuthZ.Validations.GrantShape` 검증 및 PostgreSQL의 `num_nonnulls(principal_uid, group_id, source_node_id) = 1` 체크 제약 조건으로 강제됨).

- 개별 Principal(`principal_uid`)
- Principal 그룹(`group_id`)
- **Drive 노드 Userset**(`source_node_id`와 `node_view`, `node_contribute`, `node_edit`, `node_manage`, `node_comment` 중 하나인 `source_action`의 쌍)

Drive ACL용 grant에는 `target_node_id`와 `target_scope`(하위 트리까지 상속하는 `container` 또는 해당 노드에만 적용하는 `self`)도 함께 저장됩니다. 모든 grant 행은 다음 필드를 포함합니다.

- `resource_pattern`: `Input.validate_resource_pattern_syntax`로 검증되는 콜론 구분 통합 네임스페이스 패턴입니다. `site_console:**`(Site Console), `tenant_console:**`(Pod 관리), `agent:<uid>`(런타임 Agent 접근), `drive:**`(`drive:space:**`, `drive:private:<uid>:**`, `drive:**:<node-id>:**`, `drive:**:<node-id>:node`) 범위를 다루며, 단독 `"**"` 패턴은 허용되지 않습니다.
- `action`: 콜론을 포함할 수 없는 정확한 작업 식별 문자열입니다.
- `condition`: 기본값이 `"true"`인 CEL 불리언 표현식으로, `Input.validate_condition_syntax`를 통해 문법을 검증합니다.
- `description` 및 `metadata`: 운영자가 권한 부여 목적을 파악하기 위한 설명과 부가 정보입니다.

Principal, 그룹, Userset 각각의 자연 키(`owner + resource_pattern + action + condition`) 유일성은 별도의 부분 고유 인덱스(partial unique index)로 보장됩니다. grant의 생성·upsert·수정은 모두 control plane을 거치며, 소유 주체 형태가 잘못되었거나 문법에 어긋난 규칙은 데이터베이스 계층에서도 거부됩니다.

## 그룹: 정적 및 계산된 멤버십

Principal group은 여러 Principal에 grant를 묶어서 부여하기 위한 이름 있는 컬렉션입니다. 각 그룹은 `domain`(`:operator`, `:directory`, `:im_group`, `:signal_source`), `kind`(`:static` 또는 `:computed`), 그리고 계산형 그룹일 때 사용하는 CEL 조건식 `computed_condition`을 가집니다.

모든 테넌트에는 조건식이 `principal.type == "human" && principal.membership == "member" && principal.status == "active"`로 고정된 내장 computed 그룹 `all_humans`와, 해당 Pod 내 `tenant_console:**` 권한을 부여하는 내장 static 그룹 `pod_admin`이 기본 포함됩니다. 특권 사이트 테넌트에는 `site_console:**`와 `tenant_console:**` 권한을 모두 가진 내장 static 그룹 `siteadmin`도 함께 존재합니다. `siteadmin`과 `pod_admin`에는 활성(`active`) 상태의 human `member`만 속할 수 있으며, Site Console에서 조회 대상 데이터 테넌트를 전환하더라도 운영자 본인의 신원이나 `siteadmin` 판정 기준 테넌트는 바뀌지 않습니다. 정적 멤버십은 `principal_group_memberships`에 저장되고 계산형 멤버십은 권한 스냅샷 평가 시점에 계산되며, 외부 디렉터리와 IM 채널 그룹은 `principal_group_external_bindings`를 통해 동기화됩니다.

## 결정이 내려지는 방식

AuthZ가 단순한 권고가 아니라 실질적인 강제력을 갖는 이유는 control plane과 kernel이 역할을 명확히 나누어 수행하기 때문입니다.

- **control plane은 영속 상태, Ash 인가, 스냅샷 구성을 담당합니다.** 보호 대상 액션은 `Ankole.AuthZ.Extension`으로 규칙을 선언하고, `Ankole.AuthZ.Authorizer`는 `%Ankole.AuthZ.Actor{principal, turn_authority, authn}`의 실행 주체를 검사합니다. Agent 턴은 Agent 자신의 리소스 권한을 사용합니다. 검증된 인증 정보는 `context.request.authn`에 담기며, 해당 Agent에 적용되는 grant의 CEL 조건을 평가합니다. `turn_authority`와 `WorkAccess`는 지시가 여전히 유효한지 별도로 확인합니다.
- **kernel과 PostgreSQL은 결정론적 규칙 평가를 맡습니다.** 일반 권한 검사에서는 `Ankole.AuthZ.Snapshot`이 단일 SQL 쿼리로 Principal, 그룹 멤버십, 후보 grant를 읽어 오고, 이어서 Rust kernel이 리소스 패턴 매칭과 computed 그룹 판별, CEL 조건 평가를 수행합니다. Drive 노드 권한의 경우 Rust kernel에서 요청 의존 CEL 조건을 먼저 한 번 평가한 뒤, PostgreSQL의 `WITH RECURSIVE`(`UNION` 최소 고정점) 쿼리로 5비트 ACL 앵커 그래프(`node_view=1`, `node_contribute=2`, `node_edit=4`, `node_manage=8`, `node_comment=16`; 역할 마스크 `view=1`, `contribute=19`, `edit=23`, `manage=31`) 상의 직접 grant, 그룹, 컨테이너 상속, Userset 간선을 결합해 최종 권한을 산출합니다.

`Ankole.AuthZ` 모듈은 용도에 따라 `authorize(subject, resource, action, context)`, 불리언을 반환하는 `allowed?/4`, 단일 작업의 상세 결정 맵을 반환하는 `authorize_decision/4`, 한 리소스에 대한 여러 작업을 한꺼번에 평가하는 `authorize_all_decision/4`, 하나의 스냅샷으로 여러 리소스·작업 쌍을 검사하는 `authorize_checks/3`, Drive 컨텍스트 전용인 `evaluate_drive_context/2` 진입점을 제공합니다. 어느 진입점도 호출자가 자체적으로 주장하는 권한 정보를 신뢰하지 않습니다.

## 결정 상태

권한 평가 결과는 다음 네 가지 상태 중 하나로 반환되며, 각 상태에 따라 호출자가 취해야 할 동작이 정해집니다.

- **`allow`**: 요청한 작업이 허용되었으므로 그대로 진행합니다.
- **`deny`**: 작업이 거부되었으며 거부된 작업 이름이 `deniedAction`에 담깁니다. 호출자는 작업을 중단해야 합니다.
- **`principal_disabled`**: 주체가 비활성화된 상태입니다. 사유가 명시된 거부로 처리합니다.
- **`invalid_request`**: 요청 형식 자체가 잘못되었습니다. 호출자는 그대로 재시도하지 말고 요청 인자를 수정해야 합니다.

모든 판정 시점에는 진단 이벤트(diagnostics)가 함께 발행되므로 거부 사유를 추적할 수 있습니다. 호출자는 `Ankole.AuthZ.Decision.result/1`로 결정 맵을 `:ok | {:error, reason}` 튜플로 변환해 분기 처리합니다.

## 강제가 실제로 적용되는 지점

주요 실행 경계마다 런타임이 직접 AuthZ를 호출해 검증하므로, Agent가 프롬프트나 도구 호출만으로 권한 검사를 우회할 수는 없습니다.

- AIGateway는 검증된 토큰에서 호출 주체(subject)를 식별하고, 그 주체의 grant 범위 안에서만 모델 selector와 provider에 접근하도록 제한합니다.
- **도구 준비 및 디스패치**에서는 실행 Agent의 활성 상태, 선언된 도구 목록, 인수와 지시의 유효성을 확인합니다. 도구 소유 모듈은 해당 Agent의 권한으로 실제 리소스를 검사합니다.
- 실행 세션 Driver는 결과를 커밋하기 전에 영속 펜스(fence)를 검증하고, Worker에서 올라오는 Job 작업 역시 영속 Job attempt 펜스와 인증된 연결 신원을 대조합니다.
- Site Console(`/api/v2`) 및 Pod 관리(`/api/v2/pod/admin`) 요청에는 검증된 브라우저 인증 증명, CSRF 보호, 현재 유효한 `site_console:**` 또는 `tenant_console:**` grant가 모두 필요합니다.

즉, 모델이 스스로 권한이 있다고 선언하더라도 각 경계에서 실제 Principal과 grant를 대조해 허용 여부를 판정합니다.

## Operator 표면

Principal, 그룹, grant 관리 기능(`site_console:**`)은 `/api/v2` 아래의 Site Console JSON:API 라우트로 노출되며, Pod 관리자는 `/api/v2/pod/admin/*`(`tenant_console:**`) 경로에서 테넌트 멤버, 초대, 설정, Identity Provider를 관리합니다.

`site_console:drive` 권한은 구성원과 Agent의 Private 콘텐츠를 포함한 선택된 테넌트의 전체 Drive 트리에 적용됩니다. 운영자는 이 권한으로 부여된 작업에 따라 콘텐츠를 읽거나 수정하거나 삭제할 수 있습니다.

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/api/v2/principals` | Principal 목록 조회 |
| `POST` | `/api/v2/principals` | human 내부 멤버 Principal 사전 생성 |
| `GET` | `/api/v2/principals/:uid` | 단일 Principal 조회 |
| `PATCH` | `/api/v2/principals/:uid` | human Principal 프로필(`display_name`) 수정 |
| `PATCH` | `/api/v2/principals/:uid/membership` | human Principal의 `membership`(`member` 또는 `guest`) 변경 |
| `GET` | `/api/v2/principals/:uid/access` | human 접근 상태, 제한 사항 및 복구 검토 투영 조회 |
| `POST` | `/api/v2/principals/:uid/access-disables` | human Principal 일시 중지(`suspended`) 또는 퇴사 처리(`offboarded`) |
| `POST` | `/api/v2/principals/:uid/access-restorations` | 제한 해제 후 비활성화된 human Principal 복구 |
| `GET` | `/api/v2/principals/:uid/groups` | Principal이 속한 그룹 목록 조회 |
| `GET` | `/api/v2/principals/:uid/grants` | Principal에 직접 부여된 grant 목록 조회 |
| `GET` | `/api/v2/principal-groups` | 그룹 목록 조회 |
| `POST` | `/api/v2/principal-groups` | 운영자 정의 그룹 생성 |
| `GET` | `/api/v2/principal-groups/:name` | 단일 그룹 조회 |
| `PATCH` | `/api/v2/principal-groups/:name` | 그룹 수정 |
| `DELETE` | `/api/v2/principal-groups/:name` | 운영자 정의 그룹 삭제 |
| `POST` | `/api/v2/principal-groups/computed-member-previews` | computed 그룹 조건에 일치하는 멤버 미리 보기 |
| `POST` | `/api/v2/permission-grants` | 운영자 권한 grant 생성(수정·삭제는 `/api/v2/permission-grants/:id`의 `PATCH`/`DELETE`) |

모든 grant 및 멤버십 변경은 `Ankole.AuthZ`를 거치며, 데이터베이스에 기록하기 전에 소유 주체 형태, 리소스 패턴 문법, CEL 조건식 문법을 검증합니다. 동일한 불변 조건이 PostgreSQL 체크 제약 조건과 부분 고유 인덱스로도 이중 강제됩니다.

## Principal 및 AuthZ가 아닌 것

AuthZ는 모델에게 조심스럽게 행동하라고 당부하는 시스템 프롬프트가 아니라, Principal과 grant를 대조해 실행 경계에서 직접 허용·차단을 강제하는 메커니즘입니다. 또한 Principal은 단일 인스턴스를 여러 기업으로 쪼개는 멀티테넌시 구분자나 일회성 요청 역할(per-request role)이 아니라, 권한 부여·그룹화·감사의 기준이 되는 영속적 책임 주체입니다. 마지막으로 Rust kernel은 운영자가 별도로 설정하는 제2의 정책 엔진이 아니며, control plane이 조립해 넘긴 스냅샷을 결정론적으로 평가하는 역할만 담당합니다.

## 다음 단계

- AIGateway 경계에서 검증된 토큰이 Principal로 해석되는 과정은 [AIGateway API](../ai-gateway/)를 참조하세요.
- Agent Principal의 Driver 펜스가 실행 턴을 보호하는 방식은 [Sessions](../sessions/)를 참조하세요.
