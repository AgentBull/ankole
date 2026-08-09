---
title: 画像生成
description: Agent 用の画像 model を選択し、チャットで画像を生成または編集する。
section: User guide
order: 24
---

Agent にイラスト、コンセプトアート、ビジュアルのドラフトを作らせたいときは、画像生成を有効にします。ユーザーは同じチャットに留まり、Agent は生成した各画像を添付ファイルとして返します。選択した model が参照画像を受け入れる場合、Agent は既存の画像を編集することもできます。

## 実行パスを選択する

公開 `image_generation` tool には 2 つの実行パスがあります。

- **Hosted:** Agent の `image_generate` profile を設定します。AIGateway がその別の provider と model で tool を実行し、結果をメインモデルに戻します。
- **Native:** `image_generate` を空のままにし、ネイティブ画像生成を宣言するメインの provider を使います。OpenAI と ChatGPT Subscription がこのパスをサポートします。AIGateway は公開 tool をその provider に渡します。

したがって `image_generate` profile は、有効スイッチではなくルーティングスイッチです。profile が空で、メインの provider がネイティブ画像生成を宣言していない場合、AIGateway は明確な設定エラーと共に tool を拒否します。

Hosted パスを使うには:

1. Console の **LLM Providers** で、必要な画像 model をサポートする Provider を追加します。
2. **Agents** を開き、Agent を選択します。
3. その model profile の中から `image_generate` を見つけます。
4. 画像用の Provider と model を選択し、profile を保存します。
5. チャットに戻り、明確な画像リクエストを送信します。

model-token の使用量はメインの provider credential に留まります。image-token の使用量は、画像を生成した credential に留まります。pool のローテーション後も同様です。

## 短いビジュアルブリーフを書く

リクエストは長くする必要はありません。画像がどこで使われるか、何が描かれていなければならないか、どこで勝手に想像してはいけないかを Agent に伝えます。まず用途と主題から始めます。その後、結果に影響する構図、ビジュアルスタイル、制約だけを追加します。

役立つときは、次の 5 つの部分を使います。

- **用途とキャンバス:** ウェブサイト、プレゼンテーション、SNS の投稿などの宛先を指定します。横長、縦長、正方形、または正確なアスペクト比を指定します。
- **主題とシーン:** 主な主題、その周囲、動作を指定します。
- **構図とビジュアル言語:** 重要な視点、配置、ネガティブスペース、素材、光、または媒体だけを指定します。
- **画像内のテキスト:** 正確なテキストを引用符に入れ、その位置を記述します。長いコピーは、可能なら画像の外に置きます。
- **制約:** 出現してはならないテキスト、ウォーターマーク、ロゴ、オブジェクトを指定します。参照画像がある場合は、変更してはならないものも記述します。

例えば:

```text
Use: A 16:9 hero image for a product announcement. The page title will be on the left.
Subject: A white device on a dark blue table, placed on the right.
Composition: Simple geometry, soft side light, and a large open area on the left.
Text: Include only "ANKOLE 2.0" in the bottom-right corner.
Constraints: No people, watermarks, other brand marks, or extra text.
```

テキスト、サイズ、参照画像のサポートは model によって異なります。選択した model とその Provider のドキュメントを確認してください。

## 同じチャットで画像を仕上げる

画像が最初の試みで完成することはまれです。1 つの方向を生成し、その後同じチャットで小さな変更を加えます。各 Turn で 1 つの問題、または関連する問題群を 1 つ変更します。これにより結果を制御しやすくなり、全面的な書き直しを避けられます。

編集の場合、何を変更し、何を保持するのか、両方を指定します。例えば:

```text
Change only the background to light gray. Keep the subject, composition,
lighting, text position, and colors unchanged.
```

参照画像を複数添付する場合、それらを「画像 1」「画像 2」とラベル付けし、それぞれの役割を指定します。例えば、画像 1 の主題と画像 2 の色を使います。これは、選択した model が参照画像または編集をサポートする場合にのみ機能します。

## 画像が表示されない場合

- **Agent がテキストだけを返す:** クライアントまたは Agent が `image_generation` tool を公開していることを確認します。次に、`image_generate` が設定されているか、メインの Provider がネイティブ画像生成をサポートしていることを確認します。
- **利用可能な model がない:** 現在の LLM Providers が画像生成 model を提供していません。この能力をサポートする Provider を追加してください。
- **リクエストがサポートされていない:** 互換性のある model を選択するか、サポートされていないサイズ、フォーマット、透明背景、参照画像、編集リクエストを削除してください。
- **画像は表示されるが内容が間違っている:** これは通常、設定の問題ではありません。同じチャットで続け、何を変更し、何を保持するかを指定してください。
- **生成は成功するがチャットに添付がない:** Channel Provider がファイルをアップロードできるかどうかを確認し、その会話のエラーを読んでください。

利用可能なサイズ、フォーマット、透明背景、参照画像、編集機能は、model とその Provider に依存します。