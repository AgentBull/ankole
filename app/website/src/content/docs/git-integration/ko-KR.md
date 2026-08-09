---
title: Git 통합
description: Ankole Agent가 일반 대화 또는 Background Agent Job에서 git을 사용하는 방법.
section: Guides
order: 303
---

Ankole Agent는 Worker가 제공하는 셸 도구를 통해 표준 git 명령을 사용합니다. 같은 도구가 일반 대화와 Background Agent Job에서 모두 사용 가능합니다.

가장 중요한 특성을 먼저 말하면: Agent는 git을 Worker의 **sandbox 안에서**, `/agents/<key>/` 파일시스템을 대상으로 실행합니다. 특별한 git 통합 레이어는 없습니다 — 다른 모든 작업에 사용하는 것과 같은 셸 도구를 사용하며, 파일시스템이 곧 워크스페이스입니다. `design-md` skill과 페르소나가 관례를 담고, 도구가 실행을 담당합니다.

## Agent가 git으로 할 수 있는 일

`command` 도구를 통해 Agent는 sandbox가 허용하는 모든 git 명령을 실행합니다:

```bash
git clone https://github.com/your-org/your-repo.git
git checkout -b feature/agent-fix
git add -A && git commit -m "Fix: resolve the null-pointer case"
git push origin feature/agent-fix
```

Agent는 워크스페이스(`/agents/<key>/jobs/<job-id>/` 또는 `sessions/<id>/` 아래)에 clone하고, 파일 편집 및 patch 도구로 변경하며, 커밋하고, push합니다 — 모두 셸을 통해, 모두 bubblewrap 격리 아래에서 이루어집니다.

일반 대화 중에 Agent는 포그라운드 셸과 파일 도구를 사용합니다. 작업을 Background Agent Job에 위임하면, Job은 자체 워크스페이스에서 실행되고 결과를 반환하거나 조용히 끝날 수 있습니다. 이 워크플로는 [Background Agent Jobs](../background-jobs/)를 참조하세요.

## 필요한 것

- **Git 자격 증명.** **Console → Environment variables**에서 SSH 키 또는 PAT를 `GIT_SSH_KEY`나 `GIT_TOKEN` 같은 암호화 변수로 저장하세요. 새 값은 Agent의 다음 턴부터 사용할 수 있습니다. [Environment variables](../worker-env/)를 참조하세요.
- **Worker에서 접근 가능한 저장소.** Worker는 git 호스트에 네트워크로 접근할 수 있어야 합니다. 프라이빗 네트워크에서는 Worker가 git 서버에 도달할 수 있는지 확인하세요.
- **필요할 때의 Background Agent Jobs 모델 프로필.** 기본 fallback으로 시작하기에 충분합니다. Job이 다른 provider나 모델을 필요로 할 때만 이 프로필을 구성하세요.

## 워크스페이스

Git 저장소는 세션별 또는 job별 워크스페이스에 clone됩니다:

```text
/agents/<agent-key>/
└── jobs/<job-id>/
    └── your-repo/       # cloned here
        ├── .git/
        └── ...           # the working tree
```

워크스페이스는 Agent Home 볼륨에 지속되므로, Worker가 재시작되어도 clone은 유실되지 않습니다. 레이아웃은 [File management](../file-management/)를 참조하세요.

## 작업 예시

PR을 리뷰하는 코딩 Agent를 설정해 봅니다:

1. **Console → Environment variables**에서 PAT를 `GIT_TOKEN`이라는 암호화 변수로 저장합니다.
2. Agent를 생성하고 필요한 `primary`, `light`, `heavy` 프로필을 바인딩합니다. fallback을 덮어써야 할 때만 Background Agent Jobs를 별도로 구성합니다.
3. 저장소 이름, 리뷰 기준, 브랜치 명명 관례를 담은 `MISSION.md`를 작성합니다.
4. 채널에서 Agent에게 말합니다: "Review the latest PR on `your-repo`. Clone, check out, run the tests, report what you find."
5. Agent는 clone하고, checkout하며, `command`로 테스트를 실행하고, 결과를 보고합니다. 이것은 대화에서 하거나 Background Agent Job에 위임할 수 있습니다.

## 이 가이드가 아닌 것

git 튜토리얼이 아닙니다 — Agent는 표준 git 명령을 사용합니다. CI/CD 통합도 아닙니다 — Ankole은 CI를 실행하지 않습니다. 저장소의 CI가 명령 기반이라면 Agent는 셸 명령으로 CI를 트리거할 수 있습니다. 코드 리뷰 자동화 가이드도 아닙니다 — Agent는 페르소나가 지시하는 방식대로 셸 도구를 통해 코드를 리뷰합니다.

## 다음 단계

- 셸 도구는 [Code execution](../code-execution/)을 읽으세요.
- 백그라운드 실행은 [Background Agent Jobs](../background-jobs/)를 읽으세요.
- Git 자격 증명은 [Environment variables](../worker-env/)를 읽으세요.
- 파일시스템 레이아웃은 [File management](../file-management/)를 읽으세요.