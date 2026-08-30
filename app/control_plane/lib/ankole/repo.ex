defmodule Ankole.Repo do
  alias Ecto.Adapters.Postgres, as: PostgreSQLAdapter

  @moduledoc """
  Ecto repository for control-plane PostgreSQL state.
  """

  use Ecto.Repo,
    otp_app: :ankole,
    adapter: PostgreSQLAdapter

  @doc "Escapes PostgreSQL LIKE wildcard characters for a literal pattern fragment."
  @spec escape_like(String.t()) :: String.t()
  def escape_like(text) when is_binary(text) do
    String.replace(text, ~r/([\\%_])/, "\\\\\\1")
  end
end
