defmodule BullX.Principals.AgentProfiles.AgenticLoop do
  @moduledoc false

  @required_fields ~w(main_llm goals soul)
  @optional_fields ~w(compression_llm heavy_llm)
  @profile_fields @required_fields ++ @optional_fields

  @spec cast(map()) :: {:ok, map()} | {:error, [atom()]}
  def cast(profile) when is_map(profile) do
    normalized = stringify_top_level_keys(profile)

    missing =
      @required_fields
      |> Enum.reject(&present_string?(Map.get(normalized, &1)))
      |> Enum.map(&String.to_atom/1)

    invalid =
      @optional_fields
      |> Enum.filter(&invalid_optional_string?(Map.get(normalized, &1)))
      |> Enum.map(&String.to_atom/1)

    case missing ++ invalid do
      [] -> {:ok, normalize_strings(normalized)}
      errors -> {:error, errors}
    end
  end

  def cast(_profile), do: {:error, [:profile]}

  @spec main_llm(map()) :: String.t() | nil
  def main_llm(profile), do: Map.get(profile || %{}, "main_llm")

  @spec compression_llm(map()) :: String.t() | nil
  def compression_llm(profile),
    do: Map.get(profile || %{}, "compression_llm") || main_llm(profile)

  @spec heavy_llm(map()) :: String.t() | nil
  def heavy_llm(profile), do: Map.get(profile || %{}, "heavy_llm") || main_llm(profile)

  defp stringify_top_level_keys(profile) do
    Map.new(profile, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp normalize_strings(profile) do
    Map.new(profile, fn
      {key, value} when key in @profile_fields and is_binary(value) ->
        {key, String.trim(value)}

      pair ->
        pair
    end)
  end

  defp invalid_optional_string?(nil), do: false
  defp invalid_optional_string?(value), do: not present_string?(value)

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
end
