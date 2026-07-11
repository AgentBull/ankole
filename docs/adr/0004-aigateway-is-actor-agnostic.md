# AIGateway 不理解 Actor 语义

AIGateway 是面向任意 Principal 的通用 Responses 服务，只拥有模型协议、Provider、Conversation 与 Response；Actor、最终回复投影和 provider-visible side effect 属于 SignalsGateway。调用方可在标准 metadata 中保存自己的关联标识，但 AIGateway 不解释、不索引，也不据此改变 Response 生命周期。

## Consequences

- SignalsGateway 可以依赖 AIGateway 的公开 Response 接口，AIGateway 不得反向依赖 SignalsGateway 或 Actor。
- AIGateway 的 Response terminal 与 Actor Event completion 是两个独立提交；系统接受两者之间的短暂中间状态。
