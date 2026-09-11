defmodule Ankole.WorkFixtures do
  @moduledoc false

  def service_source(agent_uid) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    {:ok, event} =
      Ankole.SignalsGateway.append_actor_event(%{
        agent_uid: agent_uid,
        sender_key: agent_uid,
        binding_name: "test:work",
        session_id: "test:work:#{id}",
        source_event_id: id,
        type: "test.work",
        available_at: now,
        completed_at: now,
        payload: %{}
      })

    event
  end
end
