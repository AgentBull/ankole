# Agent Computer 显式声明 Agent Turn 完成

Agent Computer 是 Model Iteration 与 Turn Iteration Budget 的唯一语义中心，并在 loop 结束后发送带最终 Response ID 的显式 Agent Turn Completion；SignalsGateway 据此完成 Actor Event。系统不再根据某个 Response 是否包含 function call 推断 Turn 终态，也不为这个交接新增 ACK、durable execution、checkpoint 或 exact resume。

## Consequences

- Worker crash 或 completion 丢失继续依赖既有 lease/redelivery，新的 execution 获得新的本地预算。
- Iteration Exhaustion 以无工具总结结束当前 Turn，但不表示用户任务已完整成功。
