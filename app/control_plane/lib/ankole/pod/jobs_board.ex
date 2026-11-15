defmodule Ankole.Pod.JobsBoard do
  @moduledoc """
  Projects and controls a Pod member's asynchronous Jobs board (`/jobs`).

  `Ankole.Pod.JobsBoard.Queries` projects one-off Background Agent Jobs and
  Workflows alongside living routines (Agent Cron Schedules, Page Automation
  Jobs, and pending checkbacks) directly from their owning domains.
  `Ankole.Pod.JobsBoard.Operations` creates new Background Agent Jobs and Cron
  Schedules and controls existing routines and executions.
  """

  alias Ankole.Pod.JobsBoard.{Operations, Queries}

  defdelegate summary(actor), to: Queries
  defdelegate list(actor), to: Queries
  defdelegate routine_detail(actor, kind, raw_id), to: Queries
  defdelegate execution_detail(actor, kind, run_id, cursor \\ nil), to: Queries

  defdelegate create(actor, attrs), to: Operations
  defdelegate change_routine(actor, kind, raw_id, action), to: Operations
  defdelegate stop_execution(actor, kind, run_id), to: Operations
  defdelegate message_execution(actor, run_id, request_id, text), to: Operations
end
