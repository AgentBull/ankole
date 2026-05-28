defmodule BullX.LLM.ModelConfig do
  @moduledoc """
  Canonical model-call configuration stored by BullX runtime profiles.

  `provider_id` identifies a local BullX provider row. `model` is the provider
  model id sent to the underlying `req_llm` adapter. Generation controls live
  with the model selection because they are call-profile choices, not endpoint
  credentials.
  """

  @reasoning_efforts [:none, :minimal, :low, :medium, :high, :xhigh]
  @default_context_window 80_000
  @min_max_completion_tokens 200

  @enforce_keys [:provider_id, :model]
  defstruct [
    :provider_id,
    :model,
    reasoning_effort: :medium,
    context_window: nil,
    max_completion_tokens: nil
  ]

  @type t :: %__MODULE__{
          provider_id: String.t(),
          model: String.t(),
          reasoning_effort: atom(),
          context_window: pos_integer() | nil,
          max_completion_tokens: pos_integer() | nil
        }

  @type error :: {:invalid_llm_config, [String.t()]}

  @spec reasoning_efforts() :: [atom()]
  def reasoning_efforts, do: @reasoning_efforts

  @spec default_context_window() :: pos_integer()
  def default_context_window, do: @default_context_window

  @spec min_max_completion_tokens() :: pos_integer()
  def min_max_completion_tokens, do: @min_max_completion_tokens

  @spec cast(map(), keyword()) :: {:ok, t()} | {:error, error()}
  def cast(attrs, opts \\ [])

  def cast(%{} = attrs, opts) do
    errors =
      []
      |> require_string(attrs, "provider_id")
      |> require_string(attrs, "model")
      |> validate_reasoning_effort(attrs)
      |> validate_optional_positive_integer(attrs, "context_window")
      |> validate_max_completion_tokens(attrs)

    case errors do
      [] -> {:ok, build(attrs, opts)}
      [_ | _] -> {:error, {:invalid_llm_config, Enum.reverse(errors)}}
    end
  end

  def cast(_attrs, _opts), do: {:error, {:invalid_llm_config, ["llm config must be an object"]}}

  @spec profile_map(t()) :: map()
  def profile_map(%__MODULE__{} = config) do
    %{
      "provider_id" => config.provider_id,
      "model" => config.model,
      "reasoning_effort" => Atom.to_string(config.reasoning_effort)
    }
    |> maybe_put("context_window", config.context_window)
    |> maybe_put("max_completion_tokens", config.max_completion_tokens)
  end

  @spec call_opts(t()) :: keyword()
  def call_opts(%__MODULE__{} = config) do
    [reasoning_effort: config.reasoning_effort]
    |> maybe_keyword_put(:max_tokens, config.max_completion_tokens)
  end

  @spec effective_context_window(t(), pos_integer() | nil) :: pos_integer()
  def effective_context_window(%__MODULE__{} = config, descriptor_context_window \\ nil) do
    config.context_window || descriptor_context_window || @default_context_window
  end

  defp build(attrs, opts) do
    %__MODULE__{
      provider_id: string_value(attrs, "provider_id"),
      model: string_value(attrs, "model"),
      reasoning_effort:
        atom_value(
          attrs,
          "reasoning_effort",
          Keyword.get(opts, :default_reasoning_effort, :medium)
        ),
      context_window: integer_value(attrs, "context_window"),
      max_completion_tokens: integer_value(attrs, "max_completion_tokens")
    }
  end

  defp require_string(errors, attrs, key) do
    case string_value(attrs, key) do
      value when is_binary(value) and value != "" -> errors
      _other -> ["#{key} is required" | errors]
    end
  end

  defp validate_reasoning_effort(errors, attrs) do
    case get_known(attrs, "reasoning_effort") do
      nil ->
        errors

      value when value in @reasoning_efforts ->
        errors

      value when is_binary(value) ->
        case value in Enum.map(@reasoning_efforts, &Atom.to_string/1) do
          true -> errors
          false -> ["reasoning_effort has unsupported value" | errors]
        end

      _other ->
        ["reasoning_effort has unsupported value" | errors]
    end
  end

  defp validate_max_completion_tokens(errors, attrs) do
    validate_optional_min_integer(
      errors,
      attrs,
      "max_completion_tokens",
      @min_max_completion_tokens
    )
  end

  defp validate_optional_positive_integer(errors, attrs, key) do
    case get_known(attrs, key) do
      nil -> errors
      "" -> errors
      value when is_integer(value) and value > 0 -> errors
      value when is_binary(value) -> validate_integer_string(errors, key, value)
      _other -> ["#{key} must be a positive integer" | errors]
    end
  end

  defp validate_integer_string(errors, key, value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> errors
      _other -> ["#{key} must be a positive integer" | errors]
    end
  end

  defp validate_optional_min_integer(errors, attrs, key, min) do
    case get_known(attrs, key) do
      nil -> errors
      "" -> errors
      value when is_integer(value) and value >= min -> errors
      value when is_binary(value) -> validate_min_integer_string(errors, key, value, min)
      _other -> ["#{key} must be at least #{min}" | errors]
    end
  end

  defp validate_min_integer_string(errors, key, value, min) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer >= min -> errors
      _other -> ["#{key} must be at least #{min}" | errors]
    end
  end

  defp string_value(attrs, key) do
    value = get_known(attrs, key)

    case value do
      value when is_binary(value) -> String.trim(value)
      _other -> nil
    end
  end

  defp integer_value(attrs, key) do
    case get_known(attrs, key) do
      value when is_integer(value) and value > 0 -> value
      value when is_binary(value) -> parsed_integer(value)
      _other -> nil
    end
  end

  defp parsed_integer(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> integer
      _other -> nil
    end
  end

  defp atom_value(attrs, key, default) do
    case get_known(attrs, key) do
      value when value in @reasoning_efforts ->
        value

      value when is_binary(value) ->
        Enum.find(@reasoning_efforts, default, &(Atom.to_string(&1) == value))

      _other ->
        default
    end
  end

  defp get_known(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, atom_key(key))

  defp atom_key("provider_id"), do: :provider_id
  defp atom_key("model"), do: :model
  defp atom_key("reasoning_effort"), do: :reasoning_effort
  defp atom_key("context_window"), do: :context_window
  defp atom_key("max_completion_tokens"), do: :max_completion_tokens

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_keyword_put(keyword, _key, nil), do: keyword
  defp maybe_keyword_put(keyword, key, value), do: Keyword.put(keyword, key, value)
end
