---
title: PDF 생성
description: PDF 파일을 만들고, 확인하고, 편집하는 agent를 설정하는 방법 — pdf skill, 사용하는 도구, 작업 예시.
section: Guides
order: 306
---

PDF 생성은 흔한 산출물입니다 — 보고서, 제안서, PDF로 제공해야 하는 형식화된 문서. Ankole의 `pdf` skill은 Worker에 설치된 PDF 도구 체인(Pandoc, 두 개의 PDF 엔진, Poppler, QPDF)으로 이 작업을 처리하고 백그라운드 job으로 실행됩니다. 이 가이드는 PDF 생성 agent의 실용적인 형태입니다.

가장 중요한 특성을 먼저 말하면: `pdf` skill은 **모델 기능이 아닌 파일시스템·도구 skill**입니다. agent는 셸 도구로 Pandoc과 PDF 엔진을 실행하며, skill의 `SKILL.md`가 방법을 알려 줍니다. `generate_pdf` API 호출 같은 것은 없습니다 — skill이 안내하는 셸을 통한 문서 준비입니다.

## 필요한 것

- **활성화된 `pdf` skill.** `default_enabled: true`이므로 덮어쓰지 않는 한 모든 agent에서 켜져 있습니다. [Skills](../skills/)를 참조하세요.
- **Worker 이미지.** Agent Computer Worker 이미지에는 Pandoc, 두 개의 PDF 엔진(Typst, LaTeX), Poppler, QPDF가 설치되어 있습니다. 이미지의 일부이므로 직접 설치하지 않습니다.
- **바인딩된 `primary` 모델 프로필.** agent가 소스 콘텐츠(Markdown 또는 문서 구조)를 작성하면 skill의 도구가 이를 PDF로 렌더링합니다.

## skill이 하는 일

`pdf` skill의 `SKILL.md`는 세 가지 작업을 다룹니다:

- **Create** — 소스 콘텐츠(보통 Markdown)를 작성하고 Pandoc과 PDF 엔진을 통해 PDF로 렌더링합니다. skill이 엔진 선택, 폰트 설정, 출력 경로를 알고 있습니다.
- **Check** — Poppler와 QPDF를 사용해 생성된 PDF(페이지 수, 텍스트 추출, 폰트 임베딩)를 검증합니다. 배포 전에 PDF가 유효한지 확인하는 데 사용하세요.
- **Edit** — 문서 전체를 다시 생성하지 않고 기존 PDF에 텍스트 수정을 적용합니다.

skill은 백그라운드 job(`ankole-runtime: background_job`)으로 실행되므로, 긴 PDF 렌더링이 대화를 막지 않습니다.

## 작업 예시

주간 보고서를 PDF로 만드는 agent를 설정해 봅니다:

1. `pdf` skill이 활성화되어 있는지 확인합니다(기본적으로 켜져 있습니다).
2. agent를 만들고 `MISSION.md`를 작성합니다: "Produce a weekly status report as a PDF. Gather the week's metrics from the channel history, write the report in Markdown, render to PDF with Typst, verify with Poppler, and post the PDF to the channel."
3. 주간 [스케줄](../schedules/)을 추가합니다.
4. 실행마다 agent가 컨텍스트를 모으고, Markdown을 작성하고, 셸을 통해 `pdf` skill의 도구를 호출하고, 출력을 검증하고, 파일을 게시합니다.

## `design-md` 동반 skill

PDF에 시각적 완성도(브랜드 팔레트, 특정 레이아웃)가 필요하면 `pdf` skill을 `design-md` skill과 짝지으세요. `pdf` skill의 `SKILL.md`는 이렇게 말합니다: "If the human has already provided a brand palette or template, match that first. Otherwise, use `design-md` skills and use it as the design reference."

## 이 가이드가 아닌 것

Pandoc이나 Typst 튜토리얼이 아닙니다 — skill이 도구 호출을 알고 있으며, 운영자의 역할은 작업 범위를 정하는 것입니다. 레이아웃 디자인 가이드도 아닙니다 — 시각적 결정은 `design-md` skill을 사용하세요. 그리고 `pdf` skill의 `SKILL.md` 읽기를 대체하지도 않습니다 — 그 파일이 도구 명령의 권위 있는 참조입니다.

## 다음 단계

- skill 시스템은 [Skills](../skills/)와 [Writing a skill](../writing-a-skill/)을 읽으세요.
- skill이 사용하는 셸 도구는 [Code execution](../code-execution/)을 읽으세요.
- 백그라운드 job은 [Background jobs](../background-jobs/)를 읽으세요.
- 스케줄링은 [Schedules](../schedules/)를 읽으세요.