---
title: 보안 강화
description: Ankole deployment instance 강화의 전체적인 형태 — 최소 권한(least authority), 비밀 관리 규율, SSRF, 자격 증명 회전, 최소 인그레스.
section: Guides
order: 316
---

Ankole은 보안 경계를 갖춘 상태로 제공됩니다 — Principal/AuthZ, 암호화된 비밀, 샌드박스 처리된 worker, 인증된 인그레스. 강화(hardening)는 벽을 추가하는 것이 아니라, 이미 있는 벽을 실제 사용에 필요한 가장 작은 표면으로 조이는 것입니다. 이 페이지는 operator가 강화하는 다섯 가지 표면을 가장 큰 위험부터 먼저 줄이는 순서로 안내합니다.

중요한 속성을 먼저 밝히자면, Ankole의 모델은 *기본적으로 최소 권한이며, 증거가 요구하는 곳에서만 확장됩니다*. 아래의 모든 조치는 권한, 비밀의 도달 범위 또는 네트워크 경로를 좁힙니다. 무언가를 넓히고 있다면 이유를 물어보세요. 넓히는 것이야말로 검토가 필요한 조치이며, 좁히는 것은 그렇지 않습니다.

## 표면 1: Principal 및 AuthZ 권한

agent는 자신의 Principal 아래에서 실행되며, 그 Principal이 할 수 있는 일은 AuthZ가 펜싱합니다. 강화 조치는 강력한 하나의 agent가 아니라 *agent별 최소 권한*입니다.

- **agent당 하나의 Principal, agent당 하나의 목적.** 고객 성공 agent와 코딩 agent는 서로 다른 Principal이어야 합니다. 하나가 침해되어도 둘 다 침해되지 않도록 하기 위해서입니다.
- **작업을 수행할 수 있는 최소한만 부여하세요.** channel 읽기 grant는 모든 channel에 쓰기 grant보다 좁고, 특정 resource pattern에 한정된 grant는 와일드카드보다 좁습니다. [Principal and AuthZ](../principal-authz/) 문서를 참조하세요.
- **디렉터리 그룹을 동기화한 다음 그룹에 부여하세요.** 동기화된 AuthZ 그룹을 사용하면 팀 멤버십으로 권한 범위를 정하고, 누군가 퇴사할 때 grant를 하나씩 편집하는 대신 소스 디렉터리에서 그룹 멤버십을 제거하여 권한을 철회할 수 있습니다.
- **의심스러우면 삭제하지 말고 비활성화하세요.** 비활성화된 Principal은 즉시 instance 전체에서 권한을 잃으며, 다시 활성화할 수 있습니다. 삭제된 Principal의 uid는 사라집니다.

감사(audit) 표면은 `/permission-grants`와 `/principals/:uid/grants`입니다. 주기적으로 읽으세요. 생성 당시에는 합리적이었던 grant도 너무 많은 권한으로 어긋날(drift) 수 있습니다.

## 표면 2: Agent가 사용하는 자격 증명

Agent 도구용 자격 증명은 Console에서 **Environment variables**에 secret 저장을 켠 상태로 보관하세요. 각 값을 사용할 수 있는 대상을 제한하고 정기적으로 회전하세요.

- **값을 아껴서 공개하세요.** 자격 증명을 회전하려면 교체 값을 입력하세요. 확인만 하려고 이전 값을 공개하지 마세요. [Environment variables](../worker-env/) 문서를 참조하세요.
- **가능하면 비밀을 agent별로 범위를 한정하세요.** 전역 비밀은 모든 agent에 닿지만, agent별 비밀은 하나에만 닿습니다. 비밀이 실제로 공유되는 경우가 아니면 agent별 형태를 선호하세요.
- **예약된 이름을 덮어쓰지 마세요.** Console에서 `PATH`, `HOME`, `WORKER_ID`, `DATABASE_URL`, `ANKOLE_`로 시작하는 이름, 일부 sandbox 이름은 설정할 수 없습니다. 이 제한을 우회하지 마세요.
- **bootstrap 비밀을 주기적으로 회전하세요.** `ANKOLE_SECRET_BASE`와 `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY`는 다른 키를 파생합니다. 그것들을 회전하는 것은 deployment 재시작 작업이며, `ANKOLE_SECRET_BASE`가 노출될 때의 영향 반경(blast radius)은 instance 전체입니다.

## 표면 3: SSRF 및 model이 제어하는 fetch

`web_fetch`를 가진 agent는 Ankole에 URL fetch를 요청할 수 있습니다. 무엇을 거부할지 결정하는 AppConfigure 키는 `security.ssrf_filter`입니다.

- **기본값은 `false`입니다 — 그리고 바꾸기 전에 그 이유를 읽으세요.** Ankole은 흔히 엔터프라이즈 내부 agent이며 인트라넷 접근이 기대됩니다. 내부 fetch가 동작하도록 필터가 꺼져 있습니다.
- **클라우드 메타데이터 엔드포인트는 설정과 무관하게 항상 차단됩니다.** `169.254.169.254`를 읽으려는 model은 필터가 켜져 있든 꺼져 있든 거부됩니다.
- **필터가 켜져 있으면** private, loopback, link-local, CGNAT 대상을 거부합니다. agent가 공개 인터넷에서 fetch하고 내부 IP에 닿을 정당한 이유가 없을 때 켜세요. 필터는 바로 그 경우를 위해 존재합니다.

이 결정은 deployment instance 전체에 적용됩니다. 잘못된 선택은 “꺼짐”이나 “켜짐”이 아니라, agent가 실제로 도달해야 하는 대상과 일치하지 않는 선택입니다.

## 표면 4: Adapter 자격 증명 회전

각 chat adapter와 identity provider는 자격 증명(`appID`/`appSecret`, `botToken`/`appToken`, `clientId`/`clientSecret`, Entra ID `appPassword`, Google Workspace `serviceAccountKey`)을 보유합니다. 주기적으로, 그리고 유출이 의심될 때마다 회전하세요.

- **먼저 provider에서 회전한 다음 Ankole에서 회전하세요.** provider의 콘솔에서 이전 자격 증명을 무효화한 다음 새 값을 adapter의 AppConfigure에 넣으세요. 순서가 중요합니다. Ankole에서 회전했지만 provider에서는 여전히 유효한 자격 증명은 공격 창(window)이 됩니다.
- **올바른 Console 페이지를 사용하세요.** Agent 도구용 자격 증명은 **Environment variables**에 넣으세요. chat channel과 identity provider 자격 증명은 각각의 Console 페이지에서 회전하세요.
- **디렉터리 동기화 자격 증명도 자격 증명입니다.** Google Workspace `serviceAccountKey`와 `adminEmail`, Graph에 사용되는 Entra ID 앱 — 이것들은 디렉터리를 읽을 수 있습니다. 이것들의 회전을 chat 자격 증명과 같은 수준의 엄중함으로 취급하세요.

## 표면 5: 최소 네트워크 인그레스

Ankole은 어느 정도의 인그레스가 필요하며, 전부가 필요한 경우는 드뭅니다. 각 transport가 실제로 요구하는 수준으로 조이세요.

- **장기 연결 adapter는 아웃바운드만 필요합니다.** Lark, Slack, DingTalk은 아웃바운드 WebSocket/Stream 연결을 엽니다. 공개 인그레스 엔드포인트가 필요하지 않습니다. 이것들만 사용한다면 deployment를 비공개로 유지하세요.
- **Teams와 webhook 인그레스는 공개 엔드포인트가 필요합니다 — 범위를 한정하세요.** Bot Framework와 `/webhooks/v1/...` 정문은 도달 가능해야 합니다. 인그레스를 사용하여 해당 경로를 예상된 provider로 제한하고(가능하면 소스 IP로), 나머지는 adapter 자체 인증(Bot Framework JWT, Graph `clientState`, ZAP/PLAIN worker 인증)에 의존하세요.
- **Webhook delegation URL은 자격 증명입니다.** Agent가 감지(detection)를 외부 시스템에 위임할 때 `/webhooks/v1/event-callbacks/*`는 도달 가능해야 합니다. 인그레스, 프록시, CDN, 애플리케이션 로그에서 전체 경로를 편집(redact)하세요. URL은 깨우기만 인가하므로, Agent는 결과에 영향을 주는 작업 전에 현재 외부 상태를 확인해야 합니다.
- **Console 자체**는 공개 인터넷에 열려 있지 않고 관리자 네트워크 또는 VPN 뒤에 있어야 합니다. bearer 게이트가 무단 접근을 막지만, 관리자 표면을 세상에 노출할 이유는 없습니다.

## 감사 자세

강화는 일회성 작업이 아니라 자세(posture)입니다. 두 가지 습관이 그것을 유지합니다:

- **grant를 주기적으로 읽으세요.** `/permission-grants`와 `/principals/:uid/grants`는 모든 Principal이 무엇을 할 수 있는지 보여 줍니다. 어긋남(drift)은 생기기 마련입니다.
- **복원을 테스트하세요.** [backup-and-restore](../backup-and-restore/) 규율은 보안 통제입니다. 복원할 수 없는 백업은 침해로부터의 복구가 아닙니다.

## 이 가이드가 아닌 것

이 가이드는 침투 테스트도 규정 준수 체크리스트도 아닙니다. Ankole의 기존 경계를 조이는 operator의 조치입니다. “모든 것을 잠그라”는 것도 아닙니다. 최소 권한은 제로 표면이 아니라 사용이 필요로 하는 *최소* 표면을 의미하며, 자신의 일을 할 수 없는 agent는 그 자체로 실패입니다. 그리고 표면별 문서의 대체재도 아닙니다. 위의 각 표면은 정확한 필드를 설명하는 참조 문서로 연결됩니다.

## 다음 단계

- 권한 모델에 대해서는 [Principal and AuthZ](../principal-authz/) 문서를 읽으세요.
- Agent가 사용하는 자격 증명에 대해서는 [Environment variables](../worker-env/) 문서를 읽으세요.
- SSRF 키와 bootstrap 비밀에 대해서는 [Environment variables](../environment-variables/) 문서를 읽으세요.