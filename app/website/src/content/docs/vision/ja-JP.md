---
title: Agent に画像を読ませる
description: Agent に画像理解を設定し、chat でのスクリーンショット、写真、図の読み取りを検証する。
section: User guide
order: 42
---

ユーザーは chat で Agent にスクリーンショット、写真、図を送れます。通常の Turn の model が画像を受け取れない場合、Ankole は `vision_fallback` profile の model を使って画像を読み取ります。

`primary` がすでに画像入力に対応している場合は、この profile を空のままにできます。画像を受け取らない Agent でも空のままにできます。

## 画像 model を設定する

1. **Console → Agents** を開き、Agent を選択します。
2. **Model profiles** で `vision_fallback` を探します。
3. 画像入力を明示的にサポートする Provider と model を選択します。
4. profile を保存し、新しい会話を開始します。

model のリストが画像対応をあなたに代わって決めることはありません。model を選択する前に Provider のドキュメントを確認してください。

## 設定を検証する

Agent に接続された chat で、鮮明な画像を送ります。画像が必要な質問をしてください。たとえば次のように。

> このスクリーンショットにはどのようなエラーが表示されていますか。最も可能性の高い原因を教えてください。

Agent が画像を無視する、または読み取れないと言う場合は、次の項目を順に確認してください。

1. chat channel が画像をアップロードして転送したか。
2. `vision_fallback` が正しい Agent に保存されているか。
3. 選択した model が画像入力に対応しているか。
4. Provider の credential と quota が利用可能か。

Agent に画像を生成させるには、[Image generation](../image-generation/) を参照してください。画像生成と画像理解は、異なる model profiles を使います。
