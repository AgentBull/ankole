defmodule Ankole.AIGateway.ReasoningEffort do
  @moduledoc """
  Normalizes the public `reasoningEffort` option before provider request build.

  Ankole uses OpenAI's effort names as the public contract. Providers that do
  not accept the full OpenAI set pass a small value map from their own module.
  The packaged model metadata decides the rest: a model that is known to accept
  effort gets `high` when nothing chooses a value, a value outside the levels of
  the model is rejected before the request leaves, and a model that is known not
  to reason gets no effort, because upstreams reject it. A model without
  metadata gets only an explicitly chosen value.
  """

  alias Ankole.Attrs
  alias Ankole.AIGateway.ModelMetadata
  alias Ankole.AIGateway.UniversalAIRequest

  @openai_values ~w(none minimal low medium high xhigh max ultra)
  @native_keys ~w(reasoning reasoning_effort output_config)
  @default_effort "high"

  @typedoc "Provider-native location for the aligned reasoning effort value."
  @type target :: :reasoning | :reasoning_effort | :output_config

  @doc "Returns the canonical values accepted by Ankole, optionally narrowed by a provider map."
  @spec values(map() | nil) :: [String.t()]
  def values(map \\ nil)
  def values(nil), do: @openai_values
  def values(map) when is_map(map), do: Enum.filter(@openai_values, &Map.has_key?(map, &1))

  @doc """
  Normalizes one public OpenAI-style reasoning effort value. A missing value
  stays missing.
  """
  @spec normalize(term()) :: {:ok, String.t() | nil} | {:error, term()}
  def normalize(nil), do: {:ok, nil}
  def normalize(value) when is_atom(value), do: value |> Atom.to_string() |> normalize()

  def normalize(value) when is_binary(value) do
    effort = value |> String.trim() |> String.downcase()

    case effort in @openai_values do
      true -> {:ok, effort}
      false -> {:error, {:reasoning_effort, {:invalid, value, @openai_values}}}
    end
  end

  def normalize(value), do: {:error, {:reasoning_effort, {:invalid, value, @openai_values}}}

  @doc """
  Applies normalized reasoning effort to a prepared UniversalAIClient request.

  Each provider must name its native target explicitly. There is no native-key
  escape path: request profiles expose only `reasoningEffort`, and this module
  owns its value normalization and provider wire shape.
  """
  @spec put_provider_options(UniversalAIRequest.t(), map(), keyword()) ::
          UniversalAIRequest.t() | {:error, term()}
  def put_provider_options(%UniversalAIRequest{} = request, ctx, opts) when is_map(ctx) do
    with {:ok, provider_options} <- provider_options(ctx, opts) do
      UniversalAIRequest.put_provider_options(request, provider_options)
    end
  end

  @doc """
  Returns provider options with `reasoningEffort` normalized and mapped.
  """
  @spec provider_options(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def provider_options(ctx, opts) when is_map(ctx) do
    options = ctx |> Map.get(:provider_options, %{}) |> Attrs.normalize_external_attrs()
    public_value = request_effort(ctx) || Map.get(options, "reasoningEffort")
    target = Keyword.fetch!(opts, :target)
    map = Keyword.get(opts, :map)
    support = model_support(Map.get(ctx, :runtime), target)

    with {:ok, effort} <- normalize(public_value),
         {:ok, mapped} <- effort_for_model(effort, support, map) do
      options = Map.drop(options, ["reasoningEffort" | @native_keys])
      {:ok, if(mapped, do: put_target(options, target, mapped), else: options)}
    end
  end

  # Anthropic accepts `output_config.effort` only on models that list effort
  # levels; a model that thinks without them rejects the field. A provider with
  # its own catalog keeps the earlier `high` default: OpenRouter routes
  # `reasoning` per model, and the ChatGPT and Ark catalogs list reasoning models.
  defp model_support(runtime, target) do
    case ModelMetadata.runtime_reasoning(runtime) do
      :provider_catalog -> {:supported, nil}
      nil -> :unknown
      %{"enabled" => true, "effort" => [_ | _] = values} -> {:supported, values}
      %{"enabled" => true} when target != :output_config -> {:supported, nil}
      _reasoning -> :unsupported
    end
  end

  defp effort_for_model(nil, {:supported, values}, map) do
    case map_effort(@default_effort, map) do
      {:ok, mapped} -> {:ok, if(values == nil or mapped in values, do: mapped)}
      {:error, _reason} -> {:ok, nil}
    end
  end

  defp effort_for_model(nil, _support, _map), do: {:ok, nil}

  defp effort_for_model(effort, :unsupported, _map),
    do: {:error, {:reasoning_effort, {:unsupported, effort, []}}}

  defp effort_for_model(effort, support, map) do
    with {:ok, mapped} <- map_effort(effort, map) do
      case support do
        {:supported, [_ | _] = values} ->
          if mapped in values,
            do: {:ok, mapped},
            else: {:error, {:reasoning_effort, {:unsupported, effort, model_values(values, map)}}}

        _known_or_unknown ->
          {:ok, mapped}
      end
    end
  end

  # The public names whose provider-native value the model accepts.
  defp model_values(native_values, map) do
    Enum.filter(values(map), fn effort ->
      case map_effort(effort, map) do
        {:ok, mapped} -> mapped in native_values
        {:error, _reason} -> false
      end
    end)
  end

  defp request_effort(ctx) do
    case Map.get(ctx, :request, %{}) do
      %{"reasoning" => %{"effort" => effort}} -> effort
      _request -> nil
    end
  end

  defp put_target(options, :reasoning, effort),
    do: Map.put(options, "reasoning", %{"effort" => effort})

  defp put_target(options, :reasoning_effort, effort),
    do: Map.put(options, "reasoning_effort", effort)

  defp put_target(options, :output_config, effort),
    do: Map.put(options, "output_config", %{"effort" => effort})

  defp map_effort(effort, nil), do: {:ok, effort}

  defp map_effort(effort, map) when is_map(map) do
    case Map.fetch(map, effort) do
      {:ok, mapped} ->
        {:ok, mapped}

      :error ->
        {:error, {:reasoning_effort, {:unsupported, effort, values(map)}}}
    end
  end
end
