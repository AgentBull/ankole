defmodule Ankole.SignalsGateway.StateCleanup do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.Repo
  alias Ankole.SignalsGateway.InputTombstone
  alias Ankole.SignalsGateway.Webhooks

  @spec cleanup_expired_state(DateTime.t()) :: %{
          tombstones: non_neg_integer(),
          webhook_endpoints: non_neg_integer()
        }
  def cleanup_expired_state(now \\ DateTime.utc_now(:microsecond)) do
    {tombstones, _} =
      InputTombstone
      |> where([tombstone], tombstone.tombstoned_until <= ^now)
      |> Repo.delete_all()

    %{tombstones: tombstones, webhook_endpoints: Webhooks.expire_due(now)}
  end
end
