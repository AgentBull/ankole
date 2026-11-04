# Personal approval inbox

Publish `server/main.js` as the server entry of an Applet page. Each subscriber creates a human-authorized Job for its `inbox` action, with `config.connection` set to the Lark connection slug. The subscriber needs an active Lark employee binding; approval decisions use that employee's verified ID.

Attach a native schedule to the Job to refresh pending tasks. Attach a Signal binding from `connector://AUTH_CONFIG_ID/lark` to the same Job, filtered to `card.action.trigger`. Configure Lark's card callback on the connection's webhook URL, or enable its authenticated long connection. Optionally bind an approval-definition trigger to the Job for immediate refreshes. The page's Job, schedule, and event subscription controls own these resources.

The action sends one interactive card per task, checks the authenticated callback operator and message against the personal Job, applies the selected decision, and replaces the card with its outcome. It stores the card IDs and decision progress in native Job state. A duplicate callback only repairs the card after a completed decision. When Lark explicitly rejects a decision, the card keeps its buttons and reports that the decision was not submitted; the subscriber can retry after resolving the error. If Lark accepted a decision but its response was lost, inspect the task in Lark before taking another action; the Job never repeats an uncertain decision automatically.

The example's integration test executes the packaged source through Function Runtime, the connector MCP gateway, signed Lark callback ingestion, durable Signals, and real HTTP provider protocol fixtures.
