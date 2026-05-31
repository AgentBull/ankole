defmodule BullX.Repo do
  @moduledoc """
  PostgreSQL repository for BullX durable facts.

  Business and runtime state that must survive BEAM restarts belongs behind
  this repo; process-local caches and workers are expected to be rebuildable
  from these tables.
  """

  use Ecto.Repo,
    otp_app: :bullx,
    adapter: Ecto.Adapters.Postgres
end
