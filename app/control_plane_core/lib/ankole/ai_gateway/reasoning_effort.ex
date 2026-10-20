defmodule Ankole.AIGateway.ReasoningEffort do
  @moduledoc """
  Normalizes the public `reasoningEffort` option before provider request build.

  Ankole uses OpenAI's effort names as the public contract. Providers that do
  not accept the full OpenAI set pass a small value map from their own module.
  """

  alias Ankole.Attrs
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

  @doc "Returns the effective effort used when a model profile does not choose one."
  @spec default() :: String.t()
  def default, do: @default_effort

  @doc """
  Normalizes one public OpenAI-style reasoning effort value.

  Missing values default to `high` because Ankole treats reasoning-capable
  language-model calls as high-effort unless a caller asks otherwise.
  """
  @spec normalize(term()) :: {:ok, String.t()} | {:error, term()}
  def normalize(nil), do: {:ok, default()}
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

    put_mapped_effort(options, public_value, target, opts)
  end

  defp request_effort(ctx) do
    case Map.get(ctx, :request, %{}) do
      %{"reasoning" => %{"effort" => effort}} -> effort
      _request -> nil
    end
  end

  defp put_mapped_effort(options, value, target, opts) do
    with {:ok, effort} <- normalize(value),
         {:ok, mapped} <- map_effort(effort, Keyword.get(opts, :map)) do
      {:ok,
       options
       |> Map.drop(["reasoningEffort" | @native_keys])
       |> put_target(target, mapped)}
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
