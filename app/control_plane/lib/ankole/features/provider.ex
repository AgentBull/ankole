defmodule Ankole.Features.Provider do
  @moduledoc "OpenFeature provider for global AppConfigure feature policies."
  @behaviour OpenFeature.Provider

  alias Ankole.AppConfigure
  alias OpenFeature.ResolutionDetails

  defstruct name: "Ankole", state: :ready, hooks: []

  @impl true
  def initialize(provider, _domain, _context), do: {:ok, provider}
  @impl true
  def shutdown(_provider), do: :ok

  @impl true
  def resolve_boolean_value(_provider, key, _default, context) do
    read =
      if Map.get(context, :mode, :cached) == :in_tx,
        do: &AppConfigure.get_by_key_in_tx/1,
        else: &AppConfigure.get_by_key/1

    case read.("features." <> key) do
      {:ok, policy} ->
        {value, reason} = policy_value(key, policy, Map.get(context, :targeting_key, "site"))
        details(value, reason)

      {:error, {:unknown_key, _key}} ->
        {:error, :flag_not_found}

      {:error, reason} ->
        {:error, :unexpected_error, RuntimeError.exception(inspect(reason))}
    end
  end

  @impl true
  def resolve_string_value(_provider, _key, _default, _context), do: {:error, :flag_not_found}
  @impl true
  def resolve_number_value(_provider, _key, _default, _context), do: {:error, :flag_not_found}
  @impl true
  def resolve_map_value(_provider, _key, _default, _context), do: {:error, :flag_not_found}

  defp policy_value(_key, %{"enabled" => false}, _target), do: {false, :disabled}

  defp policy_value(key, policy, target) do
    case Map.fetch(policy["targets"], target) do
      {:ok, value} -> {value, :targeting_match}
      :error -> {bucket(key, target) < policy["percent"], :split}
    end
  end

  defp bucket(key, target) do
    <<number::unsigned-big-64, _rest::binary>> = :crypto.hash(:sha256, key <> ":" <> target)
    rem(number, 100)
  end

  defp details(value, reason) do
    {:ok,
     %ResolutionDetails{
       value: value,
       reason: reason,
       variant: to_string(value)
     }}
  end
end
