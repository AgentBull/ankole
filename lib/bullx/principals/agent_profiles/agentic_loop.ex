defmodule BullX.Principals.AgentProfiles.AgenticLoop do
  @moduledoc false

  @required_string_fields ~w(main_llm goals soul)
  @optional_string_fields ~w(compression_llm heavy_llm daily_reset_hour)
  @integer_fields ~w(context_window_tokens protected_head_messages protected_tail_min_messages daily_reset_retry_minutes)
  @ratio_fields ~w(compression_threshold_ratio protected_tail_token_ratio)
  @boolean_fields ~w(listen_all_group_messages)
  @map_fields ~w(prompt_caching)
  @string_fields @required_string_fields ++ @optional_string_fields

  @defaults %{
    "context_window_tokens" => 128_000,
    "compression_threshold_ratio" => 0.75,
    "protected_head_messages" => 2,
    "protected_tail_token_ratio" => 0.5,
    "protected_tail_min_messages" => 4,
    "listen_all_group_messages" => false,
    "daily_reset_hour" => "04:00",
    "daily_reset_retry_minutes" => 30,
    "prompt_caching" => %{"enabled" => false, "strategy" => "system_and_3"}
  }

  @spec cast(map()) :: {:ok, map()} | {:error, [atom()]}
  def cast(profile) when is_map(profile) do
    normalized = stringify_top_level_keys(profile)

    missing =
      @required_string_fields
      |> Enum.reject(&present_string?(Map.get(normalized, &1)))
      |> Enum.map(&String.to_atom/1)

    invalid = invalid_fields(normalized)

    case missing ++ invalid do
      [] -> {:ok, normalize_strings(normalized)}
      errors -> {:error, errors}
    end
  end

  def cast(_profile), do: {:error, [:profile]}

  @spec defaults() :: map()
  def defaults, do: @defaults

  @spec effective(map()) :: {:ok, map()} | {:error, [atom()]}
  def effective(profile) when is_map(profile) do
    with {:ok, normalized} <- cast(profile) do
      {:ok, Map.merge(defaults(), normalized)}
    end
  end

  def effective(_profile), do: {:error, [:profile]}

  @spec main_llm(map()) :: String.t() | nil
  def main_llm(profile), do: Map.get(profile || %{}, "main_llm")

  @spec compression_llm(map()) :: String.t() | nil
  def compression_llm(profile),
    do: Map.get(profile || %{}, "compression_llm") || main_llm(profile)

  @spec heavy_llm(map()) :: String.t() | nil
  def heavy_llm(profile), do: Map.get(profile || %{}, "heavy_llm") || main_llm(profile)

  @spec listen_all_group_messages?(map()) :: boolean()
  def listen_all_group_messages?(profile) do
    case effective(profile || %{}) do
      {:ok, effective} -> effective["listen_all_group_messages"] == true
      {:error, _reason} -> false
    end
  end

  defp stringify_top_level_keys(profile) do
    Map.new(profile, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp normalize_strings(profile) do
    Map.new(profile, fn
      {key, value} when key in @string_fields and is_binary(value) ->
        {key, String.trim(value)}

      pair ->
        pair
    end)
  end

  defp invalid_fields(profile) do
    [
      invalid_optional_strings(profile),
      invalid_integers(profile),
      invalid_ratios(profile),
      invalid_booleans(profile),
      invalid_maps(profile),
      invalid_daily_reset_hour(profile),
      invalid_prompt_caching(profile)
    ]
    |> List.flatten()
  end

  defp invalid_optional_strings(profile) do
    @optional_string_fields
    |> Enum.filter(&invalid_optional_string?(Map.get(profile, &1)))
    |> Enum.map(&String.to_atom/1)
  end

  defp invalid_integers(profile) do
    @integer_fields
    |> Enum.filter(&invalid_non_negative_integer?(Map.get(profile, &1)))
    |> Enum.map(&String.to_atom/1)
  end

  defp invalid_ratios(profile) do
    @ratio_fields
    |> Enum.filter(&invalid_ratio?(Map.get(profile, &1)))
    |> Enum.map(&String.to_atom/1)
  end

  defp invalid_booleans(profile) do
    @boolean_fields
    |> Enum.filter(&invalid_boolean?(Map.get(profile, &1)))
    |> Enum.map(&String.to_atom/1)
  end

  defp invalid_maps(profile) do
    @map_fields
    |> Enum.filter(&invalid_map?(Map.get(profile, &1)))
    |> Enum.map(&String.to_atom/1)
  end

  defp invalid_daily_reset_hour(profile) do
    case Map.get(profile, "daily_reset_hour") do
      nil -> []
      value -> if valid_hour?(value), do: [], else: [:daily_reset_hour]
    end
  end

  defp invalid_prompt_caching(profile) do
    case Map.get(profile, "prompt_caching") do
      nil -> []
      %{} = value -> if valid_prompt_caching?(value), do: [], else: [:prompt_caching]
      _value -> [:prompt_caching]
    end
  end

  defp invalid_optional_string?(nil), do: false
  defp invalid_optional_string?(value), do: not present_string?(value)

  defp invalid_non_negative_integer?(nil), do: false
  defp invalid_non_negative_integer?(value), do: not (is_integer(value) and value >= 0)

  defp invalid_ratio?(nil), do: false
  defp invalid_ratio?(value), do: not (is_number(value) and value > 0 and value <= 1)

  defp invalid_boolean?(nil), do: false
  defp invalid_boolean?(value), do: not is_boolean(value)

  defp invalid_map?(nil), do: false
  defp invalid_map?(value), do: not is_map(value)

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp valid_hour?(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [hour, minute] -> valid_hour_part?(hour) and valid_minute_part?(minute)
      _other -> false
    end
  end

  defp valid_hour?(_value), do: false

  defp valid_hour_part?(value) do
    case Integer.parse(value) do
      {hour, ""} -> hour in 0..23 and String.length(value) == 2
      _other -> false
    end
  end

  defp valid_minute_part?(value) do
    case Integer.parse(value) do
      {minute, ""} -> minute in 0..59 and String.length(value) == 2
      _other -> false
    end
  end

  defp valid_prompt_caching?(value) do
    case stringify_top_level_keys(value) do
      %{"enabled" => enabled} when not is_boolean(enabled) ->
        false

      %{"ttl_seconds" => ttl} when not (is_integer(ttl) and ttl > 0) ->
        false

      %{"strategy" => strategy} when not (is_binary(strategy) and strategy != "") ->
        false

      value ->
        Enum.all?(Map.keys(value), &(&1 in ~w(enabled ttl_seconds strategy)))
    end
  end
end
