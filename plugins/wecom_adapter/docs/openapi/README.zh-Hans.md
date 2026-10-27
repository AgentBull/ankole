# WeComOpenAPI

`WeComOpenAPI` 是专为 Ankole 企业微信适配器构建的轻量 Elixir 客户端，覆盖适配器所需的两套企业微信接口体系：

- **智能机器人长连接通道**（`WeComOpenAPI.Bot.Client` + `WeComOpenAPI.Bot`）：管理
  `wss://openws.work.weixin.qq.com` 长连接，支持订阅鉴权、心跳保活、消息与事件分发、流式回复、模板卡片、主动推送、分片媒体上传，以及加密媒体下载（`WeComOpenAPI.Media`）。企业微信限制每个机器人同时只能维持一条在线连接；一旦收到被顶下线的 `disconnected_event`，客户端会直接停止，避免与新连接反复互踢。
- **企业微信 REST 接口**（`WeComOpenAPI` + `WeComOpenAPI.Corp.Client`）：封装
  `https://qyapi.weixin.qq.com` 接口，支持按 `{corp_id, secret}` 缓存访问令牌（`WeComOpenAPI.TokenManager`）、企业微信扫码登录辅助函数（`WeComOpenAPI.OAuth`），以及通讯录查询（`WeComOpenAPI.Contact`，读取成员姓名需配置通讯录同步 Secret）。

两套接口的调用错误均统一转换为 `WeComOpenAPI.Error`，并通过 `reason` 字段提供稳定的错误分类（如 `:auth`、`:ip_rejected`、`:rate_limited` 等）。
