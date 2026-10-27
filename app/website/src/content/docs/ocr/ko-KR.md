---
title: OCR 텍스트 인식
description: GPU나 외부 OCR 서비스 없이 Agent가 스캔한 PDF, 사진, 스크린샷, 영수증을 읽게 하세요.
section: User guide
order: 25
---

파일을 Agent에게 전달하고 읽어 낼 텍스트를 요청해 보세요. Agent Computer Worker에 OCR 엔진이 기본 내장되어 있으므로, 별도의 모델 Provider나 API 키, 외부 OCR 서비스를 추가로 설정할 필요가 없습니다.

예를 들어 다음과 같이 요청할 수 있습니다.

```text
Read all text in this screenshot and keep the original reading order.

Extract pages 2 to 5 from this scanned PDF. Mark any text that you cannot read with confidence.

Read this receipt and list the merchant, date, items, tax, and total.
```

## 일반 CPU에서의 고급 인식

Ankole은 일반 CPU에서도 높은 정확도로 동작하는 최신 [PaddleOCR PP-OCRv6 medium](https://www.paddleocr.ai/latest/en/version3.x/algorithm/PP-OCRv6/PP-OCRv6.html) 검출·인식 모델을 사용합니다. PP-OCRv6 제품군 가운데 정확도에 중점을 둔 medium 티어 모델로, PaddleOCR 공식 평가 기준 `PP-OCRv5_server` 대비 텍스트 검출은 4.6%, 텍스트 인식은 5.1% 향상되었습니다.

단일 모델로 간체·번체 중국어, 영어, 일본어 및 라틴 문자 기반 46개 언어를 합쳐 총 50개 언어를 인식합니다. 일반 스캔 문서와 스크린샷은 물론 간판, 제품 라벨, 디지털 디스플레이처럼 일상 장면에서 촬영한 사진 속 글자도 처리할 수 있습니다.

또한 OpenVINO로 최적화된 CPU 추론 경로를 통해 Worker 로컬에서 모델을 바로 실행하므로, GPU가 없는 표준 Worker에서도 빠르게 텍스트를 읽어 냅니다. 모델 가중치가 Worker 이미지 안에 포함되어 있어 문서가 외부 OCR 서비스로 전송되지 않으며, 페이지당 추가 과금도 발생하지 않습니다.

## Ankole이 정확한 경로를 선택

픽셀에서 글자를 추정하는 OCR과 달리, 일반 텍스트 추출은 문서에 들어 있는 원본 문자를 그대로 읽어 옵니다. 따라서 Ankole은 원본 문자를 추출할 수 있을 때 더 정확한 경로를 우선 선택합니다.

- 텍스트 레이어가 살아 있는 PDF에서는 원본 텍스트를 바로 추출합니다.
- 전체가 이미지로 스캔된 PDF에서는 모든 페이지에 OCR을 수행합니다.
- 두 형태가 섞인 혼합 PDF에서는 이미지 페이지에만 OCR을 적용하고 나머지 페이지는 직접 추출합니다.
- DOCX, PPTX, XLSX 파일은 각 페이지를 이미지로 변환하지 않고 문서 구조를 직접 읽어 들입니다.

사용자가 추출 방식을 일일이 지정할 필요는 없으며, 가급적 원본 파일을 그대로 전달하고 원하는 결과 형식만 알려 주면 됩니다.

## Agent가 반환할 수 있는 것

Agent는 인식한 결과를 바탕으로 순수 텍스트, 정돈된 전사본, 요약문, 구조화된 항목을 반환할 수 있습니다. OCR 엔진이 각 줄의 좌표와 신뢰도(confidence) 점수도 함께 내어 주므로, Agent는 원래 읽기 순서를 유지할 수 있고 스캔 상태가 흐릿해 인식이 불확실한 구간이 있으면 경고를 덧붙일 수도 있습니다.

인식 품질을 높이려면 해상도가 충분하고 흔들림이나 기울어짐이 없는 선명한 이미지를 사용하세요. 작은 글씨가 들어 있는 문서는 재압축된 스크린샷 대신 원본 파일을 그대로 보내는 편이 좋습니다. 확실하지 않은 글자를 임의로 추측하지 말고 불확실한 줄을 따로 표시해 달라고 요청할 수도 있습니다.

## 제한

- 한국어, 아랍어, 키릴 문자, 태국어 등 50개 언어 모델에 포함되지 않은 문자 체계는 지원하지 않습니다.
- 손글씨, 수식, 복잡한 표, 곡선 형태로 배치된 글자, 초점이 흐리거나 심하게 기울어진 사진에서는 인식률이 낮아질 수 있습니다. 특히 표는 셀 구조가 보장된 테이블이 아니라 좌표가 붙은 텍스트 줄 단위로 반환됩니다.
- OCR은 문서 내용을 읽어 올 뿐, 원본 PDF 파일 자체에 검색 가능한 텍스트 레이어를 새로 심어 주지는 않습니다.

`ocr` Skill은 기본적으로 활성화되어 있습니다. 만약 Agent가 OCR을 사용할 수 없다고 답하면 최신 Worker 이미지를 사용 중인지, 그리고 **Agent Library**에서 해당 Skill이 켜져 있는지 확인하세요.