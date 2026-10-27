---
title: 보안 강화
description: Ankole deployment instance 강화의 전체적인 형태 — 최소 권한(least authority), 비밀 관리 규율, SSRF, 자격 증명 회전, 최소 인그레스.
section: Guides
order: 316
---

Ankole은 Principal/AuthZ 권한 경계, 암호화된 시크릿 저장소, Agent별 전용 Worker 컨테이너, 인증된 인그레스 등 기본 보안 경계를 갖춘 상태로 제공됩니다. 따라서 보안 강화(hardening)란 새로운 방어벽을 덧대는 작업이라기보다, 이미 마련된 경계를 실제 운영에 꼭 필요한 최소 범위로 조이는 과정입니다. 이 문서에서는 위험도가 큰 영역부터 차례로 여섯 가지 운영 표면을 점검하고 강화하는 방법을 안내합니다.

Ankole 보안 모델의 기본 원칙은 **최소 권한으로 시작해 명확한 근거가 있을 때만 범위를 넓힌다**는 것입니다. 아래의 모든 조치는 권한, 시크릿 노출 범위, 네트워크 경로를 좁히는 방향을 따릅니다. 반대로 범위를 넓혀야 할 때는 그 이유를 먼저 검토하세요.

## 표면 1: Principal 및 AuthZ 권한

모든 Agent는 고유한 Principal 아래에서 실행되며, 허용되는 작업 범위는 AuthZ가 통제합니다. 만능 권한을 가진 단일 Agent 대신 **Agent별 최소 권한** 원칙을 적용하세요.

- **Agent당 하나의 Principal, 하나의 명확한 역할.** 고객 지원 Agent와 코딩 Agent는 서로 다른 Principal로 분리해야 합니다. 그래야 한쪽이 침해되더라도 피해가 다른 역할로 번지지 않습니다.
- **업무 수행에 꼭 필요한 최소 권한만 부여하세요.** 전체 채널 쓰기 권한보다 특정 채널 읽기 권한이 안전하고, 와일드카드보다 구체적인 resource pattern이 안전합니다. 자세한 구조는 [Principal and AuthZ](../principal-authz/)를 참조하세요.
- **디렉터리 그룹을 동기화해 그룹 단위로 권한을 부여하세요.** 동기화된 AuthZ 그룹을 기준으로 권한을 걸어 두면, 퇴사자가 발생했을 때 개별 grant를 일일이 수정하지 않고 사내 디렉터리에서 그룹 멤버십을 해제하는 것만으로 권한을 회수할 수 있습니다.
- **일시 중지(Suspend)와 퇴사 처리(Offboard)를 정확히 구분해 사용하세요.** Principal은 삭제하지 않습니다. **일시 중지(`disposition: :suspended`)** 는 세션, 토큰, 진행 중인 후속 작업을 즉시 차단하되 복직 시 복구할 수 있도록 개인 `SiteCredential`을 남겨 둡니다. 반면 **퇴사 처리(`disposition: :offboarded`)** 는 세션·토큰·작업 차단에 더해 공유되지 않은 `SiteCredential`과 Pod 이메일 바인딩까지 모두 해제하므로, 구성원이 조직을 떠날 때는 반드시 퇴사 처리를 실행해야 합니다.

권한 감사는 `/api/v2/permission-grants`와 `/api/v2/principals/:uid/grants` 엔드포인트로 수행할 수 있습니다. 처음 부여할 때는 적절했던 권한도 시간이 지나며 과도해질(drift) 수 있으니 주기적으로 점검하세요.

## 표면 2: Agent가 사용하는 자격 증명

Agent 도구가 사용하는 외부 자격 증명은 Console의 **Environment variables**에서 secret 저장 옵션을 켠 상태로 보관하고, 접근 대상을 좁혀 주기적으로 교체(회전)하세요.

- **저장된 값을 불필요하게 평문으로 열어 보지 마세요.** 자격 증명을 교체할 때는 기존 값을 먼저 조회하지 말고 새 값을 바로 덮어써 저장하면 됩니다. 자세한 내용은 [Environment variables](../worker-env/)를 참조하세요.
- **가능하면 시크릿 범위를 개별 Agent로 한정하세요.** 사이트나 테넌트 전역 시크릿은 소속된 모든 Agent에 전달되지만, Agent별 시크릿은 해당 Agent 하나에만 전달됩니다. 여러 Agent가 실제로 공유해야 하는 자격 증명이 아니라면 Agent 단위 설정을 우선하세요.
- **예약된 환경 변수 이름을 덮어쓰지 마세요.** `PATH`, `HOME`, `WORKER_ID`, `DATABASE_URL`, `ANKOLE_` 접두사 변수 및 [Environment variables](../worker-env/)에 안내된 예약 이름은 Console에서 설정할 수 없으며, 이 제약을 우회하려 해서는 안 됩니다.
- **부트스트랩 시크릿도 주기적으로 교체하세요.** `ANKOLE_SECRET_BASE`는 저장소 암호화 키를 파생하는 루트 시크릿이고, `ANKOLE_FUNCTION_RUNTIME_TOKEN`은 control plane과 `ankole-function-runtime` 사이의 내부 통신을 인증합니다. 부트스트랩 시크릿 교체에는 배포 재시작이 수반되며, 특히 `ANKOLE_SECRET_BASE`가 유출되면 인스턴스 전체가 영향권에 들어갑니다. 반면 Worker 자격 증명은 운영자가 설정하는 부트스트랩 시크릿이 아닙니다. control plane이 Worker generation마다 무작위 자격 증명을 발급해 인증용 다이제스트만 저장하고, 동일 generation 기동 재시도에 필요한 값은 암호화해 관리합니다.

## 표면 3: SSRF 및 model이 제어하는 fetch

`web_fetch` 권한이 있는 Agent는 Ankole을 통해 URL 조회를 요청할 수 있으며, 차단 대상 대역은 AppConfigure의 `security.ssrf_filter` 키로 제어합니다.

- **기본값은 `false`이며, 변경하기 전에 배포 성격을 먼저 확인하세요.** Ankole은 사내 인트라넷 문서나 내부 시스템을 조회해야 하는 기업 내부용 Agent로 배포되는 경우가 많기 때문에 기본적으로 사설망 접근이 열려 있습니다.
- **클라우드 메타데이터 엔드포인트는 설정값과 무관하게 항상 차단됩니다.** `security.ssrf_filter`가 켜져 있든 꺼져 있든 `169.254.169.254` 조회 시도는 무조건 거부됩니다.
- **`security.ssrf_filter`를 `true`로 켜면** 사설(private), 루프백(loopback), 링크 로컬(link-local), CGNAT 대역으로의 접근이 모두 거부됩니다. Agent가 공개 인터넷만 조회하면 되고 사내 IP에 접근할 이유가 없는 환경이라면 이 필터를 켜 두세요.

이 설정은 배포 인스턴스 전체에 적용됩니다. 무조건 켜거나 끄는 것이 정답이 아니라, 운영 중인 Agent가 실제로 접근해야 하는 네트워크 범위와 일치시키는 것이 핵심입니다.

## 표면 4: Adapter 자격 증명 회전

각 채팅 어댑터와 Identity Provider는 고유 자격 증명(`appID`/`appSecret`, `botToken`/`appToken`, `clientId`/`clientSecret`, Entra ID `appPassword`, Google Workspace `serviceAccountKey`)을 사용합니다. 정기 일정에 따라, 그리고 유출이 조금이라도 의심될 때는 즉시 교체하세요.

- **외부 공급자 콘솔에서 먼저 교체한 뒤 Ankole 설정을 갱신하세요.** 공급자 측에서 새 키를 발급하고 이전 자격 증명을 폐기한 다음 새 값을 어댑터의 AppConfigure에 반영해야 합니다. Ankole에서만 바꾸고 공급자 측에 이전 키를 살려 두면 그대로 공격 노출 구간이 남습니다.
- **자격 증명 성격에 맞는 Console 화면에 저장하세요.** Agent 도구용 키는 **Environment variables**에 두고, 채팅 채널과 Identity Provider 자격 증명은 각각의 전용 설정 페이지에서 관리하세요.
- **디렉터리 동기화용 자격 증명도 동일한 수준으로 관리하세요.** Google Workspace의 `serviceAccountKey` 및 `adminEmail`, Microsoft Graph 조회용 Entra ID 앱 자격 증명은 전사 조직도를 읽을 수 있는 민감한 권한을 가집니다. 채팅 봇 토큰과 똑같은 주기와 보안 기준으로 교체하세요.

## 표면 5: 최소 네트워크 인그레스

Ankole 운영에 인그레스 경로가 일부 필요할 수는 있지만, 모든 경로를 외부에 열어 두어야 하는 경우는 드뭅니다. 사용하는 전송 방식이 실제로 요구하는 경로만 최소한으로 개방하세요.

- **장기 연결형 어댑터는 아웃바운드 연결만 있으면 됩니다.** Lark, Slack, DingTalk은 내부에서 외부로 WebSocket/Stream 연결을 열기 때문에 공개 인그레스 엔드포인트가 전혀 필요하지 않습니다. 이러한 채널만 쓴다면 배포 인스턴스를 비공개 망 안에 그대로 두세요.
- **Teams 및 웹훅 인그레스는 공개 엔드포인트가 필요하므로 경로를 좁혀 노출하세요.** Bot Framework와 `/webhooks/v1/...` 경로는 외부에서 도달할 수 있어야 합니다. 인그레스 계층에서 해당 경로만 열고(가능하면 공급자 소스 IP 대역도 제한), 요청 검증은 각 어댑터의 자체 인증(Bot Framework JWT, Graph `clientState` 등)에 맡기세요.
- **Webhook 위임 콜백 URL은 그 자체가 자격 증명입니다.** Agent가 외부 시스템의 이벤트 감지를 기다릴 때는 `/webhooks/v1/event-callbacks/*` 경로가 열려 있어야 합니다. 인그레스, 리버스 프록시, CDN, 애플리케이션 로그 전반에서 콜백 토큰이 포함된 전체 URL 경로가 기록되지 않도록 마스킹(redact)하세요. 또한 콜백 URL은 세션을 깨우는 권한만 부여하므로, 실제 상태 변경이나 보고를 수행하기 전에는 Agent가 반드시 외부 시스템의 최신 원본 상태를 직접 다시 확인해야 합니다.
- **Console 화면 자체**는 공개 인터넷에 직접 노출하지 말고 사내 관리망이나 VPN 뒤에 배치하세요. 인증 게이트가 무단 접근을 차단하더라도 관리자 인터페이스를 외부에 열어 둘 이유는 없습니다.

## 표면 6: Worker 컨테이너, Function Runtime 및 control plane

각 Agent는 전용 Worker 컨테이너 또는 Pod를 단독으로 사용하며, 다른 Agent와 Worker, 캐시 디스크, 자격 증명을 공유하지 않습니다. 또한 무상태 TypeScript 프로그램(Workflow, PTC, Applet 백엔드)은 데이터베이스 자격 증명이나 Kubernetes ServiceAccount 토큰이 없는 별도의 `ankole-function-runtime` 서비스에서 격리 실행됩니다. 즉 컨테이너 자체가 격리 경계입니다. Worker 내부의 셸 명령, Codex app-server, Automation 스크립트, 브라우저는 추가 내부 샌드박스 없이 Worker 사용자(`uid 1000`, Linux capabilities 및 `sudo` 없음) 권한으로 실행됩니다.

- 모든 명령은 `sudo` 권한 없는 `uid 1000`으로 실행되므로, Home 디렉터리 안에 사용자 수준 패키지는 설치할 수 있어도 시스템 패키지는 설치할 수 없습니다. 다만 같은 Agent에 속한 여러 Session끼리는 동일한 Home 파일과 프로세스 공간을 공유합니다.
- **Worker 자격 증명은 오직 해당 Agent 하나에만 귀속됩니다.** Worker 데몬은 인증 자격 증명을 메모리에만 보관하며 하위 명령의 환경 변수에서는 제거합니다. 다른 Agent의 자격 증명이나 이미 교체된 이전 Worker의 자격 증명으로는 연결이 거부됩니다.
- **control plane은 호스트 root에 준하는 핵심 자산으로 보호하세요.** control plane은 Docker 소켓이나 네임스페이스 Role(Pod, Secret, PVC 생성·삭제 권한)을 통해 Worker를 제어하며, 특히 Docker 소켓 접근 권한은 호스트 root 권한과 사실상 동일합니다.
- **Kubernetes 환경에서는 gVisor를 함께 적용하세요.** Kubernetes provider YAML의 `podTemplate.spec.runtimeClassName`에 클러스터의 gVisor RuntimeClass(예: `gvisor`)를 지정하면 됩니다. 기존 인스턴스 설정을 바꾸면 해당 풀의 Worker는 유휴 상태가 될 때 새 설정으로 교체됩니다. Helm의 `worker.runtimeClassName` 값은 최초 기동 시 기본 provider를 시드할 때만 쓰이므로, 이미 등록된 뒤에는 Console에서 provider 설정을 직접 수정하세요.
- **Worker와 `ankole-function-runtime`의 이그레스(egress) 범위를 제한하세요.** Docker Compose에서는 Worker 컨테이너가 `ankole_workers` 브리지에, `ankole-function-runtime`이 `ankole_functions` 브리지에 연결되어 control plane과 외부 인터넷에는 접근할 수 있지만 내부 `ankole_backend` 네트워크의 PostgreSQL에는 접근할 수 없습니다. 클라우드 VM 위에서 운영할 때는 인스턴스 메타데이터 hop limit을 `1`로 설정하거나 컨테이너에서 `169.254.169.254` 대역을 차단하세요. Helm 배포에서 `networkPolicy.enabled`를 켜면 Worker Pod의 인바운드 연결이 차단되고 이그레스는 control plane, DNS, `networkPolicy.workerDeniedCIDRs` 바깥의 공개 주소로만 제한되며, 전용 `NetworkPolicy`를 통해 `ankole-function-runtime` 역시 control plane 인그레스와 `functionRuntime.deniedCIDRs`(사설 및 메타데이터 CIDR 제외) 바깥의 공개 이그레스만 허용됩니다. 클러스터 노드의 인스턴스 메타데이터 hop limit도 `1`로 설정하세요.

## 감사 자세

보안 강화는 한 번 설정하고 끝나는 작업이 아니라 지속적인 운영 습관으로 유지해야 합니다.

- **주기적으로 권한 목록을 점검하세요.** `/api/v2/permission-grants`와 `/api/v2/principals/:uid/grants`를 조회하면 각 Principal에 열려 있는 권한을 전부 확인할 수 있습니다. 운영 기간이 길어질수록 불필요한 권한이 누적되기 쉽습니다.
- **백업 복원 절차를 실제로 리허설하세요.** [backup-and-restore](../backup-and-restore/) 절차는 그 자체로 핵심 보안 통제 수단입니다. 실제 상황에서 복원해 보지 않은 백업은 침해 사고 시 복구 수단이 될 수 없습니다.

## 이 가이드가 아닌 것

이 문서는 모의 침투 테스트 매뉴얼이나 규정 준수 인증 체크리스트가 아니라, Ankole이 제공하는 보안 경계를 운영 환경에 맞게 조이는 실무 지침입니다. 또한 무조건 모든 기능을 막으라는 뜻도 아닙니다. 최소 권한이란 표면적을 0으로 만드는 것이 아니라 업무 수행에 꼭 필요한 최소 범위만 여는 것이며, 정상 업무조차 처리하지 못하게 막아 버리는 설정은 올바른 강화가 아닙니다. 각 항목의 세부 필드 규격은 연결된 개별 레퍼런스 문서를 함께 확인하세요.

## 다음 단계

- 권한 평가 모델 상세 구조는 [Principal and AuthZ](../principal-authz/)를 참조하세요.
- Agent 도구용 자격 증명 관리는 [Environment variables](../worker-env/)를 참조하세요.
- SSRF 설정 키와 부트스트랩 시크릿은 [Environment variables](../environment-variables/)를 참조하세요.
- Agent 명령이 실행되는 Worker 구조는 [Agent Computer Worker](../agent-computer-worker/)를 참조하세요.
