defmodule Ankole.Signals.StateCleanup do
  @moduledoc false

  alias Ankole.Signals.Webhooks

  @spec cleanup_expired_state(DateTime.t()) :: %{
          tombstones: non_neg_integer(),
          webhook_endpoints: non_neg_integer()
        }
  def cleanup_expired_state(now \\ DateTime.utc_now(:microsecond)) do
    tombstones =
      case Ankole.Conversations.expire_input_tombstones(now) do
        {:ok, count} -> count
        {:error, error} -> raise error
      end

    %{tombstones: tombstones, webhook_endpoints: Webhooks.expire_due(now)}
  end
end
