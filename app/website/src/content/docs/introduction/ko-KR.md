---
title: 소개
description: Ankole 디지털 본사, Agent Harness, Meta Ankole Company Brain이 제공하는 기능과 프라이빗 배포 인스턴스의 작동 방식을 설명합니다.
section: Getting started
order: 1
---

**Ankole은 Meta Ankole의 Company Brain을 중심으로 설계된 오픈 소스 디지털 본사이자 엔터프라이즈 Agent Harness입니다. 협업용 Pod 워크스페이스를 개인 비서 및 전문 AI 동료와 결합하여, Agent가 근거를 제시하며 지속적인 실무를 수행하는 데 필요한 컨텍스트, 권한, 도구, 피드백 루프를 제공합니다.**

프라이빗 배포 인스턴스 안에서 구성원과 Agent는 Pod Docs, 샤딩된 Base, React + TypeScript Applet, Pod Chat, 외부 메신저를 넘나들며 협업하고, 공유 지식·통합 Connectors·Function Runtime·전용 Agent Computer Worker가 이를 뒷받침합니다.

단독 언어 모델은 전달받은 프롬프트 안에서만 추론할 수 있지만, Ankole은 최신 사내 사실 조합, 런타임 Principal·Drive 권한 검증, 격리된 컨텍스트 간 위임, 프로세스 장애 후 작업 복구, 그리고 교정 내용과 실제 결과의 후속 업무 반영까지 일관되게 처리합니다.

## Ankole이 제공하는 기능

- **Pod 디지털 본사:** 계층형 Docs 공동 편집, 물리 샤드에 저장되는 Base 테이블, 무모델(zero-LLM) 게시형 Applet Action을 갖춘 React + TypeScript Applet, 멀티플레이어 Pod Chat을 제공하며 Slack, Microsoft Teams, Lark/Feishu, DingTalk, WeCom과도 연동됩니다.
- **개인 비서와 AI 동료:** 모든 내부 멤버에게는 본인의 협업 권한 범위로 동작하는 1:1 **개인 비서**가 배정되며, 전문 **AI 동료**는 고유 Principal 권한, Action Card 승인, 격리된 Peer A2A 위임(`send_to_agent`)을 통해 협업합니다.
- **Meta Ankole(`Brain`, `Skills`, 계약):** 출처·Claim·시점·신뢰도·상충 여부·공개 범위를 추적하는 **Brain** 온톨로지 그래프와 공유 **Skills**, 조합·상속 가능한 `AGENTS.md` 및 `DESIGN.md` 행동·디자인 계약을 하나로 통합합니다.
- **통합 Connectors 및 MCP 게이트웨이:** `Ankole.Connectors`가 테넌트 공유 앱 자격 증명, 멤버 개인 OAuth 연동(`/connectors`), Lark/Feishu·GitHub·Linear 및 원격 MCP 서버용 컨트롤 플레인 MCP 게이트웨이를 관리하여 원본 시크릿이 Worker나 Applet 격리 환경으로 유출되지 않게 보호합니다.
- **이벤트 기반 실행 및 장애 복구:** 채팅 메시지, 정기 일정, Webhook, Connector 트리거가 Session, Background Agent Job, 결정론적 Applet Action을 깨우며, 프로세스 재시작 후에도 PostgreSQL 상태에서 그대로 복구됩니다.
- **지속적인 학습 루프:** Dreaming이 실제 Job 실행 궤적에서 7일 임대 방식의 Skill 주의사항(교훈)을 자동으로 활성화하고 예측을 실제 결과와 대조해 채점하며, 사람은 영구 주의사항과 공유 Skill을 관리합니다.

## 배포 인스턴스의 구성 요소

문서 전반에서 사용하는 핵심 개념은 다음과 같습니다.

| 구성 요소 | 설명 | 더 보기 |
|---|---|---|
| **Pod** | 사람과 Agent가 함께 일하는 디지털 본사로, 계층형 Docs, 물리 샤딩된 Base 테이블, React + TypeScript Applet(게시된 Applet Action 포함), 통합 Drive, 멀티플레이어 Pod Chat을 제공합니다. | [아키텍처 개요](../architecture/) |
| **개인 비서 및 AI 동료** | 두 가지 Agent 역할입니다. 멤버마다 1:1로 배정되어 소유자의 협업 권한을 투영하는 **개인 비서**와, 고유 Principal 권한으로 동작하며 격리된 Peer A2A(`send_to_agent`)로 협업하는 전문 **AI 동료**로 나뉩니다. | [Agents](../agents/) |
| **Meta Ankole(`Brain`, `Skills`, 계약)** | 출처가 기록된 **Brain** 온톨로지 그래프, 재사용 가능한 **Skills**(Agent별 임대형 교훈 포함), 조합형 `AGENTS.md` / `DESIGN.md` 계약을 아우르는 조직 지식 계층입니다. | [Brain](../brain/), [Skills](../skills/), [Agent Library](../agent-library/) |
| **통합 Connectors** | 테넌트 애플리케이션 연결(`authConfigId`), 개인 OAuth(`/connectors`), 외부 이벤트 구독, 그리고 Lark·GitHub·Linear 등의 Toolkit을 Worker와 Function Runtime에 제공하는 컨트롤 플레인 MCP 게이트웨이입니다. | [MCP 사용하기](../using-mcp/) |
| **Principal** | 사람, Agent, 내부 `system` 서비스(`system`, `ankole_brain`)를 나타내는 `(tenant_id, uid)` 책임 주체입니다. `Ankole.AuthZ`가 런타임에 모든 권한 검사와 감사 기록을 Principal 기준으로 수행합니다. | [Principal and AuthZ](../principal-authz/) |
| **Session** | 대화 또는 Peer A2A 교환 내 Agent 실행 단위로, 컨텍스트, 실행 중 방향 조정, 취소, 콜드 웨이크 회전, 장애 복구를 담당합니다. | [Sessions](../sessions/) |
| **Signal routing rule** | 외부 메신저 채널, Webhook, 일정, Base/Applet 이벤트, Connector 트리거를 대상 Agent Session이나 게시된 Applet Action으로 연결하는 규칙입니다. | [Signal routing rules](../signal-bindings/) |
| **Background Agent Job** | 전용 Worker에서 수 시간 동안 비동기로 실행되는 영속적 Codex 작업으로, 중간 확인 질문이나 최종 결과물을 원래 대화로 전달합니다. | [Background Agent Jobs](../background-agent-jobs/) |
| **Function Runtime** | 무상태 `ankole-function-runtime` 서비스로, 격리된 TypeScript 런타임에서 Pod Applet 백엔드, 게시된 무모델 Applet Action([Automation Jobs](../automation-jobs/)), PTC, Workflow를 실행하고 컨트롤 플레인 MCP 호스트와 연결됩니다. | [아키텍처 개요](../architecture/) |
| **Agent Computer Worker** | 각 Agent 전용 컴퓨팅 환경으로, 셸 도구, 헤드리스 브라우저, Codex Job, MCPorter, Git 자격 증명 도우미, 영속 `/workspace` Home, 그리고 통합 Drive·Brain·Skills·계약을 마운트하는 `/drive` FUSE를 제공합니다. | [Agent Computer Worker](../agent-computer-worker/) |

또한 여러 출처를 장시간 조사할 때는 [Deep Research](../deep-research-job/)를, 실제 웹 페이지를 조작할 때는 [브라우저 자동화](../browser-automation/)를 활용할 수 있습니다.

## 지원하는 의사결정 및 운영 업무

Ankole은 검증 가능한 근거와 결과물이 요구되는 핵심 디지털 업무를 위해 설계되었습니다. 경쟁 가설을 교차 검증하는 산업 리서치, 시나리오 모델 기반의 제품·시장 평가, 재현 가능한 데이터 분석은 물론 Pod Base, Applet, GitHub, Linear, 기업 메신저를 가로지르는 상시 운영 업무를 지원합니다.

과제 성격에 따라 멤버의 개인 비서가 본인 권한으로 직접 처리하거나, Peer A2A(`send_to_agent`)로 전문 AI 동료에게 위임하거나, [Workflow](../workflows/)로 여러 격리된 서브에이전트 컨텍스트에 분산해 상관 오류를 줄이거나, 무모델 Applet Action으로 결정론적 동기화·점검을 자동화할 수 있습니다. 모든 실행 과정에서 Meta Ankole과 수신 Signal이 최신 맥락을 공급하고, Principal과 AuthZ가 실행 경계를 통제하며, 관측된 결과가 다음 판단으로 이어집니다.

## 현재 상태

Ankole은 프로덕션 환경에서 운영되는 완결형 엔터프라이즈 디지털 본사 및 Agent Harness입니다. Elixir 컨트롤 플레인, Pod 워크스페이스, Function Runtime(`ankole-function-runtime`), Agent Computer Worker, Rust 커널, Meta Ankole, 통합 Connectors, 운영자용 Console을 자체 인프라에 직접 호스팅할 수 있습니다. 핵심 코드 경로와 상태 머신은 정형 검증으로 확인하며, 메시지 라우팅·Drive ACL·장애 복구·동시성·업그레이드를 포괄하는 엔드투엔드 테스트를 상시 수행합니다.

Ankole은 공개 API의 하위 호환성을 보장하지 않으므로 릴리스에 호환되지 않는 변경이 포함될 수 있습니다.

## 다음 단계

인스턴스를 직접 실행해 보려면 [빠른 시작](../quickstart/)을 따라 진행하고, 구성 요소 간 경계와 흐름은 [아키텍처 개요](../architecture/)에서 확인하세요.
