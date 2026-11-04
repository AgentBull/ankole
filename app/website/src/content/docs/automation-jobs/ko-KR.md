---
title: Automation Job
description: 일정, 콜백, 외부 이벤트로 Applet Action을 실행하고 저장된 결과를 확인합니다.
section: User guide
order: 22
---

Automation Job은 게시된 Applet의 Action을 Function Runtime에서 실행합니다. 정해진 처리를 위해 매번 Agent 턴을 시작할 필요가 없습니다. Job은 설정과 영구 상태를 저장하고, Applet 코드는 처리 함수와 동시 실행 정책, 이어서 실행할 횟수를 정의합니다.

## 만들고 연결하기

1. 서버 모듈에서 `actions`를 내보내는 Applet을 게시합니다.
2. Applet의 자동화 패널에서 Action을 선택하고 개인 또는 팀 Job을 만듭니다.
3. 일정, 콜백 엔드포인트, 외부 이벤트 소스를 추가합니다. 일정은 Cron과 고정 간격을 지원합니다.
4. 일정을 수동 실행하거나 테스트 콜백을 보낸 뒤 Run의 입력과 결과를 확인합니다.

Agent도 `ankole-pod jobs`로 같은 작업을 수행합니다. 명령 규약은 `ankole-pod --help`를 확인하세요. Applet 화면에서는 `@ankole/applet-sdk`의 `useAppletJobs()`와 `useJobSources(jobID)`를 사용할 수 있습니다.

## 실행 권한

개인 Job은 소유한 직원의 권한으로 실행되며, 본인과 개인 비서가 소스를 관리합니다. 팀 Job은 Applet 소유자의 서비스 권한을 사용하고, 관리하려면 페이지 편집 권한이 필요합니다. Applet을 휴지통으로 옮기면 새 실행을 받지 않습니다. Job을 삭제하면 소유한 일정과 콜백 엔드포인트를 삭제하고 외부 이벤트 연결을 해제합니다. 다른 소비자가 쓰는 공유 구독은 유지됩니다.

## 입력과 결과

Action은 `ctx.signal`, `ctx.job.config`, 영구 저장되는 `ctx.state`를 사용합니다. 긴 작업은 `remainingMs()`와 `continueSlice()`로 나누어 실행합니다. 외부 도구는 `AnkoleRuntime.mcp`로 호출하며, 팀 실행은 해당 `AnkoleRuntime.admin` 기능을 사용합니다. 앱 자격 증명과 개인 승인은 Pod의 연결 페이지에서 관리합니다.

자동화 패널에서 상태, 시작·종료 시각, 트리거, 결과, 오류, 길이가 제한된 로그를 확인합니다. 입력과 로그는 필요할 때 펼쳐 볼 수 있습니다. 전달 기록은 Run에 연결되며, 입력이 대기 중인 실행에 병합되었는지도 표시합니다. 개인 승인이 필요하면 제공된 링크에서 승인한 뒤 다시 시도합니다. 부분 쓰기 오류는 생성된 리소스 ID를 반환하므로 남은 단계만 복구할 수 있습니다.

코드는 Applet을 다시 게시해 갱신합니다. 실행 간 상태는 로컬 파일이 아니라 `ctx.state`에 보관하고, 선언한 재실행 정책에 맞게 외부 쓰기를 설계하세요.

[일정](../schedules/), [Webhook 위임](../webhook-delegations/), [자동화 구성 예시](../automation-blueprints/)도 참고하세요.
