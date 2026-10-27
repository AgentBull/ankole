---
title: PDF 생성
description: PDF 파일을 만들고, 확인하고, 편집하는 agent를 설정하는 방법 — pdf skill, 사용하는 도구, 작업 예시.
section: Guides
order: 306
---

보고서, 제안서, 정식 배포용 문서 등 PDF 파일을 산출물로 만들어야 하는 경우는 매우 흔합니다. Ankole의 `pdf` skill은 Worker에 설치된 PDF 도구 체인(Pandoc, 두 가지 PDF 엔진, Poppler, QPDF)을 활용해 백그라운드 Job에서 문서를 생성하고 검증합니다. 이 가이드에서는 PDF를 다루는 Agent를 실무에 맞게 설정하는 방법을 살펴봅니다.

먼저 알아 둘 점은 `pdf` skill이 **모델 내장 기능이 아니라 파일시스템 및 CLI 도구 기반의 skill**이라는 것입니다. 별도의 `generate_pdf` API 호출이 존재하는 것이 아니라, Agent가 `SKILL.md`의 안내에 따라 셸 도구로 Pandoc과 PDF 엔진을 직접 실행해 문서를 조판합니다.

## 필요한 것

- **활성화된 `pdf` skill.** 기본값이 `default_enabled: true`이므로 별도로 재정의하지 않는 한 모든 Agent에서 켜져 있습니다. 자세한 내용은 [Skills](../skills/)를 참조하세요.
- **Worker 이미지.** Agent Computer Worker 이미지에는 Pandoc, 두 가지 PDF 엔진(Typst, LaTeX), Poppler, QPDF가 기본 설치되어 있으므로 별도로 설치할 필요가 없습니다.
- **바인딩된 `primary` 모델 프로필.** Agent가 원본 콘텐츠(Markdown 또는 문서 구조)를 작성하면, 이후 도구 체인으로 PDF 렌더링을 수행합니다.

## skill이 하는 일

`pdf` skill의 `SKILL.md`는 다음 세 가지 작업을 안내합니다.

- **Create**: 원본 콘텐츠(주로 Markdown)를 작성하고 Pandoc과 PDF 엔진으로 렌더링합니다. 엔진 선택 기준, 글꼴 설정, 출력 경로 규칙이 모두 지침에 정의되어 있습니다.
- **Check**: Poppler와 QPDF로 생성된 PDF의 페이지 수, 텍스트 추출 상태, 글꼴 임베딩 여부를 검사합니다. 문서를 외부에 전달하기 전에 이상이 없는지 확인할 때 유용합니다.
- **Edit**: 문서 전체를 처음부터 다시 생성하지 않고 기존 PDF에 텍스트 수정을 반영합니다.

이 skill은 백그라운드 Job(`ankole-runtime: background_job`)에서 실행되므로, 렌더링 시간이 길어지더라도 진행 중인 채팅 대화가 가로막히지 않습니다.

## 작업 예시

매주 상태 보고서를 PDF로 만들어 공유하는 Agent를 설정하는 절차는 다음과 같습니다.

1. `pdf` skill이 활성화되어 있는지 확인합니다(기본 활성화).
2. Agent를 생성하고 `MISSION.md`에 `"Produce a weekly status report as a PDF. Gather the week's metrics from the channel history, write the report in Markdown, render to PDF with Typst, verify with Poppler, and post the PDF to the channel."`을 작성합니다.
3. 주간 [스케줄](../schedules/)을 등록합니다.
4. 스케줄이 실행될 때마다 Agent가 채널 기록에서 컨텍스트를 모아 Markdown 초안을 작성하고, 셸을 통해 `pdf` skill의 도구로 렌더링과 검증을 마친 뒤 완성된 PDF를 채널에 게시합니다.

## `design-md` 동반 skill

브랜드 색상 팔레트나 정돈된 레이아웃처럼 시각적 완성도가 중요할 때는 `pdf` skill과 `design-md` skill을 함께 활성화하세요. `pdf` skill의 `SKILL.md`에서도 사용자가 브랜드 팔레트나 템플릿을 직접 제공한 경우 이를 우선 따르고, 그렇지 않으면 `design-md` skill을 디자인 기준으로 삼도록 안내합니다("If the human has already provided a brand palette or template, match that first. Otherwise, use `design-md` skills and use it as the design reference.").

## 이 가이드가 아닌 것

이 문서는 Pandoc이나 Typst 문법 튜토리얼이 아닙니다. 구체적인 명령어 조합은 skill에 이미 정리되어 있으며, 운영자는 Agent가 수행할 작업 범위만 명확히 잡아 주면 됩니다. 또한 시각 디자인 자체를 다루는 가이드도 아니므로 레이아웃이나 스타일 기준은 `design-md` skill에 맡기세요. 정확한 도구 호출 명세는 `pdf` skill의 `SKILL.md`가 기준이므로 세부 규칙은 해당 파일을 직접 참고하세요.

## 다음 단계

- Skill 시스템 전반은 [Skills](../skills/)와 [Writing a skill](../writing-a-skill/)을 참조하세요.
- Skill이 사용하는 셸 도구는 [Code execution](../code-execution/)을 참조하세요.
- 백그라운드 Job 구조는 [Background jobs](../background-jobs/)를 참조하세요.
- 정기 실행 설정은 [Schedules](../schedules/)를 참조하세요.