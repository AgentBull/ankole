defmodule BullX.AIAgent.Profile do
  @moduledoc """
  Casts and validates `agents.profile["ai_agent"]`.

  Principal storage only guarantees a JSON object. This module owns the
  AIAgent-specific runtime fields consumed before model calls, command handling,
  ambient policy, ToolSet expansion, and ACL checks.
  """

  alias BullX.LLM.ModelConfig

  @reasoning_efforts ModelConfig.reasoning_efforts()
  @conversation_isolation_modes [:scene, :actor]
  @ambient_modes [:observe_only, :may_intervene]
  @time_awareness_granularities [:minute, :hour, :day, :off]
  @access_tags [:ordinary, :privileged]

  @enforce_keys [:main_llm, :mission]
  defstruct [
    :main_llm,
    :compression_llm,
    :heavy_llm,
    :mission,
    ambient_intent_system_prompt: "",
    soul: "",
    instructions: "",
    conversation_isolation_mode: :scene,
    unmentioned_group_messages: :observe_only,
    daily_reset: %{
      enabled: true,
      hour: "04:00",
      timezone: "Etc/UTC",
      retry_minutes: 30
    },
    context: %{
      max_turns: 50,
      compression_threshold_ratio: 0.70,
      prompt_cache: true,
      time_awareness_granularity: :hour
    },
    acl: %{elevation_strategy: :deny},
    toolsets: %{},
    generation: %{
      generation_lease_ttl_ms: 600_000,
      generation_heartbeat_interval_ms: 30_000,
      generation_max_runtime_ms: 1_800_000
    }
  ]

  @type t :: %__MODULE__{}
  @type error :: {:invalid_profile, [String.t()]}

  @spec cast(map()) :: {:ok, t()} | {:error, error()}
  def cast(%{} = agent_profile) do
    case Map.get(agent_profile, "ai_agent") || Map.get(agent_profile, :ai_agent) do
      %{} = profile -> cast_ai_agent(profile)
      _missing -> {:error, {:invalid_profile, ["ai_agent profile is required"]}}
    end
  end

  def cast(_profile), do: {:error, {:invalid_profile, ["profile must be a JSON object"]}}

  @spec reasoning_efforts() :: [atom()]
  def reasoning_efforts, do: @reasoning_efforts

  @spec access_tags() :: [atom()]
  def access_tags, do: @access_tags

  defp cast_ai_agent(profile) do
    errors =
      []
      |> validate_model_config(profile, "main_llm", :required, :medium)
      |> validate_model_config(profile, "compression_llm", :optional, :low)
      |> validate_model_config(profile, "heavy_llm", :optional, :high)
      |> validate_required_string(profile, "mission")
      |> validate_optional_string(profile, "ambient_intent_system_prompt")
      |> validate_optional_string(profile, "soul")
      |> validate_optional_string(profile, "instructions")
      |> validate_in(profile, "conversation_isolation_mode", @conversation_isolation_modes)
      |> validate_in(profile, "unmentioned_group_messages", @ambient_modes)
      |> validate_daily_reset(profile)
      |> validate_context(profile)
      |> validate_acl(profile)
      |> validate_toolsets(profile)
      |> validate_generation(profile)

    case errors do
      [] -> {:ok, build(profile)}
      [_ | _] -> {:error, {:invalid_profile, Enum.reverse(errors)}}
    end
  end

  defp build(profile) do
    {:ok, main_llm} =
      profile
      |> config_value("main_llm")
      |> ModelConfig.cast(default_reasoning_effort: :medium)

    compression_llm =
      case config_value(profile, "compression_llm") do
        %{} = config ->
          {:ok, llm} = ModelConfig.cast(config, default_reasoning_effort: :low)
          llm

        _missing ->
          %{main_llm | reasoning_effort: :low}
      end

    heavy_llm =
      case config_value(profile, "heavy_llm") do
        %{} = config ->
          {:ok, llm} = ModelConfig.cast(config, default_reasoning_effort: :high)
          llm

        _missing ->
          %{main_llm | reasoning_effort: :high}
      end

    %__MODULE__{
      main_llm: main_llm,
      compression_llm: compression_llm,
      heavy_llm: heavy_llm,
      mission: string_value(profile, "mission", nil),
      ambient_intent_system_prompt: string_value(profile, "ambient_intent_system_prompt", ""),
      soul: string_value(profile, "soul", ""),
      instructions: string_value(profile, "instructions", ""),
      conversation_isolation_mode: atom_value(profile, "conversation_isolation_mode", :scene),
      unmentioned_group_messages:
        atom_value(profile, "unmentioned_group_messages", :observe_only),
      daily_reset: daily_reset(profile),
      context: context(profile),
      acl: acl(profile),
      toolsets: toolsets(profile),
      generation: generation(profile)
    }
  end

  defp validate_model_config(errors, profile, key, presence, default_reasoning_effort) do
    case {config_value(profile, key), presence} do
      {nil, :optional} ->
        errors

      {nil, :required} ->
        ["#{key} is required" | errors]

      {%{} = config, _presence} ->
        case ModelConfig.cast(config, default_reasoning_effort: default_reasoning_effort) do
          {:ok, _config} ->
            errors

          {:error, {:invalid_llm_config, config_errors}} ->
            prefixed = Enum.map(config_errors, &"#{key}.#{&1}")
            prefixed ++ errors
        end

      {_other, _presence} ->
        ["#{key} must be a JSON object" | errors]
    end
  end

  defp validate_optional_string(errors, profile, key) do
    case Map.get(profile, key) do
      nil -> errors
      value when is_binary(value) -> errors
      _other -> ["#{key} must be a string" | errors]
    end
  end

  defp validate_required_string(errors, profile, key) do
    case string_value(profile, key, nil) do
      value when is_binary(value) and value != "" -> errors
      _other -> ["#{key} is required" | errors]
    end
  end

  defp validate_in(errors, profile, key, choices) do
    profile
    |> atom_value(key, List.first(choices))
    |> then(fn value ->
      case Enum.member?(choices, value) do
        true -> errors
        false -> ["#{key} has unsupported value" | errors]
      end
    end)
  end

  defp validate_daily_reset(errors, profile) do
    daily_reset = map_value(profile, "daily_reset", %{})

    errors
    |> validate_boolean(daily_reset, "daily_reset.enabled")
    |> validate_hour(daily_reset)
    |> validate_timezone(daily_reset)
    |> validate_integer_range(daily_reset, "daily_reset.retry_minutes", 1, 720)
  end

  defp validate_context(errors, profile) do
    context = map_value(profile, "context", %{})

    errors
    |> validate_integer_range(context, "context.max_turns", 1, 200)
    |> validate_ratio(context)
    |> validate_boolean(context, "context.prompt_cache")
    |> validate_context_granularity(context)
  end

  defp validate_acl(errors, profile) do
    case Map.get(profile, "acl") do
      nil ->
        errors

      %{} = acl ->
        case string_value(acl, "elevation_strategy", "deny") do
          "deny" -> errors
          _other -> ["acl.elevation_strategy must be deny" | errors]
        end

      _other ->
        ["acl must be a JSON object" | errors]
    end
  end

  defp validate_toolsets(errors, profile) do
    case Map.get(profile, "toolsets", %{}) do
      %{} = toolsets ->
        toolsets
        |> Enum.reduce(errors, fn {toolset_id, config}, acc ->
          acc
          |> validate_toolset_id(toolset_id)
          |> validate_toolset_config(toolset_id, config)
        end)

      _other ->
        ["toolsets must be a JSON object" | errors]
    end
  end

  defp validate_generation(errors, profile) do
    generation = map_value(profile, "generation", %{})

    errors
    |> validate_positive_integer(generation, "generation.generation_lease_ttl_ms")
    |> validate_positive_integer(generation, "generation.generation_heartbeat_interval_ms")
    |> validate_positive_integer(generation, "generation.generation_max_runtime_ms")
    |> validate_heartbeat_ratio(generation)
  end

  defp validate_boolean(errors, map, dotted_key) do
    key = last_key(dotted_key)

    case Map.get(map, key) do
      nil -> errors
      value when is_boolean(value) -> errors
      _other -> ["#{dotted_key} must be boolean" | errors]
    end
  end

  defp validate_hour(errors, daily_reset) do
    case string_value(daily_reset, "hour", "04:00") do
      <<h1, h2, ?:, m1, m2>>
      when h1 in ?0..?2 and h2 in ?0..?9 and m1 in ?0..?5 and m2 in ?0..?9 ->
        hour = String.to_integer(<<h1, h2>>)

        case hour <= 23 do
          true -> errors
          false -> ["daily_reset.hour must use HH:MM" | errors]
        end

      _other ->
        ["daily_reset.hour must use HH:MM" | errors]
    end
  end

  defp validate_timezone(errors, daily_reset) do
    timezone = string_value(daily_reset, "timezone", "Etc/UTC")

    case valid_timezone_name?(timezone) do
      true -> errors
      false -> ["daily_reset.timezone must be an IANA timezone name" | errors]
    end
  end

  defp validate_integer_range(errors, map, dotted_key, min, max) do
    key = last_key(dotted_key)

    case Map.get(map, key) do
      nil -> errors
      value when is_integer(value) and value >= min and value <= max -> errors
      _other -> ["#{dotted_key} must be an integer in #{min}..#{max}" | errors]
    end
  end

  defp validate_positive_integer(errors, map, dotted_key) do
    key = last_key(dotted_key)

    case Map.get(map, key) do
      nil -> errors
      value when is_integer(value) and value > 0 -> errors
      _other -> ["#{dotted_key} must be a positive integer" | errors]
    end
  end

  defp validate_ratio(errors, context) do
    case Map.get(context, "compression_threshold_ratio") do
      nil -> errors
      value when is_number(value) and value > 0 and value < 1 -> errors
      _other -> ["context.compression_threshold_ratio must be > 0 and < 1" | errors]
    end
  end

  defp validate_context_granularity(errors, context) do
    case atom_value(context, "time_awareness_granularity", :hour) do
      value when value in @time_awareness_granularities -> errors
      _other -> ["context.time_awareness_granularity has unsupported value" | errors]
    end
  end

  defp validate_heartbeat_ratio(errors, generation) do
    ttl = Map.get(generation, "generation_lease_ttl_ms", 600_000)
    heartbeat = Map.get(generation, "generation_heartbeat_interval_ms", 30_000)

    case heartbeat <= div(ttl, 3) do
      true ->
        errors

      false ->
        ["generation.generation_heartbeat_interval_ms must be <= one third of lease ttl" | errors]
    end
  end

  defp validate_toolset_id(errors, toolset_id) when is_binary(toolset_id) and toolset_id != "",
    do: errors

  defp validate_toolset_id(errors, _toolset_id),
    do: ["toolset id must be a non-empty string" | errors]

  defp validate_toolset_config(errors, toolset_id, %{} = config) do
    errors
    |> validate_toolset_enabled(toolset_id, config)
    |> validate_toolset_supported_fields(toolset_id, config)
    |> validate_basic_enabled(toolset_id, config)
  end

  defp validate_toolset_config(errors, toolset_id, _config) do
    ["toolset #{toolset_id} config must be a JSON object" | errors]
  end

  defp validate_toolset_enabled(errors, toolset_id, config) do
    case fetch_config(config, "enabled") do
      {:ok, value} when is_boolean(value) ->
        errors

      {:ok, _value} ->
        ["toolset #{toolset_id}.enabled must be boolean" | errors]

      :error ->
        ["toolset #{toolset_id}.enabled is required" | errors]
    end
  end

  defp validate_toolset_supported_fields(errors, toolset_id, config) do
    config
    |> Map.keys()
    |> Enum.reject(&(&1 == "enabled" or &1 == :enabled))
    |> case do
      [] ->
        errors

      fields ->
        [
          "toolset #{toolset_id} has unsupported fields: #{Enum.map_join(fields, ", ", &to_string/1)}"
          | errors
        ]
    end
  end

  defp validate_basic_enabled(errors, toolset_id, config) when toolset_id in ["basic", :basic] do
    case fetch_config(config, "enabled") do
      {:ok, false} -> ["toolset basic cannot be disabled" | errors]
      _value -> errors
    end
  end

  defp validate_basic_enabled(errors, _toolset_id, _config), do: errors

  defp fetch_config(config, key) do
    case Map.fetch(config, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(config, String.to_existing_atom(key))
    end
  rescue
    ArgumentError -> :error
  end

  defp daily_reset(profile) do
    daily_reset = map_value(profile, "daily_reset", %{})

    %{
      enabled: Map.get(daily_reset, "enabled", true),
      hour: string_value(daily_reset, "hour", "04:00"),
      timezone: string_value(daily_reset, "timezone", "Etc/UTC"),
      retry_minutes: integer_value(daily_reset, "retry_minutes", 30)
    }
  end

  defp context(profile) do
    context = map_value(profile, "context", %{})

    %{
      max_turns: integer_value(context, "max_turns", 50),
      compression_threshold_ratio: number_value(context, "compression_threshold_ratio", 0.70),
      prompt_cache: Map.get(context, "prompt_cache", true),
      time_awareness_granularity: atom_value(context, "time_awareness_granularity", :hour)
    }
  end

  defp acl(profile) do
    acl = map_value(profile, "acl", %{})
    %{elevation_strategy: atom_value(acl, "elevation_strategy", :deny)}
  end

  defp toolsets(profile) do
    profile
    |> Map.get("toolsets", %{})
    |> Map.new(fn {toolset_id, config} ->
      {toolset_id,
       %{
         enabled: Map.get(config, "enabled", Map.get(config, :enabled))
       }}
    end)
  end

  defp generation(profile) do
    generation = map_value(profile, "generation", %{})

    %{
      generation_lease_ttl_ms: integer_value(generation, "generation_lease_ttl_ms", 600_000),
      generation_heartbeat_interval_ms:
        integer_value(generation, "generation_heartbeat_interval_ms", 30_000),
      generation_max_runtime_ms: integer_value(generation, "generation_max_runtime_ms", 1_800_000)
    }
  end

  defp map_value(map, key, default) do
    case config_value(map, key) do
      %{} = value -> value
      _other -> default
    end
  end

  defp string_value(map, key, default) do
    case config_value(map, key) do
      value when is_binary(value) -> value
      _other -> default
    end
  end

  defp integer_value(map, key, default) do
    case config_value(map, key) do
      value when is_integer(value) -> value
      _other -> default
    end
  end

  defp number_value(map, key, default) do
    case config_value(map, key) do
      value when is_number(value) -> value
      _other -> default
    end
  end

  defp atom_value(map, key, default) do
    case config_value(map, key) do
      nil -> default
      value -> normalize_atom(value)
    end
  end

  defp config_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp normalize_atom(value) when is_atom(value), do: value

  defp normalize_atom(value) when is_binary(value) do
    cond do
      value in Enum.map(@reasoning_efforts, &Atom.to_string/1) ->
        String.to_existing_atom(value)

      value in Enum.map(@conversation_isolation_modes, &Atom.to_string/1) ->
        String.to_existing_atom(value)

      value in Enum.map(@ambient_modes, &Atom.to_string/1) ->
        String.to_existing_atom(value)

      value in Enum.map(@time_awareness_granularities, &Atom.to_string/1) ->
        String.to_existing_atom(value)

      value in Enum.map(@access_tags, &Atom.to_string/1) ->
        String.to_existing_atom(value)

      value == "deny" ->
        :deny

      true ->
        value
    end
  end

  defp normalize_atom(value), do: value

  defp valid_timezone_name?(timezone), do: BullX.AIAgent.Time.valid_timezone?(timezone)

  defp last_key(dotted_key) do
    dotted_key
    |> String.split(".")
    |> List.last()
  end
end
