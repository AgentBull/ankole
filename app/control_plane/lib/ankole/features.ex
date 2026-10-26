defmodule Ankole.Features do
  @moduledoc "OpenFeature evaluation of declared features in the current request context."

  alias Ankole.Features.Config
  alias Ankole.Repo
  alias OpenFeature.Client

  def initialize, do: OpenFeature.set_provider(%Ankole.Features.Provider{})

  def boolean_value(key, context \\ %{}), do: evaluate_details(key, context).value
  def boolean_value_in_tx(key, context \\ %{}), do: evaluate_details_in_tx(key, context).value

  def evaluate_details(key, context \\ %{}), do: evaluate(key, context, :cached)
  def evaluate_details_in_tx(key, context \\ %{}), do: evaluate(key, context, :in_tx)

  def client_snapshot(context \\ %{}) do
    for {key, opts} <- Config.flags(),
        Keyword.get(opts, :client_visible, false),
        into: %{},
        do: {key, boolean_value(key, context)}
  end

  defp evaluate(key, context, mode) do
    if mode == :in_tx, do: :ok = Repo.require_transaction()

    context = Map.put_new(context, :targeting_key, Repo.tenant_id() || "site")

    details =
      OpenFeature.get_client()
      |> Client.get_boolean_details(key, false, context: Map.put(context, :mode, mode))

    case details.error_code do
      nil ->
        details

      :flag_not_found ->
        raise ArgumentError, "undeclared feature: #{key}"

      _error ->
        raise "feature evaluation failed for #{key}: #{details.error_message}"
    end
  end
end
