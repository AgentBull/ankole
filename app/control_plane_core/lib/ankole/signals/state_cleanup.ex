defmodule Ankole.Signals.StateCleanup do
  @moduledoc false

  alias Ankole.Conversations.InputTombstone
  alias Ankole.Signals.Webhooks

  @spec cleanup_expired_state(DateTime.t()) :: %{
          tombstones: non_neg_integer(),
          webhook_endpoints: non_neg_integer()
        }
  def cleanup_expired_state(now \\ DateTime.utc_now(:microsecond)) do
    result =
      InputTombstone
      |> Ankole.Ash.bulk_destroy(:expire, %{now: now},
        strategy: [:atomic],
        return_records?: true,
        return_errors?: true
      )

    tombstones =
      case result do
        %Ash.BulkResult{status: :success, records: records} -> length(records)
        %Ash.BulkResult{errors: errors} -> raise Ash.Error.to_error_class(errors)
      end

    %{tombstones: tombstones, webhook_endpoints: Webhooks.expire_due(now)}
  end
end
