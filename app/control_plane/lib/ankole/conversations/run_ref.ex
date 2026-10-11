defmodule Ankole.Conversations.RunRef do
  @moduledoc "The Worker-side identity of an open conversation input. It carries no driver epoch."
  @enforce_keys [:agent_uid, :session_id, :actor_event_id]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}

  def from_proto(
        %Ankole.RuntimeFabric.V1.RunRef{actor: %{session_id: session}, actor_event_id: id},
        uid
      )
      when session != "" and id != "" do
    {:ok, %__MODULE__{agent_uid: uid, session_id: session, actor_event_id: id}}
  end

  def from_proto(_, _uid), do: {:error, :invalid_run_ref}
end
