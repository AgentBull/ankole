defmodule Ankole.E2E.FakeOpenAILongLivedOwnerScenarios do
  @moduledoc "Model commands for real Job CLI ownership and later callback delivery."

  def classify(request, prompt) do
    native? = Enum.any?(request["tools"] || [], &(get_in(&1, ["function", "name"]) == "exec"))

    cond do
      String.contains?(prompt, "CHAOS_B07_WAKE") -> :b07_wake
      native? and String.contains?(prompt, "CHAOS_B07_JOB") -> :b07_job
      String.contains?(prompt, "CHAOS_B07_CREATE") -> :b07_create
      String.contains?(prompt, "CHAOS_B07_JOB") -> :b07_notice
      true -> nil
    end
  end

  def action_for(:b07_create, 1) do
    {:tool_call,
     %{
       id: "call_b07_create",
       name: "create_background_job",
       arguments: %{
         "title" => "Persistent callback ownership",
         "task" =>
           "CHAOS_B07_JOB Register webhook and automation callbacks for the originating conversation."
       }
     }}
  end

  def action_for(:b07_job, 1) do
    script = ~S"""
    const { mkdir } = await import("node:fs/promises");
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
    await mkdir("b07-automation", {recursive: true});
    await Bun.write("b07-automation/main.ts", 'await emitEvent({marker: "CHAOS_B07_WAKE", path: "automation"});\n');
    const makeAutomation = () => cli("create-automation-job-cli", ["--dir", "b07-automation", "--label", "B07 automation", "--wake-on-failure"]).automation_job;
    const automation = makeAutomation();
    const cancelled = makeAutomation();
    if (!cli("list-automation-jobs-cli", []).automation_jobs.some(job => job.id === automation.id)) throw new Error("automation list ownership mismatch");
    const detail = cli("show-automation-job-cli", ["--id", String(automation.id)]).result;
    if (detail.automation_job.id !== automation.id) throw new Error("automation show ownership mismatch");
    cli("cancel-automation-job-cli", ["--id", String(cancelled.id)]);
    console.log("B07_CLI_RESULT=" + JSON.stringify({endpoint_id: endpoint.id, cancelled_endpoint_id: extra.id, automation_id: automation.id, cancelled_automation_id: cancelled.id}));
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
