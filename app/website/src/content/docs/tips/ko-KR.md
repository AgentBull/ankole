---
title: 운영자 팁
description: Ankole 운영 시 시간을 절약해 주는 검증된 짧은 요령 — 로그 읽기, 에이전트 범위 설정, 시크릿 순환, 멈춘 턴 복구, 모델 프로파일 다이얼 올바르게 설정하기.
section: Guides
order: 308
---

이 페이지에서는 개별 가이드 하나에 넣기는 애매하지만 실무 운영에서 자주 마주치는 실용적인 요령들을 모아 소개합니다. 모두 Ankole의 실제 동작 원리에 기반한 짧은 팁으로, 미리 알아 두면 시행착오로 몇 시간씩 허비하는 일을 덜 수 있습니다.

## 로그를 로컬에서 예쁘게 읽기

제어 플레인은 기본적으로 수집 시스템에 적합한 구조화된 JSON 로그를 출력하므로 터미널에서 눈으로 바로 읽기에는 불편합니다. 로컬 개발 환경에서는 devkit의 pretty-printer로 파이프해 확인하세요.

```bash
bun run dev   # in one terminal
bun run kit logs pretty < /path/to/log-stream   # or pipe a log file through it
```

프로덕션 환경에서는 JSON 로그를 그대로 로그 수집 시스템에 보내고, 로컬에서 직접 확인할 때만 pretty-printer를 사용하세요.

## 버그 사냥 전에 로그 레벨 범위 설정

`ANKOLE_LOG_LEVEL`의 기본값은 `info`입니다. 특정 문제를 재현할 때만 잠시 `debug`로 낮추고, 확인이 끝나면 바로 원래대로 되돌려 두세요. `debug` 상태로 방치하면 로그량이 폭증하고 처리 성능도 떨어집니다. 허용되는 값은 `debug | info | warning | error` 네 가지뿐이며, 잘못된 값을 넣으면 조용히 무시되지 않고 부팅 단계에서 즉시 거부됩니다.

## 터미널 없이 활성화 코드 얻기

초기 설정 화면에서 활성화 코드를 입력해야 하는데 `bun dev` 터미널이나 제어 플레인 컨테이너 표준 출력을 바로 볼 수 없다면 다음 명령으로 조회할 수 있습니다.

```bash
bun run kit show bootstrap-activation-code          # local
docker compose logs control-plane | grep "SETUP ACTIVATION CODE"   # Compose
kubectl -n ankole logs deployment/ankole-control-plane -c control-plane | grep "SETUP ACTIVATION CODE"   # Helm
```

데이터베이스 테이블을 뒤져 코드를 추측하려 하지 말고, 설정 플로우가 실제로 출력한 원본 소스에서 그대로 읽어 오세요.

## 모델 프로파일 슬롯을 다이얼로 취급

Agent에 내장된 8개의 모델 프로파일 슬롯(`primary`, `light`, `heavy`, `coding`, `vision_fallback`, `web_search`, `web_fetch`, `image_generate`)은 각각 역할에 맞게 조절하는 다이얼과 같습니다.

- 간단한 질의응답 위주의 Agent라면 **`primary`**에 가볍고 저렴한 모델을 연결하고, 비용보다 판단 품질이 중요한 역할일 때만 상위 모델로 올리세요.
- **`light`**에는 실제로 빠르고 저렴한 경량 모델을 바인딩하세요. 호출 빈도는 높고 중요도는 낮은 보조 경로를 위해 마련된 슬롯입니다.
- **`vision_fallback`**은 이미지를 읽어야 하는 Agent에만 설정하고, 그렇지 않다면 비워 두세요.
- **`web_search`**와 **`web_fetch`**는 서로 독립된 슬롯이므로 웹 접근이 필요한 Agent에만 각각 바인딩하세요.
- Brain 검색용 모델은 **AppConfigure**에서 별도로 지정합니다. 사이트 범위의 `brain.embedding_model`은 전체 Agent의 벡터 검색에 쓰이고, 각 테넌트의 `brain.rerank_model`은 해당 테넌트의 재정렬(rerank)에 쓰입니다. embedding 모델을 비워 두면 벡터 검색이 비활성화되고, rerank 모델을 비워 두면 융합(fusion) 검색 순위가 그대로 유지됩니다. 자세한 내용은 [Brain](../brain/)을 참조하세요.

응답이 유독 느리게 느껴지는 Agent는 실제 업무 난도에 비해 지나치게 무거운 모델이 `primary`에 바인딩되어 있는 경우가 많습니다.

## 환경 변수에서 credential 순환

Worker 환경 변수 변경 사항은 지금 돌고 있는 턴이 아니라 **다음 턴**부터 반영됩니다. 따라서 자격 증명을 교체할 때는 다음 순서를 따르세요.

1. Console의 **Environment variables**에서 새 값을 입력하고 저장합니다.
2. 현재 실행 중인 턴이 있다면 끝날 때까지 기다립니다(해당 턴은 이미 시작 시점의 환경을 물고 있습니다).
3. 새 메시지를 보내 바뀐 값이 정상 적용되었는지 확인합니다.

저장 버튼을 누르기 전부터 실행 중이던 턴의 결과를 보고 시크릿 교체가 안 되었다고 오해하지 마세요. 진행 중인 턴에는 새 값이 전달되지 않습니다.

## 암호화된 값은 필요할 때만 공개

자격 증명을 교체할 때는 이전 값을 먼저 열어 볼 필요 없이 새 값을 바로 입력해 덮어쓰면 됩니다. **Reveal** 기능은 장애 원인을 진단하기 위해 현재 저장된 값을 직접 대조해야 할 때만 제한적으로 사용하세요.

## 멈춘 턴 복구

턴이 멈춘 것처럼 보일 때 실제 원인은 Ankole 내부가 아니라 업스트림 모델 응답 지연이나 외부 도구 대기인 경우가 대부분입니다. 성급하게 취소하기 전에 다음 순서로 확인하세요.

1. `/api/v2/ai-gateway/conversations`에서 해당 턴의 최근 모델 호출 기록을 확인합니다. 호출 후 응답까지 긴 공백이 있다면 모델 공급자 측 지연입니다.
2. Worker 로그에서 현재 실행 중인 도구 호출이 있는지 살펴봅니다. 외부 명령이나 도구가 느리게 돌고 있으면 턴 전체가 멈춘 것처럼 보입니다.
3. 턴이 실제로 잘못된 방향에 빠졌을 때만 세션에 steer 메시지를 보내거나 타임아웃되도록 두세요. 백그라운드 Job을 취소할 때는 `POST /api/v2/background-agent-jobs/:id/cancel`을 호출하며, 이때도 현재 실행 중인 턴은 안전하게 마무리된 뒤 종료됩니다.

원인을 확인하지 않고 강제로 취소부터 하면 외부 작업의 부수 효과가 어정쩡하게 중간에서 끊긴 상태를 만들게 됩니다.

## 바인딩을 조용히 비활성화

`DELETE /api/v2/agents/:agent_uid/signal-bindings/:binding_name` 호출은 영구 삭제가 아니라 **비활성화**로 동작하므로 기존 설정이 그대로 보존됩니다. 토큰 폐기나 연휴, 장애 대응 등으로 기존 구성을 잃지 않은 채 특정 채널의 수신만 잠시 멈추고 싶을 때 유용하며, 나중에 `PATCH` 요청으로 다시 활성화할 수 있습니다.

## 업그레이드 전에는 매번 백업

Helm 롤백을 실행하더라도 이미 적용된 데이터베이스 마이그레이션까지 되돌려지지는 않습니다. 따라서 업그레이드 전에는 매번 제어 플레인 PostgreSQL 데이터베이스와 전용 `BASE_DB_URLS` 샤드 데이터베이스들을 `pg_dump`로 백업하고, 배포 부트스트랩 시크릿(`ANKOLE_SECRET_BASE`, `RELEASE_COOKIE`, `ANKOLE_FUNCTION_RUNTIME_TOKEN`)도 함께 챙겨 두세요. 업그레이드 직전의 이 짧은 백업 하나가 깔끔한 복구로 끝날지, 하루 종일 복구 작업에 매달릴지를 가릅니다. 구체적인 명령은 [Backup and restore](../backup-and-restore/)를 참조하세요.

## 올바른 영구 문서 조정

Agent의 담당 역할과 업무 범위가 모호하면 `MISSION.md`를 다듬고, 말투나 판단 방식이 어긋나면 `SOUL.md`를 수정하세요. 생성하는 웹 페이지, 슬라이드, 문서, 차트에 일관된 시각 스타일을 입히고 싶다면 `DESIGN.md`를 편집하면 됩니다. 세 문서는 각기 다른 관심사를 담당하므로 디자인 가이드 파일에 행동 수칙을 섞어 적지 마세요.

## DingTalk 에이전트당 로봇 하나

DingTalk 연동에는 에이전트당 활성 바인딩 하나, 그리고 `clientId`당 에이전트 하나라는 엄격한 제약이 적용됩니다. 에이전트 수를 늘릴 때는 에이전트마다 전용 로봇을 하나씩 따로 준비하세요. 같은 에이전트에 두 번째 DingTalk 바인딩을 추가하면 `dingtalk_binding_already_exists` 오류가 나고, 다른 에이전트에 이미 연결된 `clientId`를 재사용하면 `dingtalk_app_already_bound` 오류가 반환됩니다. 자세한 설정 방법은 [Quickstart](../quickstart/#chat-channels)를 참조하세요.

## Teams는 항상 공개 엔드포인트 필요

Microsoft Teams는 아웃바운드 장기 연결 대신 Bot Framework의 인바운드 웹훅 호출로 메시지를 전달합니다. 따라서 Teams 봇이 갑자기 응답하지 않을 때 가장 먼저 점검할 곳은 공개 HTTPS 엔드포인트입니다. TLS 인증서 만료, DNS 레코드 변경, 인그레스 순단 모두 겉으로는 “봇이 대답을 멈췄다”는 증상으로 나타납니다. 장기 연결을 쓰는 Lark, Slack, DingTalk은 짧은 인그레스 장애에도 영향받지 않지만 Teams는 즉시 영향을 받습니다.

## 다음 단계

- Console API 전체 경로는 [Console API reference](../console-api/)를 참조하세요.
- 배포 환경 변수 목록은 [Environment variables](../environment-variables/)를 참조하세요.
- 로컬 개발용 `kit` 명령어는 [kit CLI reference](../kit-cli/)를 참조하세요.
