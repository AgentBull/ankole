defmodule Ankole.AIGateway.CodexModelToolConfig do
  @moduledoc """
  Validates Provider-owned Codex model tool configuration and resolves it by model slug.

  AIGateway keeps the rest of the Codex model card under its own ownership.
  Provider rows can change only fields that describe how the pinned Codex
  client encodes model-visible tools.
  """

  alias Ankole.AIGateway.ProviderConfigs.Provider

  @fields ~w(shell_type apply_patch_tool_type web_search_tool_type tool_mode)
  @shell_types ~w(default local unified_exec disabled shell_command)
  @apply_patch_tool_types [nil, "freeform"]
  @web_search_tool_types ~w(text text_and_image)
  @tool_modes [nil, "direct", "code_mode", "code_mode_only"]

  @doc "Validates the model-slug configuration map stored on one Provider connection."
  @spec validate_provider_configs(term()) :: :ok | {:error, term()}
  def validate_provider_configs(configs) when is_map(configs) do
    configs
    |> Enum.sort_by(fn {model, _value} -> model end)
    |> Enum.reduce_while(:ok, fn {model, value}, :ok ->
      case validate_entry(model, value) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:invalid_codex_model_tool_config, {model, reason}}}}
      end
    end)
  end

  def validate_provider_configs(_configs),
    do: {:error, {:invalid_codex_model_tool_config, :expected_model_map}}

  @doc "Returns the validated tool configuration for one Provider model."
  @spec for_model(Provider.t(), String.t()) :: map()
  def for_model(%Provider{connection_options: options}, model)
      when is_map(options) and is_binary(model) do
    options
    |> Map.get("codex_model_tool_configs", %{})
    |> case do
      configs when is_map(configs) -> Map.get(configs, model)
      _value -> nil
    end
    |> safe_config()
  end

  def for_model(_provider, _model), do: %{}

  @doc "Keeps one valid tool configuration and drops every invalid configuration."
  @spec safe_config(term()) :: map()
  def safe_config(config) when is_map(config) do
    case validate_config(config) do
      :ok -> Map.take(config, @fields)
      {:error, _reason} -> %{}
    end
  end

  def safe_config(_config), do: %{}

  defp validate_entry(model, config)
       when is_binary(model) and model != "" and byte_size(model) <= 256 and is_map(config),
       do: validate_config(config)

  defp validate_entry(model, _config) when not is_binary(model) or model == "",
    do: {:error, :invalid_model_slug}

  defp validate_entry(model, _config) when byte_size(model) > 256,
    do: {:error, :model_slug_too_long}

  defp validate_entry(_model, _config), do: {:error, :expected_config_map}

  defp validate_config(config) do
    unknown_fields =
      config
      |> Map.keys()
      |> Enum.reject(&(&1 in @fields))
      |> Enum.map(fn
        field when is_binary(field) -> field
        field -> inspect(field)
      end)
      |> Enum.sort()

    with [] <- unknown_fields,
         :ok <- validate_value(config, "shell_type", @shell_types),
         :ok <- validate_value(config, "apply_patch_tool_type", @apply_patch_tool_types),
         :ok <- validate_value(config, "web_search_tool_type", @web_search_tool_types),
         :ok <- validate_value(config, "tool_mode", @tool_modes) do
      :ok
    else
      [_field | _fields] = fields -> {:error, {:unknown_fields, fields}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_value(config, field, accepted) do
    case Map.fetch(config, field) do
      {:ok, value} ->
        if value in accepted,
          do: :ok,
          else: {:error, {:invalid_field, field, value}}

      :error ->
        :ok
    end
  end
end
