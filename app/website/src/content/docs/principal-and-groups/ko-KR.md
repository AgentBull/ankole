---
title: Principal과 permission group
description: 사람과 조직 디렉터리를 동기화한 다음, directory, static 또는 computed group으로 액세스를 할당합니다.
section: User guide
order: 49
---

Ankole에서는 사람, Agent, 시스템 서비스를 모두 Principal로 표현합니다. 여러 Principal을 묶어 관리할 때는 permission group을 사용하고, 각 Principal이나 group이 어떤 리소스에 접근할 수 있는지는 permission grant로 정의합니다.

Identity Provider를 연동하면 임직원과 조직 디렉터리가 자동으로 동기화되므로 Ankole에서 부서 멤버십을 일일이 수동 관리할 필요가 없습니다. 그 밖에도 패스워드리스 이메일 OTP(`SiteCredential`), Pod 초대 링크(`/join/:token`), 관리자 사전 생성을 통해 사용자를 등록할 수 있습니다.

## Identity Provider가 조직을 동기화하는 방법

Identity Provider에서 디렉터리 동기화(directory sync)를 켜면 외부 조직도가 다음 두 가지 데이터로 반영됩니다.

- 임직원은 human principal로 생성되며, 동기화 과정에서 이름과 아바타 같은 프로필 정보가 최신 상태로 유지됩니다.
- 부서, 사용자 그룹 등 조직 단위는 directory permission group으로 생성되며, 소속 멤버십도 함께 갱신됩니다.

외부 디렉터리에 상위·하위 부서 계층이 있으면 하위 부서 소속 인원은 상위 부서 group의 멤버로도 함께 포함됩니다. 따라서 상위 부서에 grant를 부여하면 하위 부서 구성원에게도 동일한 권한이 적용됩니다.

Identity Provider를 저장하면 첫 전체 동기화(full sync)가 바로 시작되고, 이후 기본적으로 6시간마다 전체 동기화가 다시 실행됩니다. 증분 동기화(incremental sync)를 지원하는 Provider라면 다음 전체 동기화 전이라도 사용자 및 조직 변경분이 실시간에 가깝게 반영됩니다.

디렉터리를 즉시 새로 고치려면 **Console → Identity Providers**에서 대상 Provider를 선택한 뒤 **전체 동기화 실행**을 누르세요. 동기화가 끝나면 **Access → Principals**와 **Access → Permission groups**에서 반영 결과를 확인할 수 있습니다.

directory group의 기준 원본(source of truth)은 외부 identity 시스템이므로, 부서 이동이나 멤버십 변경은 반드시 회사 디렉터리에서 처리하세요. Ankole 안에서 이러한 그룹을 직접 수정하려고 해서는 안 됩니다.

동기화 결과에 예상한 직원이나 부서가 보이지 않는다면 외부 애플리케이션에 부여된 디렉터리 조회 권한과 공개 범위를 점검하세요. API 연동이 되어 있더라도 애플리케이션에 전사 조직 전체의 조회 범위가 열려 있지 않을 수 있습니다.

첫 Identity Provider를 연결하는 방법은 [빠른 시작](../quickstart/#identity-providers)을 참조하세요.

## Principal 보기

**Console → Access → Principals**를 열면 이름, UID, 유형, 멤버십, 상태 목록이 표시됩니다.

- **Human** principal은 Identity Provider 로그인 및 디렉터리 동기화, 패스워드리스 이메일 OTP(`SiteCredential`), Pod 초대 링크(`/join/:token`), 또는 관리자 사전 생성을 통해 만들어집니다. 각 human principal은 테넌트 안에서 `member` 또는 `guest` 중 하나의 `membership`을 가집니다. 내부 구성원인 `member`는 내장 computed group인 `all_humans`에 자동 포함됩니다. 반면 외부 협력자인 `guest`는 명시적인 Pod 페이지 공유나 Agent grant가 있어야만 접근할 수 있으며, 내장 관리자 그룹(`siteadmin`, `pod_admin`) 참여나 Private space 사용이 제한되고 Brain의 `world` 범위 지식도 제공받지 않습니다(외부 게스트 허용 여부와 Pod 접근 정책은 `pod.allow_external_guests`로 제어합니다).
- **Agent** principal은 새 Agent를 생성할 때 함께 만들어집니다.
- **System** principal은 내부 서비스 작업을 위해 Ankole이 자체 생성합니다.

Principal 이름이나 행 오른쪽의 **상세 보기**를 누르면 소속 group과 직접 부여된 grant를 모두 볼 수 있습니다. Principal UID와 유형은 해당 identity 또는 런타임 소유 도메인에서 결정하므로 읽기 전용입니다. 접근 권한을 점검할 때는 직접 grant뿐 아니라 소속 group도 반드시 함께 확인하세요. 직접 grant가 없더라도 group 멤버십을 통해 권한을 부여받았을 수 있습니다.

## 올바른 permission group 선택

그룹 종류에 따라 멤버십을 관리하는 주체가 다릅니다.

| Permission group | 적합한 상황 | 멤버십 관리 주체 |
| --- | --- | --- |
| **Directory group** | 회사 디렉터리에 이미 부서나 사용자 그룹이 구성되어 있을 때 | Identity Provider 동기화 |
| **IM group** | 채팅방 참여 여부에 따라 접근 권한을 연동하고 싶을 때 | 채팅 채널 동기화 |
| **Signal source group** | 특정 라우팅 규칙으로 대화한 사용자 전체를 묶고 싶을 때 | Signals 수용 경로 |
| **Provider members group** | 특정 Identity Provider를 통해 들어온 사용자 전체(`<provider>:members:all`)를 대상으로 할 때 | Identity Provider 동기화 |
| **Static group** | Ankole 내부에서만 쓰는 소규모 팀이고 멤버 변동이 잦지 않을 때 | 관리자 |
| **Computed group** | Principal 속성 조건만으로 대상 멤버를 명확히 판별할 수 있을 때 | Ankole이 평가하는 CEL 표현식 |

Directory group과 IM group은 동기화를 통해 permission group 목록에 자동으로 나타나며, 외부 시스템이 멤버십을 소유하므로 Console에서는 읽기 전용으로 표시됩니다. 반면 static group과 computed group은 관리자가 Ankole에서 직접 생성하고 관리합니다. 이와 별도로 모든 테넌트에는 해당 Pod 내 `tenant_console:**` 작업을 허용하는 내장 static group `pod_admin`과 활성 내부 구성원을 묶는 내장 computed group `all_humans`가 기본 제공되며, 특권 사이트 테넌트에는 `site_console:**` 및 `tenant_console:**` 권한을 가진 내장 static group `siteadmin`이 추가로 포함됩니다. `siteadmin`과 `pod_admin`에는 활성(`active`) 상태인 human `member`만 속할 수 있습니다.

대상 조직이 회사 디렉터리에 이미 정의되어 있다면 가급적 directory group을 사용하세요. 구성원이 부서를 옮기거나 퇴사하더라도 다음 증분 또는 전체 동기화 시점에 접근 권한이 자동으로 조정됩니다.

## Static group 만들기

1. **Console → Access → Permission groups**를 열고 **새 group**을 선택합니다.
2. 변경되지 않을 소문자 식별자 이름과 표시 이름, 설명을 입력합니다.
3. 유형으로 **Static**을 선택한 뒤 저장합니다.
4. 생성된 group을 열고 Members 섹션에서 **멤버 추가**를 선택합니다.

멤버로 추가된 Principal에는 해당 group의 모든 grant가 즉시 적용되며, 멤버에서 제외하면 권한도 바로 회수됩니다.

## Computed group 만들기

computed group은 별도의 멤버 목록을 저장하지 않으며 수동으로 멤버를 추가할 수도 없습니다. 대신 접근 권한을 검사할 때마다 CEL 표현식 하나를 평가해 해당 Principal이 그룹 조건을 만족하는지 실시간으로 판별합니다.

새 group을 만들 때 유형을 **Computed**로 선택하고 **Membership condition**에 CEL 표현식을 입력합니다. 표현식은 `principal` 변수를 참조해 현재 주체의 속성을 읽으며, 반드시 `true` 또는 `false` 불리언 값을 반환해야 합니다.

표현식에서 사용할 수 있는 필드는 다음과 같습니다.

| 필드 | 의미 | 예시 값 |
| --- | --- | --- |
| `principal.uid` | 고유 Principal UID | `01958f1a-...` |
| `principal.type` | Principal 유형 | `human`, `agent`, `system` |
| `principal.membership` | 테넌트 내 human 멤버십 구분 | `human`은 `member` 또는 `guest`, `agent`와 `system`은 `null` |
| `principal.status` | Principal 상태 | `active`, `disabled` |
| `principal.displayName` | 표시 이름(비어 있을 수 있음) | `Alex Smith` |
| `principal.avatarURL` | 아바타 URL(비어 있을 수 있음) | Provider에서 전달한 URL |

예를 들어 다음 표현식은 활성 상태인 모든 내부 구성원과 일치합니다(내장 `all_humans` 그룹과 동일한 조건).

```text
principal.type == "human" && principal.membership == "member" && principal.status == "active"
```

여기서 `principal.membership == "member"` 조건을 빼면 활성 상태인 외부 `guest`까지 함께 포함됩니다.

모든 활성 Agent를 대상으로 하려면 다음과 같이 작성합니다.

```text
principal.type == "agent" && principal.status == "active"
```

표현식을 입력하면 현재 조건과 일치하는 활성 Principal 목록이 Console에 실시간 미리보기로 표시됩니다. 의도보다 넓은 범위에 권한이 열리지 않도록 저장하기 전에 대상 인원수와 이름을 꼭 확인하세요.

한번 저장한 뒤에는 group의 식별자 이름과 유형을 바꿀 수 없습니다. 일반 computed group의 멤버십 조건식은 이후에도 수정할 수 있으니, 수정 시에도 실시간 미리보기를 다시 확인한 뒤 저장하세요. 내장 computed group의 조건식은 Ankole이 직접 관리하므로 Console에서 읽기 전용으로 유지됩니다.

참고로 CEL 표현식에서는 직원의 이메일 주소, 직책, 소속 부서를 조회할 수 없습니다. 부서 단위 권한 부여에는 동기화된 directory group을 사용하시고, 표시 이름 문자열로 소속 조직을 추정하는 조건식은 작성하지 마세요.

## Grant 추가

대상 permission group이나 Principal 상세 화면을 열고 grant 섹션에서 **새 grant**를 선택한 뒤 다음 항목을 입력합니다.

- **Resource pattern:** 권한을 적용할 리소스 범위
- **Action:** 허용할 작업 이름(예: `read`, `update`)
- **Condition:** 선택적 세부 제한 조건(별도 조건이 없으면 비워 둠)
- **Description:** 이 권한이 필요한 이유에 대한 메모

개별 Principal에 직접 grant를 주기보다는 permission group 단위로 권한을 부여하는 방식을 권장하며, 직접 grant는 예외적인 상황에서만 사용하세요. grant를 수정하거나 삭제하면 소유 주체와 해당 group 멤버 전체에 즉시 반영됩니다.

한번 생성한 grant의 소유 주체는 다른 대상으로 바꿀 수 없습니다. 권한을 다른 Principal이나 group으로 옮겨야 한다면 새 소유 주체 아래에 grant를 먼저 추가해 접근이 정상 동작하는지 확인한 뒤 기존 grant를 삭제하세요.

## 조직 구조에 따라 액세스 할당

예를 들어 연구 부서 소속 임직원 전원에게 특정 Agent 조회 권한을 주려면 다음 순서로 설정합니다.

1. Identity Provider를 통해 연구 부서와 소속 구성원이 동기화되었는지 확인합니다.
2. 연구 부서에 해당하는 directory permission group을 엽니다.
3. 해당 group에 대상 Agent에 대한 `read` grant를 추가합니다.
4. 부서 소속 계정으로 직접 로그인해 대상 Agent는 열리지만 grant 범위 밖의 다른 리소스는 차단되는지 확인합니다.

이후 연구 부서 인원 변동은 회사 디렉터리에서만 관리하면 됩니다. 다음 동기화가 돌 때 Ankole의 group 멤버십이 자동 갱신되므로 grant 설정을 다시 손댈 필요가 없습니다.

화면에서 저장이 완료되었다는 표시만으로는 검증이 끝난 것이 아닙니다. 실제 소속 멤버 계정으로 접근 결과를 확인해 resource pattern, action, 멤버십 소스가 정확히 맞물리는지 점검하세요.

## 일시 중지(Suspend) 또는 퇴사 처리(Offboard)

구성원이 휴직하거나 퇴사할 때는 계정을 삭제하려 하지 말고 접근 사용 중지 기능을 사용하세요. **Principals and permission groups**에서 대상 사용자를 열고 **계정 접근** 섹션에 사유를 입력한 뒤, 상황에 맞는 처리 구분(`disposition`)을 선택합니다.

- **일시 중지(`suspended`)**: 모든 기기에서 다음 요청 시점에 Console 세션, OAuth 세션, 토큰을 거부하고 후속 작업을 중단하되, 개인 `SiteCredential`, 이메일 별칭, Pod 연락처 이메일 및 전화번호 바인딩은 그대로 유지합니다. 추후 복직해 계정을 복구하면 자격 증명을 다시 연결할 필요 없이 기존 Human Principal을 그대로 이어서 쓸 수 있습니다.
- **퇴사 처리(`offboarded`)**: 세션 및 토큰 철회와 후속 작업 중단에 더해, 해당 테넌트에서 공유되지 않은 개인 `SiteCredential`, 이메일 별칭, Pod 연락처 이메일 및 전화번호 바인딩을 모두 해제합니다. 이때 감사 기록에 `released_identifiers` 워터마크가 남으므로, 나중에 동일한 이메일 등으로 새 직원이 입사하더라도 기존 계정과 섞이지 않고 새로운 Human UID를 발급받습니다. 이미 일시 중지 상태인 계정이라도 퇴사 처리를 실행하면 남아 있던 식별자 바인딩이 해제됩니다.

어느 구분을 선택하더라도 Principal UID, 불변 기업 주체 ID, 기존 작업 산출물, 감사 기록은 그대로 보존됩니다.

외부 Identity Provider 상태 변화로도 계정 사용이 자동 중지될 수 있습니다. Feishu에서의 퇴사·계정 동결·검토된 동기화 범위 제외나 DingTalk에서의 퇴사 상태가 디렉터리 동기화로 전달되면 해당 계정이 동일하게 사용 중지됩니다. 반대로 외부 Provider 이벤트만으로 접근 권한이 자동 복구되지는 않으며, 일시적인 네트워크 오류는 퇴사로 간주하지 않습니다.

계정 사용이 중지되면 해당 사용자의 권한으로 돌아가는 메시지 처리, 스케줄, Background Agent Job, Workflow, 자동화 작업은 다음 시작 시점에 취소되거나 거부됩니다. 중지 시점에 이미 승인되어 실행 중이던 작업은 끝까지 완료될 수 있으며 감사 기록에 그 사실이 명시됩니다(중지 실패가 아닙니다). 소유 주체를 증명할 수 없는 작업 레코드가 발견되면 관리자가 **권한 근거가 없는 작업 검토** 화면에서 처리 방침을 결정할 때까지 `work_authorization_review_required` 상태로 보류되며, 이 분류 결정은 감사 로그에 기록되고 한 번만 내릴 수 있습니다.

사용자 상세 페이지에서는 현재 접근 상태, 처리 구분(`disposition`), identity 소스, 중지 사유와 시각, 실행한 운영자(또는 동기화 소스), 영향받은 작업 항목별 정리 결과, OIDC 클라이언트별 로그아웃 알림 결과를 한눈에 볼 수 있습니다. 정리나 알림 전송에 실패한 항목이 있으면 대상 객체와 함께 재시도 동작이 표시됩니다.

**계정 복구**를 진행하려면 관리자 권한과 복구 사유, 본인 신원 확인이 필요합니다. Console에서는 먼저 걸려 있는 모든 제한 조건을 해제하도록 안내한 뒤, 복구 시 다시 효력을 얻게 될 group 멤버십, 직접 grant, Pod 페이지 Userset grant 목록을 보여 주며 이에 대한 명시적 승인을 요청합니다. 외부 Provider에서 비롯된 제한은 최근 성공한 디렉터리 조회에서 복귀 사실이 확인된 뒤에만 해제할 수 있습니다. 복구가 완료되면 사용자는 새로 로그인해야 하며(Feishu의 경우 개인 연결 재승인 포함), 이미 만료된 이전 세션이나 해제된 자격 증명, 취소된 작업은 되살아나지 않습니다.

만약 `siteadmin`이나 특정 Pod의 `pod_admin` 그룹에 활성 상태인 human 관리자가 한 명도 남지 않은 비상 상황이라면, control-plane 셸 접근 권한을 가진 운영자가 감사 기록이 남는 복구 명령(`Ankole.Release.recover_admin`)을 실행해 신원이 확인된 활성 내부 구성원(`member`)에게 관리자 권한을 부여할 수 있습니다.

```sh
# 사이트 관리 권한 복구(특권 테넌트의 siteadmin)
mix ankole.admin.recover HUMAN_UID OPERATOR REASON --identity-verified

# 지정 테넌트의 Pod 관리 권한 복구(해당 테넌트의 pod_admin)
mix ankole.admin.recover HUMAN_UID OPERATOR REASON --identity-verified --tenant SLUG
```

대상 그룹에 아직 활성 관리자가 한 명이라도 남아 있거나, 지정한 대상이 사용 중지 상태 또는 외부 `guest`인 경우에는 명령 실행이 거부됩니다.

권한 모델의 내부 구조는 [Principal과 AuthZ](../principal-authz/)를 참조하세요.
