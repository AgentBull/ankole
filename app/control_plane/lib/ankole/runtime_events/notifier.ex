defmodule Ankole.RuntimeEvents.Notifier do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias Ankole.JSON

  @spec notify_in_tx(module(), String.t(), map()) :: :ok | {:error, term()}
  def notify_in_tx(repo, channel, payload)
      when is_atom(repo) and is_binary(channel) and is_map(payload) do
    with {:ok, encoded} <- JSON.encode(payload),
         {:ok, _result} <- SQL.query(repo, "SELECT pg_notify($1, $2)", [channel, encoded]) do
      :ok
    end
  end
end
