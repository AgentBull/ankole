---
title: Principal과 permission group
description: 사람과 조직 디렉터리를 동기화한 다음, directory, static 또는 computed group으로 액세스를 할당합니다.
section: User guide
order: 49
---

Ankole은 사람, Agent, 시스템 서비스를 Principal로 표현합니다. permission group은 여러 Principal을 함께 관리합니다. permission grant는 Principal 또는 group이 사용할 수 있는 resource를 정의합니다.

Identity Provider는 일반적으로 직원과 조직 디렉터리를 자동으로 동기화합니다. Ankole에서 각 직원을 다시 만들거나 부서 멤버십을 유지 관리할 필요가 없습니다.

## Identity Provider가 조직을 동기화하는 방법

Identity Provider에 대해 directory sync를 활성화하면 Ankole은 외부 디렉터리를 두 가지 유형의 데이터로 변환합니다.

- 직원은 human principal이 됩니다. directory sync는 이름과 아바타 같은 profile 데이터를 업데이트합니다.
- 부서, 사용자 group, 이와 유사한 조직 단위는 directory permission group이 됩니다. sync는 해당 멤버십도 업데이트합니다.

외부 디렉터리에 부서 계층이 있으면 하위 부서의 사람도 상위 부서 group의 멤버가 됩니다. 따라서 상위 부서에 대한 grant는 하위 부서의 사람들도 포함할 수 있습니다.

Ankole은 Identity Provider를 저장한 후 첫 번째 full sync를 시작합니다. 기본적으로 6시간마다 full sync를 다시 실행합니다. incremental sync를 지원하는 Provider는 다음 full sync 전에 사람과 조직 변경 사항을 보낼 수도 있습니다.

디렉터리를 즉시 새로 고치려면 **Console → Identity Providers**를 열고 Provider를 선택한 다음 **전체 동기화 실행**을 선택합니다. sync가 완료되면 **Access → Principals**와 **Access → Permission groups**를 확인합니다.

외부 identity 시스템은 directory group의 source of truth로 유지됩니다. 부서와 멤버십은 회사 디렉터리에서 변경하세요. Ankole에서 이러한 group을 수동으로 유지 관리하려고 하지 마세요.

결과에 예상한 사람이나 부서가 없으면 외부 애플리케이션의 디렉터리 권한과 가용 범위를 확인하세요. API 액세스가 애플리케이션에 전체 조직에 대한 액세스를 항상 부여하는 것은 아닙니다.

첫 번째 Identity Provider를 연결하는 방법은 [빠른 시작](../quickstart/#2-set-up-the-identity-provider-first)을 참조하세요.

## Principal 보기

**Console → Access → Principals**를 엽니다. 목록에는 이름, UID, 유형, 상태가 표시됩니다.

- **Human** principal은 Identity Provider가 동기화하는 회사 디렉터리에서 옵니다.
- **Agent** principal은 Agent를 만들 때 나타납니다.
- **System** principal은 내부 서비스 작업을 위해 Ankole이 만듭니다.

Principal을 선택하면 해당 group과 직접 grant를 볼 수 있습니다. 액세스를 조사할 때는 두 영역을 모두 확인하세요. Principal은 직접 grant가 없어도 group을 통해 액세스를 얻을 수 있습니다.

## 올바른 permission group 선택

각 group source에는 서로 다른 멤버십 소유자가 있습니다.

| Permission group | 사용 시기 | 멤버십 소유자 |
| --- | --- | --- |
| **Directory group** | 부서나 사용자 group이 이미 회사 디렉터리에 있음 | Identity Provider 동기화 |
| **IM group** | 액세스가 chat group 멤버십을 따라야 함 | Chat channel 동기화 |
| **Static group** | 팀이 Ankole에만 존재하거나 멤버 수가 적고 자주 바뀌지 않음 | 관리자 |
| **Computed group** | Principal 속성으로 멤버를 안정적으로 식별할 수 있음 | Ankole이 평가하는 CEL expression |

Directory group과 IM group은 permission group 목록에 자동으로 나타납니다. Console에서는 읽기 전용입니다. 관리자는 Ankole에서 static group과 computed group을 만듭니다.

회사 디렉터리가 대상 팀을 이미 나타내고 있으면 directory group을 사용하세요. 사람이 팀을 옮기거나 퇴사하면 다음 incremental 또는 전체 directory sync가 액세스를 조정합니다.

## Static group 만들기

1. **Console → Access → Permission groups**를 열고 **새 group**을 선택합니다.
2. 안정적인 소문자 이름, 표시 이름, 설명을 입력합니다.
3. **Static**을 선택한 다음 group을 저장합니다.
4. 새 group을 열고 Members 섹션에서 **멤버 추가**를 선택합니다.

새 멤버는 group의 모든 grant를 즉시 얻습니다. 멤버를 제거하면 해당 액세스도 제거됩니다.

## Computed group 만들기

computed group은 멤버십 목록을 저장하지 않으며 수동 멤버도 받지 않습니다. Ankole은 액세스를 확인할 때 하나의 CEL expression을 평가하여 principal이 group에 속하는지 결정합니다.

group을 만들 때 **Computed**를 선택합니다. **Membership condition**에 CEL expression을 입력합니다. expression은 `true` 또는 `false`를 반환해야 하며 `principal`을 통해 현재 principal을 읽습니다.

computed group은 현재 다음 필드를 사용할 수 있습니다.

| 필드 | 의미 | 일반적인 값 |
| --- | --- | --- |
| `principal.uid` | 안정적인 principal UID | `research-agent` |
| `principal.type` | Principal 유형 | `human`, `agent`, `system` |
| `principal.status` | Principal 상태 | `active`, `disabled` |
| `principal.displayName` | 표시 이름(비어 있을 수 있음) | `Alex Smith` |
| `principal.avatarURL` | 아바타 URL(비어 있을 수 있음) | Provider의 URL |

이 expression은 모든 활성 human과 일치합니다.

```text
principal.type == "human" && principal.status == "active"
```

이 expression은 UID가 `research-`로 시작하는 Agent와 일치합니다.

```text
principal.type == "agent" && principal.uid.startsWith("research-")
```

expression을 입력하는 동안 Console은 일치하는 모든 활성 principal을 미리 보여줍니다. 저장하기 전에 개수와 이름을 확인하여 group이 의도한 것보다 더 많은 principal에 액세스를 부여하지 않도록 하세요.

저장한 후에는 group 이름, 유형, 멤버십 조건을 변경할 수 없습니다. 규칙을 변경하려면 새 group을 만들고 미리 보기를 확인한 다음 grant를 옮기고 이전 group을 삭제하세요.

CEL은 현재 직원의 이메일 주소, 직책, 부서 멤버십을 읽을 수 없습니다. 부서 액세스에는 동기화된 directory group을 사용하세요. 표시 이름에서 조직 멤버십을 추론하지 마세요.

## Grant 추가

permission group 또는 principal을 열고 grant 섹션에서 **새 grant**를 선택합니다. 그런 다음 다음을 입력합니다.

- **Resource pattern:** grant가 포함하는 resource 범위
- **Action:** 허용되는 작업(예: `read` 또는 `update`)
- **Condition:** 선택적인 고급 제한. 추가 조건이 없으면 비워 둡니다
- **Description:** 이 액세스가 필요한 이유

grant는 permission group에 부여하는 것을 권장합니다. 직접 principal grant는 예외적인 경우에만 사용하세요. 변경되거나 삭제된 grant는 해당 소유자와 관련 group 멤버에게 즉시 영향을 미칩니다.

## 조직 구조에 따라 액세스 할당

연구 부서의 모든 직원이 하나의 Agent를 볼 수 있어야 한다고 가정해 보겠습니다.

1. Identity Provider가 연구 부서와 해당 멤버를 동기화했는지 확인합니다.
2. 해당하는 directory permission group을 엽니다.
3. 대상 Agent에 대한 `read` grant를 group에 추가합니다.
4. 부서 멤버 중 한 명으로 로그인합니다. 멤버가 대상 Agent는 열 수 있지만 grant 범위 밖의 resource는 열 수 없는지 확인합니다.

연구 부서 멤버십은 회사 디렉터리에서 변경합니다. 다음 sync 후 Ankole이 group 멤버십을 업데이트합니다. group의 grant를 변경할 필요는 없습니다.

저장 성공만으로는 충분한 증거가 아닙니다. 실제 멤버 계정으로 결과를 검증하여 resource pattern, action, 멤버십 source가 올바른지 확인하세요.

전체 permission model은 [Principal과 AuthZ](../principal-authz/)를 참조하세요.