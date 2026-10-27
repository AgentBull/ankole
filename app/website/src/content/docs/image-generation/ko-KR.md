---
title: Image generation(이미지 생성)
description: Agent용 이미지 모델을 선택하고 chat에서 이미지를 생성하거나 편집하는 방법을 설명합니다.
section: User guide
order: 24
---

Agent가 일러스트레이션, 컨셉 아트, 시각적 초안을 만들어야 할 때 이미지 생성 기능을 활성화하세요. 사용자는 원래 채팅방에서 그대로 요청하면 되며, Agent는 생성된 이미지를 첨부 파일로 반환합니다. 선택한 모델이 참조 이미지(reference image) 입력을 지원하면 기존 이미지를 불러와 편집할 수도 있습니다.

## 실행 경로 선택

공개 `image_generation` 도구는 다음 두 가지 경로 중 하나로 실행됩니다.

- **Hosted:** Agent의 `image_generate` 프로필을 구성하는 방식입니다. AIGateway가 별도로 지정된 Provider와 모델로 도구를 실행한 뒤, 그 결과를 메인 모델에 반환합니다.
- **Native:** `image_generate` 프로필을 비워 두고 네이티브 이미지 생성을 지원하는 메인 Provider를 그대로 사용하는 방식입니다. OpenAI와 ChatGPT Subscription이 이 경로를 지원하며, AIGateway는 공개 도구를 해당 메인 Provider로 바로 전달합니다.

즉, `image_generate` 프로필은 기능 활성화 스위치가 아니라 실행 경로를 결정하는 라우팅 스위치입니다. 이 프로필이 비어 있는데 메인 Provider도 네이티브 이미지 생성을 지원하지 않으면, AIGateway는 명확한 구성 오류를 반환하며 도구 호출을 거부합니다.

Hosted 경로를 설정하는 절차는 다음과 같습니다.

1. Console의 **LLM Providers**에서 원하는 이미지 모델을 지원하는 Provider를 추가합니다.
2. **Agents**를 열고 대상 Agent를 선택합니다.
3. 모델 프로필에서 `image_generate`를 찾습니다.
4. 이미지용 Provider와 모델을 선택한 뒤 프로필을 저장합니다.
5. 채팅으로 돌아가 구체적인 이미지 생성 요청을 보냅니다.

일반 모델 토큰 사용량은 메인 Provider 자격 증명에 기록되며, 이미지 토큰 사용량은 풀 순환(pool rotation)이 일어난 뒤에도 실제로 이미지를 생성한 자격 증명에 귀속됩니다.

## 짧은 시각적 브리프 작성

요청문을 길게 작성할 필요는 없습니다. 이미지를 어디에 쓸지, 무엇이 담겨야 하는지, 임의로 변형하면 안 되는 요소가 무엇인지만 분명하게 알려 주면 됩니다. 먼저 목적과 주제를 제시하고, 결과물에 영향을 미치는 구도·시각 스타일·제약 조건만 덧붙이세요.

필요에 따라 다음 다섯 가지 항목을 활용하면 효과적입니다.

- **용도와 캔버스:** 웹사이트 배너, 프레젠테이션, 소셜 포스트 등 사용처를 밝히고 가로형(landscape), 세로형(portrait), 정사각형(square) 또는 정확한 화면 비율을 지정합니다.
- **주제와 장면:** 중심 피사체와 주변 배경, 동작을 설명합니다.
- **구도와 시각 언어:** 꼭 지켜야 할 시점, 배치, 여백(negative space), 재질, 조명, 표현 매체만 지정합니다.
- **이미지 속 텍스트:** 넣어야 할 정확한 문구를 따옴표로 감싸고 배치할 위치를 명시합니다. 긴 문구는 가급적 이미지 바깥에 배치하는 편이 좋습니다.
- **제약:** 들어가면 안 되는 텍스트, 워터마크, 로고, 객체를 명시합니다. 참조 이미지를 함께 줄 때는 유지해야 할 요소도 함께 적어 주세요.

예시는 다음과 같습니다.

```text
Use: A 16:9 hero image for a product announcement. The page title will be on the left.
Subject: A white device on a dark blue table, placed on the right.
Composition: Simple geometry, soft side light, and a large open area on the left.
Text: Include only "ANKOLE 2.0" in the bottom-right corner.
Constraints: No people, watermarks, other brand marks, or extra text.
```

텍스트 렌더링 품질, 지원 해상도, 참조 이미지 처리 여부는 모델마다 다르므로 선택한 모델과 해당 Provider의 문서를 함께 확인하세요.

## 같은 chat에서 이미지 다듬기

첫 시도에서 바로 완성본이 나오는 경우는 드뭅니다. 먼저 한 가지 방향으로 초안을 만든 뒤 같은 채팅에서 세부 사항을 조금씩 다듬어 나가세요. 한 턴마다 한 가지 문제나 서로 관련된 수정 사항만 요청하면 결과를 통제하기 쉽고 이미지 전체가 새로 그려지는 일도 줄일 수 있습니다.

기존 이미지를 편집할 때는 바꿀 부분과 그대로 유지할 부분을 함께 밝혀 주세요. 예를 들면 다음과 같습니다.

```text
Change only the background to light gray. Keep the subject, composition,
lighting, text position, and colors unchanged.
```

참조 이미지를 두 장 이상 첨부할 때는 각각 “Image 1”, “Image 2”처럼 이름을 붙이고 역할을 구분해 주는 것이 좋습니다(예: 피사체는 Image 1을 따르고 색감은 Image 2를 적용). 물론 선택한 모델이 참조 이미지나 이미지 편집을 지원할 때만 이 방식이 동작합니다.

## 이미지가 나타나지 않는 경우

- **Agent가 텍스트만 반환함:** 클라이언트나 Agent에 `image_generation` 도구가 노출되어 있는지 확인하세요. 이어서 `image_generate` 프로필이 구성되어 있거나 메인 Provider가 네이티브 이미지 생성을 지원하는지 점검합니다.
- **선택 가능한 모델이 없음:** 현재 등록된 LLM Providers 중에 이미지 생성 모델을 제공하는 곳이 없는 상태입니다. 해당 기능을 지원하는 Provider를 추가하세요.
- **지원되지 않는 요청 오류:** 호환되는 다른 모델을 선택하거나, 현재 모델이 지원하지 않는 해상도·포맷·투명 배경·참조 이미지·편집 조건을 요청에서 제외하세요.
- **이미지는 생성되지만 내용이 의도와 다름:** 대개 설정 문제가 아닙니다. 같은 채팅에서 이어서 대화하며 무엇을 수정하고 무엇을 그대로 둘지 구체적으로 지정하세요.
- **생성은 성공했지만 채팅에 첨부 파일이 보이지 않음:** 연결된 Channel Provider가 파일을 정상적으로 업로드할 수 있는지 확인하고 해당 대화의 오류 기록을 점검하세요.

지원되는 이미지 크기, 파일 형식, 투명 배경, 참조 이미지 및 편집 범위는 선택한 모델과 Provider에 따라 달라집니다.
