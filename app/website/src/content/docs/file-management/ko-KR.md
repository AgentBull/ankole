---
title: 파일 관리
description: Console에서 통합 드라이브 루트를 관리하고, Worker의 /drive FUSE 마운트와 첨부 파일 고정 참조 및 휴지통 보관 정책을 다룹니다.
section: User guide
order: 31
---

**일상적인 협업에서는 채팅창에서 바로 파일을 첨부해 보내거나 Pod 페이지에서 함께 작업하면 충분하며, Agent 역시 `/drive` 마운트를 직접 읽고 씁니다. Console 드라이브 브라우저는 Worker가 중지된 상태에서 테넌트의 각 루트를 점검하거나 참고 데이터셋을 올리고 저장된 산출물을 내려받거나 폴더 구조를 정리할 때만 열면 됩니다.**

Ankole는 협업 페이지와 런타임 파일을 **통합 드라이브(Unified Drive)** 하나로 관리합니다. `Ankole.Pod`가 `pages` 트리와 권한, 휴지통 수명 주기를 소유하고, `Ankole.Files`가 테넌트별로 격리된 불변 바이트 객체를 `file_objects`에 보관합니다(문서 삽입 이미지, Base 셀 첨부, Applet 빌드 자산은 `pod_files`에서 별도로 관리되므로 드라이브 목록을 어지럽히지 않습니다). 한편 Session과 Background Agent Job의 작업 디렉터리(`/workspace`)는 드라이브가 아니라 영속 Agent Home 볼륨에 위치합니다. 스토리지 백엔드 설정은 [제어면 드라이브 저장소](../drive-storage/)를, 1.x Home 데이터 이전은 [1.0에서 2.0으로 업그레이드](../upgrade-to-2/)를 참조하세요.

## Worker `/drive` 마운트와 CLI 폴백

FUSE를 지원하는 Worker에서는 루트 슈퍼바이저가 각 명령이나 Codex 프로세스의 전용 마운트 네임스페이스 안에 `/drive`를 마운트한 뒤 권한 없는 `uid 1000`으로 전환하며, 현재 실행 컨텍스트의 권한 그래프가 허용하는 루트만 노출합니다.

| 경로 | 모드 | 내용 |
|---|---|---|
| `/drive/Public` | 읽기·쓰기 | 공유 Pod Space 페이지, 폴더, 파일(일반 디렉터리와 함께 필요 시 `._adoc.md`, `._abase`, `._aapp` 뷰로 투영) |
| `/drive/MyDrive` | 읽기·쓰기 | Agent가 구성원의 Personal Assistant로 동작할 때 해당 인간 소유자의 개인(Private) 공간 |
| `/drive/AgentDrive` | 읽기·쓰기 | 저장된 결과물과 대화 외부에서 생성된 이미지를 담는 Agent 전용 프라이빗 런타임 루트 |
| `/drive/ChatDrive` | 읽기·쓰기 | 수신 첨부 파일, 대화 중 생성된 이미지, 공유 산출물을 담는 현재 대화 전용 격리 루트 |
| `/drive/Brain` | 읽기 전용 | 현재 대화방과 요청자의 공개 범위에 맞춰 필터링된 Brain 지식 페이지 트리(`._awiki.md`) |
| `/drive/Skills` | 읽기 전용 | **Meta Ankole → Skills**에서 관리하는 활성화된 Skill 패키지([Skills](../skills/) 참조) |
| `/drive/AGENTS.md`, `/drive/DESIGN.md` | 읽기 전용 | **Meta Ankole → Agents**에서 관리하는 최종 합성된 행동·디자인 규약([Agents](../agents/) 참조) |
| `/drive-recovery` | 읽기·쓰기(로컬) | 백그라운드 VFS 쓰기 반영 중 `412` 또는 `422` 충돌이 발생했을 때 초안 바이트와 오류 정보를 보존하는 범위별 복구 디렉터리 |

부팅 시점 프로브에서 FUSE를 마운트할 수 없는 환경의 Worker에서는 서명된 WorkerFiles 릴레이를 통해 동작하는 `ankole-files` CLI(`list`, `get --node-id`, `put`, `mv`, `rm`)가 대신 안내됩니다. 또한 채팅 응답에 파일을 첨부하는 `reply_attachment`는 드라이브 `node_id`와 `/drive/...` 경로를 모두 지원하며, 대기 중인 FUSE 쓰기를 먼저 플러시한 뒤 완료된 객체를 참조합니다.

## Console에서 탐색 및 업로드

1. Console에서 대상 테넌트를 선택하고 **Drive**를 엽니다.
2. 실행 중인 Worker가 없어도 **Pod Space**, **Brain**, 구성원 및 Agent의 **Private** 루트, 각 **Conversation** 루트를 바로 탐색할 수 있습니다.
3. 대상 폴더를 열고 **업로드**를 선택해 개별 파일이나 디렉터리 트리를 올립니다. 같은 이름의 기존 파일에 업로드하면 해당 노드의 현재 `object_id`가 새 객체로 교체됩니다.

참고 자료는 `customer-research/2026-q3-interviews.pdf`처럼 맥락이 분명한 경로 아래에 정리하세요. 드라이브에 파일을 올려도 Agent 턴이 자동으로 시작되지는 않으므로, 처리가 필요하면 채팅에서 경로나 페이지를 알려 지시하고 장기 지식으로 추출하려면 **Learn source**로 제출하세요.

## 첨부 파일, 휴지통 및 보관 기간

루트가 아닌 파일이나 폴더 옆의 작업 메뉴에서 이동, 이름 변경, 삭제를 수행할 수 있습니다(각 공간 루트 자체는 이동·이름 변경·삭제할 수 없습니다).

- **통합 드라이브 휴지통:** 파일이나 폴더를 삭제하면 하위 트리가 즉시 휴지통으로 이동하며 드라이브와 Pod 목록에서 숨겨집니다. 휴지통 항목은 `drive.trash_retention_days`(기본값 `30`일, `0`으로 설정하면 설정을 바꿀 때까지 무기한 보관)가 지나 자동 영구 삭제되기 전까지 `manage` 권한이 있는 관리자나 소유자가 복원할 수 있습니다. 영구 삭제에 대비해 중요한 자료는 정기 [백업](../backup-and-restore/)에 포함해 두세요.
- **고정 보존되는 채팅 첨부 파일:** 메시지가 전송될 때 Ankole는 `message_attachments`에 해당 시점의 불변 `object_id`를 기록합니다(런타임에서는 `ankole-pod chat attachment get`으로 조회 가능). 이후 원본 드라이브 파일을 덮어쓰거나 이름을 바꾸고 이동하거나 휴지통에 넣더라도 이미 전송된 대화 첨부 파일은 그대로 내려받을 수 있습니다.

## Worker 재시작 후 유지되는 데이터

통합 드라이브 객체는 PostgreSQL과 오브젝트 스토리지에, `/workspace` 안의 저장소와 작업 파일은 영속 Agent Home에 저장되므로 두 영역 모두 Worker 재시작이나 이미지 교체 후에도 유지됩니다. `/workspace`에만 기록된 파일은 Agent Home 안에 머무르므로 드라이브나 Pod에서 확인하려면 Agent가 `/drive`로 복사(또는 `ankole-files put`으로 게시)해야 합니다. 프로바이더별 스토리지 특성은 [Worker 관리](../worker-management/)를 참조하세요.

## 자주 발생하는 문제

- **업로드한 파일을 Agent가 찾지 못함:** 채팅 메시지에 정확한 `/drive/...` 경로(또는 페이지 링크)를 전달하고, 실행 중인 Agent에 해당 폴더의 `view` 권한이 있는지 확인하세요. FUSE를 마운트하지 않는 Worker에서는 `ankole-files list`와 `ankole-files get --node-id`로 노드를 조회합니다.
- **생성된 산출물이 드라이브에 보이지 않음:** Background Agent Job이 아직 실행 중인지 확인하거나, `/workspace`의 결과 파일을 `/drive/ChatDrive`, `/drive/AgentDrive`, `/drive/Public` 중 원하는 위치로 복사해 달라고 요청하세요.
- **FUSE 쓰기 반영 중 동시 편집 충돌:** Worker 캐시가 커밋되기 전에 다른 작성자가 노드를 수정하거나 이동한 경우(`412` 또는 `422`), 해당 실행 범위의 `/drive-recovery` 디렉터리에서 보존된 초안 파일을 복구할 수 있습니다.
- **용량 제한 오류로 업로드 실패:** 스트리밍 백엔드(`fs`, `s3`, `gcs`, `azblob`, `oss`, `cos`, `tos`, `sftp`)는 백엔드 자체 한도와 `drive.vfs_max_upload_bytes`(0보다 클 때) 중 작은 값을 따릅니다. `postgresql`과 `webdav`는 100 MiB, `d1`은 2,000,000바이트, 구조화 Markdown 페이지 투영은 100 MiB 상한이 적용됩니다.
