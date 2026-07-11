defmodule Ankole.Repo do
  alias Ecto.Adapters.Postgres, as: PostgreSQLAdapter

  @moduledoc """
  Ecto repository for control-plane PostgreSQL state.
  """

  use Ecto.Repo,
    otp_app: :ankole,
    adapter: PostgreSQLAdapter
end
