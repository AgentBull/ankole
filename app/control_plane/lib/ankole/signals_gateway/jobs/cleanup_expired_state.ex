defmodule Ankole.SignalsGateway.Jobs.CleanupExpiredState do
  @moduledoc """
  Bounded recurring cleanup for SignalsGateway TTL state.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Ankole.SignalsGateway

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _counts = SignalsGateway.cleanup_expired_state()
    :ok
  end
end
