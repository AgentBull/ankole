---
title: Git 통합
description: Ankole Agent가 일반 대화 또는 Background Agent Job에서 git을 사용하는 방법.
section: Guides
order: 303
---

Ankole Agent는 전용 Worker가 제공하는 표준 셸과 파일 도구로 영구 `/workspace` 디렉터리 안의 git 저장소를 다룹니다. 일반 대화와 Background Agent Job 모두에서 동일한 도구를 사용할 수 있으며, Worker 인스턴스나 이미지를 교체하더라도 `/workspace`의 저장소는 그대로 유지됩니다.

## Agent가 git으로 할 수 있는 일

Agent는 `command` 도구를 사용해 Worker의 사용자 계정으로 git 명령을 실행합니다.

```bash
git clone https://github.com/your-org/your-repo.git
git checkout -b feature/agent-fix
git add -A && git commit -m "Fix: resolve the null-pointer case"
git push origin feature/agent-fix
```

워크스페이스(`/workspace/jobs/<job-id>/` 또는 `sessions/<id>/` 하위)에 저장소를 clone한 뒤 파일 편집 및 패치 도구로 코드를 수정하고, 커밋과 push까지 수행할 수 있습니다. 이 모든 과정은 셸을 통해 Worker의 사용자 권한으로 실행됩니다.

일반 대화에서는 포그라운드 셸과 파일 도구를 바로 사용합니다. 반면 작업을 Background Agent Job에 위임하면 해당 Job이 독립된 워크스페이스에서 작업을 수행한 뒤 결과를 반환하거나 조용히 종료합니다. 자세한 위임 흐름은 [Background Agent Jobs](../background-jobs/)를 참조하세요.

## 필요한 것

- **Git 자격 증명.** **Console → Environment variables**에서 SSH 키나 PAT를 `GIT_SSH_KEY`, `GIT_TOKEN` 같은 암호화 변수로 저장하세요. 저장한 값은 Agent의 다음 턴부터 적용됩니다. 자세한 내용은 [Environment variables](../worker-env/)를 참조하세요.
- **Worker에서 접근 가능한 저장소.** Worker에서 git 호스트로 네트워크 연결이 가능해야 하므로, 사설 네트워크 환경이라면 Worker가 대상 git 서버에 접근할 수 있는지 확인하세요. Docker Compose 배포에서는 Worker 컨테이너가 `ankole_workers` 네트워크에 연결되어 control plane, 인터넷, 공개 git 호스트와 통신할 수 있습니다. Helm 차트에서 `networkPolicy.enabled`를 켜면 Worker Pod는 control plane, DNS, 공개 주소로 나갈 수 있지만, 사설 대역이 `networkPolicy.workerDeniedCIDRs`에 포함되어 있으면 해당 대역의 git 서버에는 연결할 수 없습니다.
- **Background Agent Jobs 모델 프로필(선택 사항).** 기본적으로는 기본 fallback 설정만으로 충분합니다. Job에서 별도의 Provider나 모델을 써야 할 때만 이 프로필을 따로 구성하세요.

## 워크스페이스

Git 저장소는 세션별 또는 Job별 워크스페이스 아래에 clone됩니다.

```text
/workspace/
└── jobs/<job-id>/
    └── your-repo/       # cloned here
        ├── .git/
        └── ...           # the working tree
```

`/workspace` 안의 저장소는 Worker가 교체되거나 이미지가 바뀌어도 유지되지만, 스토리지 유실에 대비해 원격 저장소에 push하거나 별도 백업을 두는 것이 안전합니다. 작업 산출물을 [Agent 드라이브](../file-management/)에 게시할 때는 `ankole-files put`을 사용합니다.

## 작업 예시

PR을 리뷰하는 코딩 Agent를 설정하는 절차는 다음과 같습니다.

1. **Console → Environment variables**에서 PAT를 `GIT_TOKEN` 암호화 변수로 저장합니다.
2. Agent를 생성하고 필요한 `primary`, `light`, `heavy` 프로필을 바인딩합니다. 기본 fallback 대신 별도 모델을 지정해야 할 때만 Background Agent Jobs 프로필을 추가로 구성합니다.
3. 저장소 이름, 리뷰 기준, 브랜치 명명 규칙을 담아 `MISSION.md`를 작성합니다.
4. 채널에서 Agent에게 "Review the latest PR on `your-repo`. Clone, check out, run the tests, report what you find."라고 요청합니다.
5. 요청을 받은 Agent는 저장소를 clone해 브랜치를 checkout하고 `command` 도구로 테스트를 실행한 뒤 결과를 보고합니다. 이 작업은 대화 중 직접 처리할 수도 있고 Background Agent Job에 위임할 수도 있습니다.

## 이 가이드가 아닌 것

이 문서는 git 명령어 사용법을 다루는 튜토리얼이 아니며, Agent는 표준 git 명령을 그대로 사용합니다. 또한 Ankole 자체에 CI/CD 실행 기능이 내장되어 있는 것은 아니지만, 저장소의 CI를 명령줄로 호출할 수 있다면 Agent가 셸 명령으로 CI를 트리거할 수는 있습니다. 별도의 코드 리뷰 전용 자동화 엔진을 설명하는 문서도 아니며, Agent는 페르소나 문서에 정의된 기준에 따라 일반 셸 도구로 코드를 검토합니다.

## 다음 단계

- 셸 도구 사용법은 [Code execution](../code-execution/)을 참조하세요.
- 백그라운드 실행 구조는 [Background Agent Jobs](../background-jobs/)를 참조하세요.
- Git 자격 증명 관리는 [Environment variables](../worker-env/)를 참조하세요.
- Agent 드라이브 사용법은 [File management](../file-management/)를 참조하세요.
