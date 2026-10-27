---
title: Audit trail(감사 기록)
description: Ankole의 audit 표면 읽는 방법 — AuthZ grant 기록, control-plane 구조화 log, 그리고 각 표면이 누가 무엇을 언제 변경했는지를 어떻게 기록하는지 설명합니다.
section: Developer guide
order: 125
---

감사 기록(audit trail)은 누가, 언제, 무엇을 변경했는지 추적할 수 있도록 남기는 영구 기록입니다. Ankole은 단일 통합 감사 로그 하나에 모든 것을 몰아넣는 대신, 각 서브시스템이 자신이 책임지는 핵심 의사결정과 상태 변화를 전용 표면에 기록하는 구조를 취합니다. 이 문서는 운영자를 위해 각 감사 표면이 무엇을 담고 있는지, 어떻게 조회하는지, 그리고 여러 표면을 어떻게 교차 확인하는지 안내합니다.

가장 중요한 공통 원칙은 모든 감사 표면이 휘발성 메모리 지표가 아니라 **영구 PostgreSQL 테이블 또는 구조화된 로그 스트림**이라는 점입니다. 이미 기록된 행은 이를 남긴 프로세스가 종료되어도 보존되지만, 애초에 수집·보관하지 않은 로그는 사후에 재구성할 수 없습니다.

## AuthZ grant, 사람 접근 변경 및 초대 기록

모든 권한 부여 내역은 `permission_grants` 테이블의 영구 행으로 저장됩니다. 각 grant는 단일 `principal_uid`, 단일 `group_id`, 또는 Userset 페이지 대상(`source_page_id` 및 `source_action`)에 귀속되며, Pod ACL grant는 `target_page_id`와 `target_scope`를 통해 특정 `pages` 행을 기준으로 설정됩니다. 허용 대상과 범위는 `resource_pattern`, `action`, `condition` 컬럼에 명시되고 생성 시각과 최종 수정 시각이 타임스탬프로 남습니다. 별도의 grant 감사 로그 테이블을 따로 두지 않으며, `permission_grants` 테이블 자체가 정본 기록 역할을 합니다.

사람 계정의 접근 상태 변경과 워크스페이스 초대 이력 역시 PostgreSQL에 영구 행으로 기록됩니다.

- `human_access_events` 테이블에는 계정 비활성화, 복원, 디렉터리 동기화에 따른 상태 전환이 발생할 때마다 실행 주체, 변경 출처, 이전·현재 상태, `access_version`, 해제된 식별자(`released_identifiers`)가 기록됩니다.
- `human_access_restrictions` 테이블에는 `:suspended`(일시 중지) 또는 `:offboarded`(퇴사·오프보딩) 처분(`disposition`)과 제한 사유를 담은 현재 활성 제한 상태가 저장됩니다.
- `pod_invitations` 테이블에는 Pod 워크스페이스 초대 내역, 멤버십 유형(`member` 또는 `guest`), 누적 사용 횟수(`used_count`), 초대 생성자(`created_by_principal_uid`)가 기록됩니다.

Principal 및 권한 그룹의 현재 grant 목록은 `GET /api/v2/principals/:uid/grants`와 `GET /api/v2/principal-groups/:name/grants`로 조회할 수 있습니다. 현재 테이블에 존재하는 행이 곧 런타임에 강제되는 유효 권한이며, 과거에 부여되었다가 삭제된 이력까지 추적해야 할 때는 PostgreSQL의 시점 복구(PITR) 기록을 활용합니다.

## 구조화된 control-plane log

control plane은 이벤트 이름, 사람이 읽기 쉬운 메시지, 구조화된 컨텍스트 필드, 심각도(`debug`~`error`)로 이루어진 일관된 형식의 구조화 로그를 출력합니다. 실시간 운영 이벤트에 대한 감사 추적은 이 로그 스트림을 통해 이루어집니다.

- 업스트림 provider 호출 내역(호출된 provider, 모델, 응답 결과)
- Worker 수명 주기 이벤트(인스턴스 시작, turn 진입, turn 완료 및 오류)
- Signal 유입 이벤트(도착한 자극의 종류, 필터링 또는 수락 결과)
- 정기 스케줄 실행 내역(실행 시각 및 처리 결과)

구조화 로그는 PostgreSQL에 적재되지 않으며, 외부 로그 수집기(ingester)가 받아 보관하는 데이터가 유일한 기록입니다. 따라서 감사 목적으로 장기 보존이 필요하다면 로그 인덱스나 S3 아카이브 같은 영구 저장소로 실시간 전송하도록 구성하세요. 외부로 수집되지 않은 표준 출력 로그는 컨테이너나 프로세스가 사라질 때 함께 소멸합니다.

로그 출력 설정은 [Environment variables](../environment-variables/)를, 로그 해석과 장애 진단 방법은 [Read Ankole logs](../log-reading/)를 참조하세요.

## Signal 및 delivery 행

실행 세션을 깨우는 모든 Signal(영구 인박스 항목)과 외부 채널로의 모든 응답 전달(delivery) 시도는 PostgreSQL에 개별 행으로 기록됩니다. 이 행들은 런타임 운영 상태인 동시에 시스템이 어떤 요청을 수락해 어떤 응답을 내보냈는지를 증명하는 실행 원장이기도 합니다. Console API의 `/api/v2/background-agent-jobs/:id` 라우트에서는 백그라운드 작업의 시도 횟수(`attempts`)와 오류(`error`)를 확인할 수 있고, `/api/v2/ai-gateway/conversations` 라우트에서는 각 turn에서 수행된 모델 호출 내역을 조회할 수 있습니다.

## 함께 사용하기

실무 감사 질의는 대개 두 개 이상의 표면을 함께 대조해 확인합니다.

| 질문 | 확인할 곳 |
|---|---|
| “누가 이 Agent 또는 페이지 대상에게 Y 작업 권한을 부여했는가?” | `permission_grants` 테이블 및 `/api/v2/principals/:uid/grants` · `/api/v2/principal-groups/:name/grants` |
| “왜 특정 사용자 계정이 일시 중지·오프보딩되었거나 초대되었는가?” | `human_access_events`, `human_access_restrictions`, `pod_invitations` |
| “특정 turn에서 Agent가 구체적으로 어떤 호출을 수행했는가?” | `/api/v2/ai-gateway/conversations/:id/messages` |
| “예약된 스케줄이 정시에 실행되었는가?” | `/api/v2/cron-schedules/:id/runs` |
| “실패한 백그라운드 Job이 몇 번 재시도되었는가?” | `/api/v2/background-agent-jobs/:id`(`attempts`, `error`) |
| “당시 Worker나 컨트롤 플레인에서 어떤 런타임 로그가 남았는가?” | 구조화된 control-plane 로그 스트림 |

## 이 가이드가 아닌 것

이 문서는 법적 컴플라이언스 규정집이 아닙니다. Ankole은 감사 데이터를 남기는 표면을 제공하며, 보관 주기와 접근 통제 정책은 각 조직의 보안·규제 체계에 맞춰 수립해야 합니다. 또한 특정 SIEM 솔루션 연동 매뉴얼도 아닙니다. Ankole은 표준 구조화 JSON 로그를 출력하므로 조직에서 사용하는 수집기를 자유롭게 연결하면 됩니다. 마지막으로, 감사 기록이 검증된 백업을 대신할 수는 없습니다. 핵심 감사 원장이 PostgreSQL에 저장되므로 데이터베이스 자체를 복구할 수 없게 되면 감사 기록도 함께 유실됩니다.

## 다음 단계

- 전체 권한 판정 모델은 [Principal and AuthZ](../principal-authz/)를 참조하세요.
- 로그 출력 설정과 분석 방법은 [Environment variables](../environment-variables/)와 [Read Ankole logs](../log-reading/)를 참조하세요.
- 감사 원장을 안전하게 보존하는 백업 절차는 [Backup and restore](../backup-and-restore/)를 참조하세요.