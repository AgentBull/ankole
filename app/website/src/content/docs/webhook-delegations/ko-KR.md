---
title: Webhook 위임
description: Connector 구독과 Job·Agent 콜백으로 외부 이벤트를 받습니다.
section: User guide
order: 23
---

외부 이벤트는 Connector 구독이나 발신자가 POST할 수 있는 콜백 URL로 받습니다. Ankole은 전달을 영구 저장한 뒤 수신을 확인하고, 연결 설정에 따라 Agent 또는 Applet Job에 전달합니다.

## 소스 선택

GitHub 저장소·조직 이벤트와 Lark 승인·일정 변경은 Pod 연결 페이지에서 설정합니다. 관리자가 앱을 등록하고 필요하면 사용자가 개인 계정을 승인합니다. 리소스를 선택해 구독을 만들면 제어면이 상위 서비스의 등록과 삭제를 관리합니다. 실패 상태에서는 다시 시도할 수 있습니다.

범용 콜백은 Applet 자동화 패널에서 Job용으로 만듭니다. `standing` 또는 `one_shot`과 만료 시각을 지정한 뒤 한 번만 표시되는 URL을 발신자에게 복사하고 테스트하세요. Agent 대화를 재개할 콜백은 `create-webhook-cli --help`의 규약에 따라 만들 수 있습니다.

## 전달과 관리

`one_shot`은 처음 일치한 전달만 처리하고, `standing`은 일시 중지·취소·만료될 때까지 받습니다. 소비자는 상위 이벤트의 중복을 처리할 수 있어야 하며, 중요한 작업 전에는 원본 시스템의 현재 상태를 확인해야 합니다.

Job이 소유한 엔드포인트는 Agent 세션 없이 Applet Action을 실행합니다. Action은 `ctx.signal`을 읽고, 자동화 패널에서 전달 기록과 Run 상태·입력·결과·로그를 확인합니다. 개인 엔드포인트는 소유자 권한, 팀 엔드포인트는 페이지 권한을 따릅니다. Job을 삭제하면 소유 엔드포인트도 삭제하지만 다른 소비자가 사용하는 공유 Connector 구독은 유지됩니다.

일시 중지는 설정을 남기고 수신을 멈춥니다. 종료하려면 취소 또는 삭제를 사용합니다. 범용 엔드포인트를 취소해도 발신자에게 별도로 만든 Webhook은 삭제되지 않습니다.

HTTPS로 `/webhooks/v1/event-callbacks/*`와 필요한 `/webhooks/connectors/*` 경로를 전달하세요. 콜백 URL은 비밀로 관리하고 프록시 로그에서도 숨겨야 합니다. URL 소유는 이벤트 제출을 허용할 뿐 내용의 정확성을 보증하지 않습니다. 실패하면 발신자 로그, 만료, 승인, 전달 기록, Run 순서로 확인합니다.

[Automation Jobs](../automation-jobs/)와 [Signals](../signals/)를 참고하세요.
