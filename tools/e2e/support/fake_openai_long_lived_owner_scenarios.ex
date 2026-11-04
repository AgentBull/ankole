defmodule Ankole.E2E.FakeOpenAILongLivedOwnerScenarios do
  @moduledoc "Model commands for real Agent tools, Applet Jobs and callback delivery."

  def classify(request, prompt) do
    native? = Enum.any?(request["tools"] || [], &(get_in(&1, ["function", "name"]) == "exec"))

    cond do
      String.contains?(prompt, "CHAOS_ASSISTANT_POD_CLI") -> :assistant_pod_cli
      String.contains?(prompt, "CHAOS_SERVICE_POD_CLI") -> :service_pod_cli
      String.contains?(prompt, "CHAOS_HUMAN_POD_CLI") -> :human_pod_cli
      String.contains?(prompt, "CHAOS_B07_WAKE") -> :b07_wake
      native? and String.contains?(prompt, "CHAOS_B07_JOB") -> :b07_job
      String.contains?(prompt, "CHAOS_B07_CREATE") -> :b07_create
      String.contains?(prompt, "CHAOS_B07_JOB") -> :b07_notice
      true -> nil
    end
  end

  def action_for(kind, 1) when kind in [:assistant_pod_cli, :service_pod_cli, :human_pod_cli] do
    script = if kind == :assistant_pod_cli, do: "e2e-assistant-cli.ts", else: "e2e-pod-cli.ts"

    {:tool_call,
     %{
       id: "call_#{kind}",
       name: "command",
       arguments: %{
         "command" => "bun /workspace/" <> script,
         "timeout" => 90
       }
     }}
  end

  def action_for(:assistant_pod_cli, _count), do: {:completion, "ASSISTANT_POD_CLI_DONE", []}

  def action_for(kind, _count) when kind in [:service_pod_cli, :human_pod_cli],
    do: {:completion, "POD_CLI_DONE", []}

  def action_for(:b07_create, 1) do
    Ankole.E2E.FakeOpenAIState.await_release(:b07_create)

    {:tool_call,
     %{
       id: "call_b07_create",
       name: "create_background_job",
       arguments: %{
         "title" => "Persistent callback ownership",
         "task" =>
           "CHAOS_B07_JOB Register webhook and Applet Action callbacks for the originating conversation."
       }
     }}
  end

  def action_for(:b07_job, 1) do
    script = ~S"""
    function cli(name, args) {
      const result = Bun.spawnSync([name, ...args], {stdin: "ignore", stdout: "pipe", stderr: "pipe"});
      if (result.exitCode !== 0) throw new Error(name + " failed: " + new TextDecoder().decode(result.stderr));
      return JSON.parse(new TextDecoder().decode(result.stdout));
    }
    const expiry = new Date(Date.now() + 600000).toISOString();
    const makeWebhook = () => cli("create-webhook-cli", ["--label", "B07 callback", "--mode", "one_shot", "--expires-at", expiry]).webhook_endpoint;
    const endpoint = makeWebhook();
    const extra = makeWebhook();
    if (cli("list-webhooks-cli", []).webhook_endpoints.length !== 2) throw new Error("webhook list ownership mismatch");
    cli("cancel-webhook-cli", ["--id", extra.id]);
    await Bun.write("b07-webhook-url", endpoint.url);
    const {page_id} = await Bun.file('/workspace/b07-applet.json').json();
    const pod = (operation, params) => cli('ankole-pod', [operation, JSON.stringify(params)]);
    if (!pod('jobs.actions', {page_id}).includes('callback')) throw new Error('published Action missing');
    const makeAutomation = () => pod('jobs.create', {page_id, action_key:'callback', authorization_kind:'service', label:'B07 automation'});
    const automation = makeAutomation();
    const removed = makeAutomation();
    if (!pod('jobs.list', {page_id}).some(job => job.id === automation.id)) throw new Error('Applet Job list mismatch');
    pod('jobs.delete', {page_id, id:removed.id});
    if (pod('jobs.list', {page_id}).some(job => job.id === removed.id)) throw new Error('Applet Job deletion failed');
    console.log("B07_CLI_RESULT=" + JSON.stringify({endpoint_id: endpoint.id, cancelled_endpoint_id: extra.id, automation_id: automation.id, removed_automation_id: removed.id}));
    """

    command = "bun -e '" <> String.replace(script, "'", "'\"'\"'") <> "'"

    code =
      "const result = await tools.exec_command({cmd: #{Ankole.JSON.encode!(command)}, yield_time_ms: 30000}); text(result.output);"

    {:tool_call, %{id: "call_b07_job_cli", name: "exec", arguments: %{"input" => code}}}
  end

  def action_for(:b07_job, _count), do: {:completion, "B07_JOB_DONE", []}
  def action_for(:b07_wake, _count), do: {:completion, "B07_OWNER_RECEIVED", []}
  def action_for(_kind, _count), do: {:completion, "B07_ACKNOWLEDGED", []}
end
