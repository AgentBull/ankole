defmodule Ankole.Signals.Types do
  @moduledoc """
  Code-defined Signal semantics. Each internally produced type declares whether
  it supersedes a pending reply interaction. Undeclared types, including external
  CloudEvents types, preserve pending interactions.
  """

  @supersedes %{
    "automation_job.emitted" => false,
    "automation_job.run_failed" => false,
    "background_agent_job.completed" => false,
    "background_agent_job.dispatch" => true,
    "background_agent_job.failed" => false,
    "background_agent_job.input_undeliverable" => false,
    "background_agent_job.waiting" => false,
    "check_back_later.wakeup" => false,
    "command.compress" => true,
    "command.llm" => true,
    "command.llm_help" => false,
    "command.new" => true,
    "command.retry" => true,
    "command.steer" => true,
    "command.stop" => true,
    "conversation.action_card.executed" => false,
    "conversation.message.removed" => false,
    "cron.fire" => false,
    "conversation.message.addressed" => true,
    "im.message.may_intervene" => true,
    "input.revised" => true,
    "pod.page_comment.addressed" => false,
    "signal.action.invoked" => true,
    "session.reset_due" => false,
    "webhook.received" => false,
    "workflow.run.attention" => false,
    "workflow.run.completed" => false,
    "workflow.run.failed" => false,
    "workflow.task.dispatch" => true,
    "workflow.task.message" => true,
    "workflow.task.wakeup" => true
  }

  @spec supersedes_pending_interaction?(term()) :: boolean()
  def supersedes_pending_interaction?(type), do: Map.get(@supersedes, type, false)

  @doc false
  def interaction_superseding_types do
    for {type, true} <- @supersedes, do: type
  end
end
