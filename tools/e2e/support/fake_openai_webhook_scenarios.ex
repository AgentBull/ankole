defmodule Ankole.E2E.FakeOpenAIWebhookScenarios do
  @moduledoc "Deterministic model commands for the real webhook CLI, RPC and HTTP path."

  def action_for(1) do
    script = ~S"""
    const { createHash } = await import("node:crypto");
    const expiry = new Date(Date.now() + 600000).toISOString();
    function cli(name, args) {
      const result = Bun.spawnSync([name, ...args], {stdin: "ignore", stdout: "pipe", stderr: "pipe"});
      if (result.exitCode !== 0) throw new Error("webhook CLI failed: " + name);
      return JSON.parse(new TextDecoder().decode(result.stdout));
    }
    function create() {
      const result = cli("create-webhook-cli", ["--label", "R22 identical creates", "--mode", "one_shot", "--expires-at", expiry]);
      if (result.status !== "created") throw new Error("webhook create was not accepted");
      return result.webhook_endpoint;
    }
    const endpoints = [create(), create()];
    const listed = cli("list-webhooks-cli", []).webhook_endpoints;
    if (listed.length !== 2 || listed.some(item => "url" in item || "token" in item)) {
      throw new Error("webhook listing contract failed");
    }
    const results = [];
    for (const [index, endpoint] of endpoints.entries()) {
      const url = new URL(endpoint.url);
      if (url.hostname !== "host.docker.internal") throw new Error("callback origin is not reachable from the Worker");
      const token = url.pathname.split("/").at(-1);
      if (!token.startsWith("wh_")) throw new Error("callback capability is missing");
      const digest = createHash("sha256").update(token).digest("base64url");
      const post = async () => (await fetch(endpoint.url, {
        method: "POST", headers: {"content-type": "application/json"},
        body: JSON.stringify({marker: "r22-http-" + index})
      })).status;
      const statuses = index === 0 ? [await post(), await post()] : await Promise.all([post(), post(), post()]);
      results.push({id: endpoint.id, digest, statuses});
    }
    const remaining = cli("list-webhooks-cli", []).webhook_endpoints;
    console.log("R22_WEBHOOK_RESULT=" + JSON.stringify({results, listed: listed.length, remaining: remaining.length}));
    """

    {:tool_call,
     %{
       id: "call_r22_webhook_cli",
       name: "command",
       arguments: %{
         "command" => "bun -e '" <> String.replace(script, "'", "'\"'\"'") <> "'",
         "timeout" => 60
       }
     }}
  end

  def action_for(_count), do: {:completion, "CHAOS_WEBHOOK_CLI_OK", []}
end
