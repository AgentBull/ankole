---
title: Web ツール
description: Agent の Web 検索とページ読み取りを設定する方法と、ブラウザ自動化へ切り替えるべき場面の見極め方を説明します。
section: User guide
order: 33
---

Agent は公開 Web ページを探すときに `web_search` を使い、見つけたページの本文を読み取るときに `web_fetch` を使います。`web_search` を利用するには対応する Provider の設定が必須ですが、`web_fetch` については Provider が未設定でも Worker 組み込みのレンダリングフォールバックを利用できます。

## 正しいツールを選ぶ

| 能力 | 適した場面 | 実行面 |
|---|---|---|
| `web_search` | キーワード、期間、対象ドメイン条件から公開ページを検索する | Main Agent と Background Agent Job |
| `web_fetch` | URL が判明している 1 つ以上の公開ページをテキストとして読み取る | Main Agent と Background Agent Job |
| [ブラウザ自動化](../browser-automation/) | ログイン、クリック、フォーム入力、画面遷移、スクリーンショット撮影、対話型 Web アプリの操作 | **Background Agent Job のみ** |

ブラウザ自動化は `browser` Skill によって提供されており、`ankole-runtime: background_job` が宣言されています。そのため、`web_search` や `web_fetch` の Provider 選択肢には表示されず、通常のメイン Agent の Turn 内で直接動かすこともできません。

ブラウザ操作が必要な作業を依頼したいときは、メイン Agent に新しく Background Agent Job を立ち上げさせるか、既存の Job を使わせてください。Job は現在のチャット会話をブロックせずに裏側で進み、確認事項や進捗、完了結果を元の会話へ返します。

## Web ツールの設定

### Provider の追加

1. **Console → LLM Providers** を開きます。
2. `web_search`、`web_fetch`、またはその両方に対応している Provider 種別を選択します。
3. API キーと、その Provider で必須となっている設定項目を入力します。
4. 設定を保存し、Provider が有効（Enabled）になっていることを確認します。

同じ Provider 種別から複数のインスタンスを作成することも可能です。たとえば Bright Data SERP のインスタンスを 2 つ登録し、検索リージョンを使い分けたり、Agent ごとに別々のアカウントを割り当てたりできます。

### Provider の Agent への割り当て

1. **Console → Agents** を開き、対象の Agent を選択します。
2. **Model profiles** の中から `web_search` を探し、検索に対応した Provider を選択します。
3. 続けて `web_fetch` を探し、ページ読み取りに対応した Provider を選択します。
4. 両方のプロファイルを保存し、新しい会話を開始します。

これらは Provider 指定専用のプロファイルであるため、モデル名やコンテキスト長の設定は不要です。各 Provider 種別が対応機能（capability）を宣言しているため、プルダウンには条件に合致するインスタンスだけが表示されます。

選択肢が空の場合は、先に該当機能を持つ Provider を追加してください。初回の Provider 登録手順については、[クイックスタート](../quickstart/#llm-providers) を参照してください。

## 現在の組み込み Provider

Control Plane Plugin によってさらに Provider 種別を追加することもできますが、標準で Ankole に同梱されている Provider は次のとおりです。

### `web_search` Provider

| Provider | `web_fetch` も対応 | 主な特徴 | 適した場面 |
|---|---|---|---|
| **Parallel** | はい | 単一 Provider で検索と本文抽出の両方を提供。目的（objective）指定、複数クエリ、モード切替、合計文字数バジェットに対応 | 検索と読み取りを 1 つの認証情報にまとめたいとき、またはリサーチ向けのクエリを投げたいとき |
| **Bright Data SERP** | いいえ | SERP API を使用。Zone 指定が必須で、国・言語・Google ドメインを細かく指定可能 | 検索リージョンや言語、ローカライズされた検索結果を厳密に制御したいとき |
| **Jina Search** | いいえ | リージョン、ロケーション、言語、ページ番号、キャッシュ、検索エンジンの指定に対応 | 地域指定、ページネーション、キャッシュ制御を伴う直接的な Web 検索を行いたいとき |
| **AgentBull Cloud** | はい | 検索・ページ抽出に加えてモデル機能（`llm`、`embedding`、`rerank`、`image_generate`）も統合。対象ドメイン範囲、期間指定、キャッシュ回避に対応 | Web ツールと各種モデルを単一の API キーに集約したいとき、またはドメインや期間を絞った検索が必要なとき |

Parallel または AgentBull Cloud を使う場合は、1 つの Provider インスタンスを `web_search` と `web_fetch` の両方にそのまま割り当てられます。

一方、Jina Search と Jina Reader は別々の Provider 種別として定義されています。同じ Jina の API キーを使う場合でも、それぞれ個別の Provider として登録し、対応するプロファイルへ割り当ててください。

### `web_fetch` Provider

| Provider | `web_search` も対応 | 主な特徴 | 適した場面 |
|---|---|---|---|
| **Parallel** | はい | Parallel Search と同じ Provider・認証情報でページ本文を抽出 | すでに Parallel Search を導入しており、設定を一本化したいとき |
| **AgentBull Cloud** | はい | 同じ AgentBull Cloud Provider と API キーで公開ページ本文を抽出 | すでにモデルや検索で AgentBull Cloud を利用しており、認証情報をまとめたいとき |
| **Jina Reader** | いいえ | 公開ページを Markdown へ変換。リンク保持、対象・待機セレクタ、キャッシュ、エンジン切替、トークン上限に対応 | 記事本文のきれいな Markdown 変換や、ページ内の特定要素だけの抽出が必要なとき |

`web_fetch` はログイン不要の公開 HTTPS ページを対象としており、認証突破や PDF・画像・アーカイブ・音声・動画ファイルのダウンロードには対応していません。

なお、Worker 組み込みのレンダリングフォールバックは外部 Provider ではないため、Console の Provider 一覧には表示されません。描画後のページからテキストを読み取るだけのシンプルな仕組みです。

そのため、組み込みフォールバックではクリックや文字入力、ログイン状態の保持、スクリーンショット撮影は行えず、メイン Agent にブラウザ自動化機能を提供するものでもありません。

また、Provider のセレクタ指定や待機オプションを使えば遅延描画されるテキストを拾いやすくすることはできますが、実際のユーザー操作を代替するものではありません。ログインやクリック、フォーム入力を伴う作業では、Background Agent Job 内のブラウザ自動化を利用してください。

## Agent に Web ツールを使わせる

特別なスラッシュコマンドなどは不要です。達成したい結果を自然な言葉で伝えてください。たとえば次のように依頼します。

> 今週公開された関連アナウンスを 3 件探してください。一次情報のページを読んで変更点を比較し、出典リンクも添えてください。

このように依頼すると、Agent はまず `web_search` で候補を探し、続いて読むべきページを選んで `web_fetch` で内容を確認します。対象ページの URL が最初から分かっている場合は、その URL を直接貼って要約や抽出を依頼してください。

反対に、次のようなケースでは「ブラウザを使って確認して」と明示的に依頼するとスムーズです。

- 閲覧にログインが必要なページ
- 本文を表示する前にクリック、文字入力、画面遷移が必要なページ
- スクリーンショットの撮影や、実際の描画レイアウトの目視確認が必要な作業
- 複雑な UI 操作を行った後にはじめて目的のデータが表示されるページ

ブラウザ操作は Background Agent Job 内で実行されます。通常の Web 検索や公開記事の読み取り、複数ソースの比較であれば、`web_search` と `web_fetch` を使う方が高速で手軽です。

## Web タスクがうまく動かないとき

### 検索または読み取りの失敗

上から順に次の点を確認してください。

1. 対象の Agent に必要なプロファイルが設定されているか（特に `web_search` には Provider の割り当てが必須です）。
2. `web_fetch` に Provider を設定していない場合、Worker 側で組み込みレンダリングフォールバックが利用できる状態にあるか。
3. 選択した Provider 種別が、使いたい機能（検索または読み取り）に対応しているか。
4. Provider が有効化されており、API キーや必須項目に誤りがないか。
5. プロファイル変更後に、新しいチャット会話を開始したか。
6. アクセス先がログイン不要の公開 HTTPS ページであるか。

### ブラウザ自動化が実行されなかった

対象の Agent で `browser` Skill が有効になっており、かつ Background Agent Job を作成できる状態にあるかを確認してください。なお、`web_search` や `web_fetch` のプロファイル欄にブラウザ自動化を割り当てることはできません。

すでに Background Agent Job として動いているタスクで失敗する場合は、Worker の空きスロット状況と、Job ログに記録されたブラウザセッションやネットワーク到達性のエラーを確認してください。
