defmodule Ankole.AgentWorkers.Changes.AdmitConnection do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    worker = changeset.data
    generation = Ash.Changeset.get_argument(changeset, :generation)
    incarnation = Ash.Changeset.get_attribute(changeset, :incarnation_id)

    reason =
      cond do
        worker.generation != generation -> :stale_worker_generation
        worker.protocol_version != Ankole.RuntimeFabric.protocol_version() -> :protocol_mismatch
        true -> nil
      end

    if reason do
      Ash.Changeset.add_error(changeset, Ankole.Ash.DomainError.exception(reason: reason))
    else
      Ash.Changeset.filter(
        changeset,
        expr(
          is_nil(incarnation_id) or incarnation_id == ^incarnation or
            is_nil(transport_route) or is_nil(last_worker_heartbeat_at) or
            last_worker_heartbeat_at <= fragment("clock_timestamp() - interval '60 seconds'")
        )
      )
    end
  end
end
