---
title: Image generation(이미지 생성)
description: Agent용 이미지 모델을 선택하고 chat에서 이미지를 생성하거나 편집하는 방법을 설명합니다.
section: User guide
order: 24
---

Agent가 일러스트레이션, 컨셉 아트 또는 시각적 초안을 만들어야 할 때 image generation을 활성화하십시오. 사용자는 같은 chat에 머물며, Agent는 생성된 각 이미지를 attachment로 반환합니다. 선택한 모델이 reference image를 허용하면 Agent는 기존 이미지를 편집할 수도 있습니다.

## 실행 경로 선택

공개 `image_generation` tool에는 두 가지 실행 경로가 있습니다.

- **Hosted:** Agent의 `image_generate` profile을 구성합니다. AIGateway가 해당 별도 provider와 모델로 tool을 실행한 다음 결과를 메인 모델에 반환합니다.
- **Native:** `image_generate`를 비워 두고 native image generation을 선언하는 메인 provider를 사용합니다. OpenAI와 ChatGPT Subscription이 이 경로를 지원합니다. AIGateway는 공개 tool을 해당 provider에 전달합니다.

따라서 `image_generate` profile은 활성화 스위치가 아니라 라우팅 스위치입니다. profile이 비어 있고 메인 provider가 native image generation을 선언하지 않으면 AIGateway는 명확한 configuration 오류와 함께 tool을 거부합니다.

hosted 경로를 사용하려면:

1. Console의 **LLM Providers**에서 필요한 이미지 모델을 지원하는 Provider를 추가합니다.
2. **Agents**를 열고 Agent를 선택합니다.
3. model profile에서 `image_generate`를 찾습니다.
4. 이미지 Provider와 모델을 선택하고 profile을 저장합니다.
5. chat으로 돌아가 명확한 이미지 요청을 보냅니다.

model-token 사용량은 메인 provider credential에 귀속됩니다. image-token 사용량은 pool rotation 이후에도 이미지를 생성한 credential에 귀속됩니다.

## 짧은 시각적 브리프 작성

요청은 길 필요가 없습니다. 이미지가 어디에 사용될지, 무엇을 보여야 하는지, 어디에서 임의로 창작하면 안 되는지를 Agent에 알려 주십시오. 목적과 주제부터 시작하십시오. 그런 다음 결과에 영향을 주는 구도, 시각적 스타일, 제약만 추가하십시오.

유용할 때 다음 다섯 부분을 사용하십시오.

- **용도와 캔버스:** 웹사이트, 프레젠테이션, 소셜 포스트 같은 대상을 지정합니다. 가로(landscape), 세로(portrait), 정사각형(square) 또는 정확한 종횡비를 제시합니다.
- **주제와 장면:** 주요 주제, 주변 환경, 그리고 동작을 지정합니다.
- **구도와 시각 언어:** 중요한 시점, 배치, 여백(negative space), 재질, 조명 또는 매체만 지정합니다.
- **이미지 속 텍스트:** 정확한 텍스트를 따옴표 안에 넣고 위치를 명시합니다. 긴 문구는 가능하면 이미지밖에 둡니다.
- **제약:** 나타나면 안 되는 텍스트, 워터마크, 로고 또는 객체를 지정합니다. reference image의 경우 변경되지 않아야 할 부분도 명시합니다.

예를 들어:

```text
Use: A 16:9 hero image for a product announcement. The page title will be on the left.
Subject: A white device on a dark blue table, placed on the right.
Composition: Simple geometry, soft side light, and a large open area on the left.
Text: Include only "ANKOLE 2.0" in the bottom-right corner.
Constraints: No people, watermarks, other brand marks, or extra text.
```

텍스트, 크기, reference-image 지원은 모델마다 다릅니다. 선택한 모델과 해당 Provider의 문서를 확인하십시오.

## 같은 chat에서 이미지 다듬기

이미지가 첫 시도에서 완성되어야 하는 경우는 드뭅니다. 하나의 방향으로 생성한 다음 같은 chat에서 작은 변경을 반복하십시오. 각 turn에서 하나의 문제 또는 서로 관련된 문제 하나의 묶음만 변경하십시오. 이렇게 하면 결과를 더 쉽게 제어할 수 있고 전체 재작성을 피할 수 있습니다.

편집의 경우 무엇을 바꿀지와 무엇을 유지할지를 둘 다 명시하십시오. 예를 들어:

```text
Change only the background to light gray. Keep the subject, composition,
lighting, text position, and colors unchanged.
```

reference image를 두 개 이상 첨부한다면 “Image 1”, “Image 2”로 라벨을 붙이고 각 이미지의 역할을 명시하십시오. 예를 들어 Image 1의 주제와 Image 2의 색상을 사용하십시오. 이 방법은 선택한 모델이 reference image 또는 편집을 지원할 때만 동작합니다.

## 이미지가 나타나지 않는 경우

- **Agent가 텍스트만 반환함:** 클라이언트 또는 Agent가 `image_generation` tool을 노출하는지 확인하십시오. 그런 다음 `image_generate`가 구성되었거나 메인 Provider가 native image generation을 지원하는지 확인하십시오.
- **사용 가능한 모델이 없음:** 현재 LLM Providers에 image-generation 모델이 없습니다. 이 기능을 지원하는 Provider를 추가하십시오.
- **요청이 지원되지 않음:** 호환되는 모델을 선택하거나, 지원되지 않는 크기, 형식, 투명 배경, reference image 또는 편집 요청을 제거하십시오.
- **이미지는 나타나지만 내용이 잘못됨:** 보통 설정 문제가 아닙니다. 같은 chat에서 계속하며 무엇을 바꾸고 무엇을 유지할지 명시하십시오.
- **생성은 성공했지만 chat에 attachment가 없음:** Channel Provider가 여전히 파일을 업로드할 수 있는지 확인하고 해당 conversation의 오류를 읽으십시오.

사용 가능한 크기, 형식, 투명 배경, reference image 및 편집 기능은 모델과 해당 Provider에 따라 다릅니다.
