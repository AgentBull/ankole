---
title: OCR 텍스트 인식
description: GPU나 외부 OCR 서비스 없이 Agent가 스캔한 PDF, 사진, 스크린샷, 영수증을 읽게 하세요.
section: User guide
order: 25
---

파일을 Agent에게 보내고 필요한 텍스트를 요청하세요. Ankole은 Agent Computer Worker에 OCR을 포함하므로 모델 Provider, API 키, 별도의 OCR 서비스를 구성할 필요가 없습니다.

예를 들어 다음과 같이 요청할 수 있습니다:

```text
Read all text in this screenshot and keep the original reading order.

Extract pages 2 to 5 from this scanned PDF. Mark any text that you cannot read with confidence.

Read this receipt and list the merchant, date, items, tax, and total.
```

## 일반 CPU에서의 고급 인식

Ankole은 최첨단이며 CPU에서 동작하는 [PaddleOCR PP-OCRv6 medium](https://www.paddleocr.ai/latest/en/version3.x/algorithm/PP-OCRv6/PP-OCRv6.html) 검출·인식 모델을 사용합니다. medium 티어는 PP-OCRv6 계열에서 정확도에 초점을 맞춘 모델입니다. PaddleOCR의 평가에서 PP-OCRv5_server 대비 텍스트 검출이 4.6%, 텍스트 인식이 5.1% 개선되었습니다.

하나의 모델이 간체 중국어, 번체 중국어, 영어, 일본어, 라틴 문자 기반 46개 언어를 포함한 50개 언어를 지원합니다. 문서 스캔과 스크린샷, 간판, 제품 라벨, 디지털 디스플레이 같은 자연 장면의 텍스트도 처리합니다.

Ankole은 OpenVINO 최적화 CPU 추론 경로로 모델을 로컬에서 실행합니다. 따라서 일반 Worker가 GPU 없이도 빠른 로컬 인식을 수행합니다. 모델은 이미 Worker 이미지에 있으므로 문서가 외부 OCR 서비스로 나가지 않고 페이지마다 비용도 없습니다.

## Ankole이 정확한 경로를 선택

OCR은 픽셀에서 텍스트를 추정하지만, 일반 추출은 원본 문자를 읽습니다. Ankole은 이를 사용할 수 있을 때 더 정확한 경로를 선택합니다:

- 텍스트 레이어가 있는 PDF에서는 Agent가 원본 텍스트를 추출합니다.
- 완전히 스캔된 PDF에서는 모든 페이지를 인식합니다.
- 혼합 PDF에서는 OCR이 필요한 페이지에만 OCR을 사용하고 나머지 페이지는 직접 추출합니다.
- DOCX, PPTX, XLSX 파일에서는 각 페이지를 이미지로 취급하는 대신 문서 구조를 읽습니다.

이 경로를 직접 선택할 필요는 없습니다. 가능하면 원본 파일을 보내고 원하는 결과를 명시하세요.

## Agent가 반환할 수 있는 것

Agent는 인식된 텍스트에서 순수 텍스트, 정리된 스크립트, 요약, 구조화된 사실을 반환할 수 있습니다. OCR은 또한 각 줄의 위치와 신뢰도(confidence)를 제공합니다. 이를 통해 Agent는 읽는 순서를 보존하고, 품질이 낮은 스캔이 신뢰할 수 없을 때 경고할 수 있습니다.

최상의 결과를 얻으려면 충분한 해상도의 선명하고 똑바른 이미지를 사용하세요. 원본에 작은 글씨가 있으면 압축된 스크린샷 대신 원본 파일을 보내세요. Agent에게 조용히 추측하는 대신 불확실한 줄을 보고하도록 요청할 수도 있습니다.

## 제한

- 한국어, 아랍어, 키릴 문자, 태국어 등 50개 언어 모델에 없는 문자 체계는 지원되지 않습니다.
- 손글씨, 수식, 복잡한 표, 곡선 텍스트, 흐리거나 심하게 기울어진 사진은 정확도가 떨어질 수 있습니다. 표는 보장된 표 구조가 아니라 위치가 정해진 텍스트 줄로 반환됩니다.
- OCR은 내용을 읽지만 원본 PDF에 검색 가능한 텍스트 레이어를 추가하지는 않습니다.

`ocr` Skill은 기본적으로 활성화되어 있습니다. Agent가 OCR을 사용할 수 없다고 말하면 Agent가 최신 Worker 이미지를 사용하는지, 그리고 **Agent Library**에서 Skill이 활성화되어 있는지 확인하세요.