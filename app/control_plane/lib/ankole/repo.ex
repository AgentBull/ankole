defmodule Ankole.Repo do
  @moduledoc """
  Ecto repository for control-plane PostgreSQL state.
  """

  use Ecto.Repo,
    otp_app: :ankole,
    adapter: Ecto.Adapters.Postgres
end
