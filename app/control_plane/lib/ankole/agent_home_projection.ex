defmodule Ankole.AgentHomeProjection do
  @moduledoc """
  Rebuilds the uppercase Agent Home document files from PostgreSQL.

  The projection is one-way and rebuildable. Worker-side turn preparation is
  the final synchronization barrier before model execution.
  """

  alias Ankole.AgentHomePaths
  alias Ankole.AIAgent.Library
  alias Ankole.Principals
  alias Ankole.WorkerFiles

  @kinds ~w(soul mission design)

  @spec runtime_event_snapshot() :: [{String.t(), map()}]
  def runtime_event_snapshot do
    Enum.map(Principals.list_active_agents(), fn %{principal: principal} ->
      {Ankole.RuntimeEvents.agent_home_projection_channel(), %{"agent_uid" => principal.uid}}
    end)
  end

  @spec sync(String.t()) :: :ok | {:error, term()}
  def sync(agent_uid) do
    with :ok <- AgentHomePaths.validate_agent_uid(agent_uid),
         {:ok, documents} <- Library.list_agent_documents(agent_uid) do
      Enum.reduce_while(@kinds, :ok, fn kind, :ok ->
        content = get_in(documents, [kind, "content"]) || ""
        path = AgentHomePaths.document_lane_path(agent_uid, kind)

        case WorkerFiles.put_internal("agent_home_documents", path, content) do
          {:ok, _result} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end
end
