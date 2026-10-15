defmodule Ankole.WorkFixtures do
  @moduledoc false

  def service_source(agent_uid) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now(:microsecond)

    {:ok, event} =
      Ankole.Repo.transact(fn repo ->
        with {:ok, event} <-
               Ankole.Signals.accept_in_tx(repo, %{
                 source: "test://work",
                 id: id,
                 type: "test.work",
                 time: now,
                 target: %{agent_uid: agent_uid, session_id: "test:work:#{id}"},
                 sender: agent_uid,
                 authorization: Ankole.Principals.WorkAccess.service(),
                 data: %{}
               }) do
          Ankole.Sessions.Queue.mark_event_completed_in_tx(repo, event, now)
        end
      end)

    event
  end
end
