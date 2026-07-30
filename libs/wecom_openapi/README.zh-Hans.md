# WeComOpenAPI

为 Ankole 企业微信适配器构建的企业微信（WeCom）薄客户端。

覆盖适配器使用的两个产品面：

- **智能机器人通道**（`WeComOpenAPI.Bot.Client` + `WeComOpenAPI.Bot`）：
  `wss://openws.work.weixin.qq.com` 长连接——subscribe 认证、ping 心跳、
  消息/事件分发、流式回复、模板卡片、主动发送、分片媒体上传、
  加密媒体下载（`WeComOpenAPI.Media`）。平台每机器人只允许一条连接；
  收到 `disconnected_event` 被踢时客户端直接停止，不与新连接互踢。
- **企业 REST**（`WeComOpenAPI` + `WeComOpenAPI.Corp.Client`）：
  `https://qyapi.weixin.qq.com` API，按 `{corp_id, secret}` 缓存
  access token（`WeComOpenAPI.TokenManager`），WWLogin 登录助手
  （`WeComOpenAPI.OAuth`），通讯录读取（`WeComOpenAPI.Contact`，
  成员姓名需要通讯录同步 Secret）。

两个面的失败统一归一化为 `WeComOpenAPI.Error`，`reason` 提供稳定分类
（`:auth`、`:ip_rejected`、`:rate_limited` 等）。
