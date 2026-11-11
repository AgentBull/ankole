defmodule Ankole.Issues do
  @moduledoc """
  Owns Issues: the Background Agent work that a person hands to an Agent,
  follows, and accepts.

  An Issue is the work-item record of one native conversation. The conversation
  holds the title, the discussion, and the Agent's Session, so the Background
  Agent Jobs and Workflows that the Agent starts in the room are the Issue's
  runs. `Ankole.Issues.Operations` owns the writes, and `Ankole.Issues.Queries`
  owns the reads and the public form.

  Each top-level write operation owns its transaction and must be the top-level
  call. It gives `{:ok, value}` or `{:error, reason}`.
  """

  use Ankole.Ash.Domain

  resources do
    resource(Ankole.Issues.Browser)
    resource(Ankole.Issues.Issue)
  end

  defdelegate create(actor, attrs), to: Ankole.Issues.Operations
  defdelegate update(actor, id, attrs), to: Ankole.Issues.Operations

  defdelegate ensure_for_task_room_in_tx(agent_uid, owner_session_id),
    to: Ankole.Issues.Operations

  defdelegate get(actor, id), to: Ankole.Issues.Queries
  defdelegate list(actor), to: Ankole.Issues.Queries
  defdelegate scheduled(actor), to: Ankole.Issues.Activity
end
