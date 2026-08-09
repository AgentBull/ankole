---
title: Worker CLI 기능
description: Agent 기능을 `--help`가 계약을 담당하는 shell 명령으로 제공하고, Agent가 관련 결정을 내리는 위치에 한 문장짜리 포인터를 배치합니다.
section: Developer guide
order: 114
---

일부 Ankole 기능은 모델에 보이는 tool이 아니라 Agent Computer의 shell 명령입니다. Agent는 `gh`나 `kubectl`처럼 shell을 통해 이 명령들을 호출합니다. Webhook 엔드포인트 명령과 automation job 명령이 이 형태를 쓴다.

이 페이지는 기능을 이 형태로 제공해야 하는 경우와, tool 등록, Skill 인덱스 항목, system prompt 섹션 없이도 발견 가능하고 올바르게 만드는 공개 아키텍처를 설명합니다.

## CLI가 올바른 형태인 경우

다음이 모두 성립할 때 기능은 CLI 형태에 맞는다:

- Agent가 더 큰 shell 워크플로 안에서 다른 명령 옆에 사용하며, 스크립트나 백그라운드 agent job도 호출할 수 있어야 한다.
- 오직 하나의 결정 경로에서만 중요합니다. webhook을 만들지 않는 Agent는 `create-webhook-cli`가 존재한다는 사실을 알 필요가 없다.
- 모델이 채울 JSON schema가 필요 없다. 몇 개의 flag가 입력을 담습니다.

모델에 보이는 tool은 매 turn에서 컨텍스트를 소비합니다. CLI는 Agent가 관련 경로를 따라가기 전까지 아무것도 소비하지 않습니다.

## 공개 아키텍처

세 가지 규칙이 tool 등록과 Skill 인덱싱을 대체합니다:

**`--help`가 계약 문서입니다.** CLI의 `--help` 출력은 Agent가 기능을 올바르게 사용하는 데 필요한 지식을 담는다: 그것이 무엇인지, 신뢰 모델, 보장, 완전한 사용이 어떻게 생겼는지. 바이너리와 함께 제공되므로 기술하는 동작과 함께 버전이 고정되며, 별도 문서처럼 어긋날 수 없다. 다른 컨텍스트가 없는 독자를 위해 쓰고, 절차가 아니라 목표와 제약을 서술하세요. `create-webhook-cli --help`가 참조 예시입니다.

**포인터는 결정 표면에 놓입니다.** 발견은 Agent가 이미 인접한 결정을 내리는 위치에 놓인 한 문장짜리 포인터에서 온다: tool description, 특정 외부 system을 통합하는 Skill, 또는 다른 CLI의 `--help`. 각 포인터는 기능이 관련된 조건과 어디에서 더 읽을 수 있는지를 서술하며 선택을 유도하지 않습니다. 이 형태의 모든 기능은 Agent가 관련 경로에서 항상 방문하는 표면에 포인터를 적어도 하나 가져야 한다 — 기능을 의미 있게 만드는 경로가 그것을 공개하는 표면도 정합니다.

**일반 지식은 `--help`에 있고, 도메인 지식은 plugin Skill에 있다.** 기능의 모든 사용에 성립하는 계약은 `--help`에 속합니다. 하나의 외부 system을 통합하는 Skill은 그 system이 더하는 것만 유지합니다. 예를 들어 GitHub webhook Skill은 일반 webhook 계약에 대해 Agent를 `create-webhook-cli --help`로 안내하는 것으로 시작하며, hook 등록, ping 검증, 전달 조정, GitHub hook 할당량만 다룹니다. 두 번째 통합은 일반 계층 전체를 공짜로 재사용합니다.

## Automation jobs

automation job은 매 전달마다 Agent 대화를 깨우는 대신 trigger를 소비하는 결정적 스크립트입니다. checkback, cron schedule, 또는 webhook endpoint가 `automation_job_id`를 지정할 수 있다. 이 필드가 없는 trigger는 직접 깨우는 동작을 유지합니다.

Agent는 Agent Home 안에 디렉터리 하나를 만들고 `main.ts`를 추가하고, 설정과 비-SDK 분기를 손으로 확인한 다음 `create-automation-job-cli`로 디렉터리를 등록합니다. Worker는 등록 시와 매 실행 시 실제 경로로 디렉터리와 엔트리포인트를 해석합니다. 현재 파일을 Bun으로 실행하므로 다시 등록하지 않아도 편집이 반영됩니다.

각 attempt는 최신 Agent WorkerEnv와, 현재 활성화된 Skill에서 생성된 호출 범위의 `MCPORTER_CONFIG`를 받습니다. Worker는 스크립트가 어떤 server를 쓸지 예측하지 않습니다. 스크립트는 mcporter와 stdin JSON으로 선택된 MCP tool 하나를 호출할 수 있다. Automation은 Skill 지침을 읽지 않으며, 영구적인 Agent Home mcporter 구성을 사용하지 않습니다.

run SDK는 `context()`와 `emitEvent(payload)`를 제공합니다. `context().event`는 직접 trigger가 ActorEvent로 추가했을 것과 같은 CloudEvents 엔벨로프입니다. 스크립트는 내보내지 않고 조용한 성공으로 끝내거나, `emitEvent`를 한 번 이상 호출하여 영구 `automation_job.emitted` 이벤트를 소유 세션에 추가할 수 있다.

`context()`와 `emitEvent`는 플랫폼 run 안에서만 존재합니다. 직접 `bun main.ts` 실행은 이 함수들을 호출하지 않는 설정과 분기를 확인할 수 있다. 등록 후에는 모든 SDK 분기에 테스트 trigger를 사용하고 그 영구 run을 검사하세요. `emitEvent`는 stdout으로 폴백하지 않는다: ActorEvent가 영구 상태가 된 뒤에만 그 promise가 resolve된다.

모든 trigger 소비는 checkback을 청구하고, cron schedule을 진행시키고, webhook을 받아들이는 것과 같은 PostgreSQL 트랜잭션 안에서 영구 run을 만듭니다. 스크립트 예외, 0이 아닌 종료, 타임아웃은 종결적인 스크립트 결과이며 재시도되지 않습니다. Worker 손실은 인프라 장애다: run은 기존 Oban wake edge를 통해 새 fenced attempt를 받습니다. 리플레이는 스크립트 부작용을 반복할 수 있으므로 스크립트는 반복이 무해하도록 만들어야 한다.

활성 Agent turn 안에서 다음 명령을 사용하라:

- `create-automation-job-cli --dir <path> --label <text> [--wake-on-failure]`
- `list-automation-jobs-cli [--limit <1-500>]`
- `show-automation-job-cli --id <automation-job-id> [--runs <1-100>]`
- `cancel-automation-job-cli --id <automation-job-id>`

Console의 Automation Jobs 페이지는 각 job과 최근 run 상태, attempt, 오류, exit code, 제한된 stdout 및 stderr 꼬리를 보여줍니다. `create-automation-job-cli --help`는 모델을 향한 규범적 안내로 남습니다.

## 새 CLI 기능의 요구 사항

- 구현을 `app/agent_computer/src/cli/` 아래에 배치하고, 명령 패밀리마다 디렉터리 하나를 쓴다.
- `--help`와 `-h`로 완전한 계약을, stdout에 exit 0으로, turn이나 네트워크 의존 없이 제공하세요. 명령 래퍼가 서브커맨드를 앞에 붙이므로 인자 목록 어디에서든 help flag를 감지하세요.
- 인자 오류에는 짧은 usage 문자열을 유지하세요. 그것은 계약 문서가 아닙니다.
- Agent가 기능을 필요로 할 각 결정 표면에 포인터 문장을 추가하고, 포인터에 선호를 담지 마라: 조건을 서술하고 `--help`를 지목하세요.
- plugin Skill이 기능을 외부 system과 통합할 때는 `--help` 포인터로 Skill을 시작하고, Skill을 도메인 델타로 유지하세요.
