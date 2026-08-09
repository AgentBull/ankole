---
title: 운영자 팁
description: Ankole 운영 시 시간을 절약해 주는 검증된 짧은 요령 — 로그 읽기, 에이전트 범위 설정, 시크릿 순환, 멈춘 턴 복구, 모델 프로파일 다이얼 올바르게 설정하기.
section: Guides
order: 308
---

이 페이지는 하나의 가이드에 깔끔하게 담기지 않았지만 자주 등장하는 운영자 요령 모음입니다. 각 팁은 짧고 Ankole이 실제로 작동하는 방식에 근거하며, 고생 끝에 발견하는 첫 번째 시간보다 비용이 적게 듭니다.

## 로그를 로컬에서 예쁘게 읽기

제어 플레인은 기본적으로 구조화된 JSON 로그를 내보냅니다 — 수집에는 좋지만 읽기는 어렵습니다. 로컬 개발에서는 devkit pretty-printer에 파이프하세요:

```bash
bun run dev   # in one terminal
bun run kit logs pretty < /path/to/log-stream   # or pipe a log file through it
```

프로덕션에서는 `ANKOLE_LOG_FORMAT=json`을 유지하고 로그 수집기가 형식을 처리하게 하세요. pretty printer는 로컬 편의 도구이지 프로덕션 설정이 아닙니다.

## 버그 사냥 전에 로그 레벨 범위 설정

`ANKOLE_LOG_LEVEL`은 기본값이 `info`입니다. 특정 재현을 위해 `debug`로 낮추고 끝나면 되돌려 놓으세요 — `debug`로 방치된 배포는 시끄럽고 느립니다. 유효한 값은 `debug | info | warning | error`이며, 유효하지 않은 값은 부팅 시 거부되고 조용히 무시되지 않습니다.

## 터미널 없이 활성화 코드 얻기

`bun dev`(또는 제어 플레인 컨테이너) 터미널이 보이지 않고 설정 페이지가 코드를 요구하면:

```bash
bun run kit show bootstrap-activation-code          # local
docker compose logs control-plane | grep "SETUP ACTIVATION CODE"   # Compose
kubectl -n ankole logs deployment/ankole-control-plane -c control-plane | grep "SETUP ACTIVATION CODE"   # Helm
```

데이터베이스에서 코드를 짐작하지 마세요 — 설정 플로우가 실제로 사용하는 소스에서 읽으세요.

## 모델 프로파일 슬롯을 다이얼로 취급

열 개의 프로파일 슬롯은 단지 “primary 모델과 그 친구들”이 아닙니다. 각각은 다이얼입니다:

- 에이전트가 주로 빠른 질문에 답할 때는 **`primary`**를 더 저렴한 모델로 낮추고, 품질이 비용보다 중요할 때는 올리세요.
- **`light`**는 진짜로 저렴하고 빠른 모델에 바인딩하세요 — 고용량·저중요도 경로를 위해 존재합니다.
- **`vision_fallback`**은 에이전트가 이미지를 보는 경우에만 설정하세요. 그렇지 않으면 바인딩하지 않고 슬롯을 아끼세요.
- **`web_search`**와 **`web_fetch`**는 독립적입니다 — 에이전트가 웹에 접근해야 할 때만 바인딩하세요.

“느리게 느껴지는” 에이전트는 대개 실제로 하는 작업에 비해 너무 무거운 `primary`가 바인딩된 경우입니다.

## 환경 변수에서 credential 순환

Worker 환경 변경은 현재 실행 중인 턴이 아니라 **다음 턴**부터 적용됩니다. 따라서:

1. Console의 **Environment variables**에 새 값을 입력하고 저장하세요.
2. 진행 중인 턴이 끝나도록 두세요 — 이미 자체 환경을 가지고 있습니다.
3. 새 메시지를 보내 새 값이 적용되었는지 확인하세요.

저장 당시 실행 중이던 턴으로 시크릿 변경을 판단하지 마세요. 그 턴은 새 값을 보지 못합니다.

## 암호화된 값은 필요할 때만 공개

credential을 순환하려면 교체 값을 입력하세요. 확인만 하려고 이전 값을 공개하지 마세요. **Reveal**은 문제를 진단하기 위해 현재 값을 검사해야 할 때만 선택하세요.

## 멈춘 턴 복구

멈춘 것처럼 보이는 턴은 대개 Ankole이 아니라 모델이나 제공자를 기다리는 것입니다. 무엇이든 취소하기 전에:

1. `/ai-gateway/conversations`에서 턴의 최근 모델 호출을 확인하세요 — 긴 공백이 있으면 제공자가 지연의 원인입니다.
2. worker 로그에서 진행 중인 tool call을 확인하세요 — 느린 도구는 멈춘 턴처럼 보입니다.
3. 턴이 진짜로 꼬인 경우에만 에이전트의 세션을 steer하거나 턴이 타임아웃되도록 둘 수 있습니다. 백그라운드 Job의 취소는 `POST /background-agent-jobs/:id/cancel`이며, 진행 중인 턴은 끝까지 완료됩니다.

공격적으로 취소하는 것이 운영자가 절반만 된 부수 효과를 만드는 방법입니다.

## 바인딩을 조용히 비활성화

`DELETE /agents/:agent_uid/signal-bindings/:binding_name`은 하드 삭제가 아니라 *비활성화*입니다 — 구성은 복구 가능한 상태로 유지됩니다. 설정을 잃지 않고 에이전트를 채널에서 조용히 만들고 싶을 때(자격 증명이 폐기된 경우, 휴일, 사고) 사용하세요. `PATCH`로 다시 활성화합니다.

## 업그레이드 전에는 매번 백업

Helm 롤백은 데이터베이스 마이그레이션을 되돌리지 않습니다. 업그레이드 전 2분짜리 `pg_dump`는 “롤백됨”과 “백업에서 복원, 하루를 잃음”의 차이입니다. 명령은 [Backup and restore](../backup-and-restore/)를 참조하세요.

## 올바른 영구 문서 조정

Agent의 책임이 불분명하면 `MISSION.md`를 편집하세요. 커뮤니케이션 또는 판단이 잘못되었으면 `SOUL.md`를 편집하세요. 웹 페이지, 슬라이드, 문서, 차트에 일관된 시각 스타일이 없으면 `DESIGN.md`를 편집하세요. 각 파일은 하나의 관심사를 소유하므로 비주얼 디자인 시스템에 동작 규칙을 넣지 마세요.

## DingTalk 에이전트당 로봇 하나

DingTalk은 엄격한 제약을 적용합니다: 에이전트당 활성화 바인딩 하나, `clientId`당 에이전트 하나. 확장한다면 에이전트마다 로봇 하나를 계획하세요. 동일한 에이전트의 두 번째 바인딩은 `dingtalk_binding_already_exists`로 실패합니다. 다른 에이전트에서 `clientId`를 재사용하면 `dingtalk_app_already_bound`로 실패합니다. 설정은 [Quickstart](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule)를 참조하세요.

## Teams는 항상 공개 엔드포인트 필요

Teams는 긴 연결이 아니라 Bot Framework 웹훅 호출로 전달합니다. Teams 봇이 작동을 멈추면 가장 먼저 확인할 것은 공개 HTTPS 엔드포인트입니다 — 인증서 만료, DNS 변경, 인그레스 다운타임 모두 “봇이 응답을 멈췄다”처럼 보입니다. Lark, Slack, DingTalk는 긴 연결을 사용하므로 짧은 엔드포인트 중단을 견디지만 Teams는 그렇지 않습니다.

## 다음 단계

- Console 인터페이스 참조에 대해서는 [Console API reference](../console-api/)를 읽으세요.
- 환경 노브에 대해서는 [Environment variables](../environment-variables/)를 읽으세요.
- kit 명령에 대해서는 [kit CLI reference](../kit-cli/)를 읽으세요.