defmodule Ankole.AIGateway.ReasoningEffort do
  @moduledoc """
  Normalizes the public `reasoningEffort` option before provider request build.

  Ankole uses OpenAI's effort names as the public contract. Providers that do
  not accept the full OpenAI set pass a small value map from their own module.
  """

  alias Ankole.AIGateway.MapUtils
  alias Ankole.AIGateway.UniversalAIRequest

  @openai_values ~w(none minimal low medium high xhigh)
  @default_effort "high"

  @doc """
  Normalizes one public OpenAI-style reasoning effort value.

  Missing values default to `high` because Ankole treats reasoning-capable
  language-model calls as high-effort unless a caller asks otherwise.
  """
  @spec normalize(term()) :: {:ok, String.t()} | {:error, term()}
  def normalize(nil), do: {:ok, @default_effort}
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

  OpenAI-compatible providers use the default target key and no value map.
  Provider-specific modules pass `:target_key`, `:map`, or `:skip_if_present`
  only when their upstream API differs from OpenAI's public option.
  """
  @spec put_provider_options(UniversalAIRequest.t(), map(), keyword()) ::
          UniversalAIRequest.t() | {:error, term()}
  def put_provider_options(%UniversalAIRequest{} = request, ctx, opts \\ []) when is_map(ctx) do
    with {:ok, provider_options} <- provider_options(ctx, opts) do
      UniversalAIRequest.put_provider_options(request, provider_options)
    end
  end

  @doc """
  Returns provider options with `reasoningEffort` normalized and mapped.
  """
  @spec provider_options(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def provider_options(ctx, opts \\ []) when is_map(ctx) do
    options = ctx |> Map.get(:provider_options, %{}) |> MapUtils.normalize_request_keys()
    public_value = Map.get(options, "reasoningEffort")
    target_key = opts |> Keyword.get(:target_key, "reasoningEffort") |> to_string()

    cond do
      present?(public_value) ->
        put_mapped_effort(options, public_value, target_key, opts)

      provider_native_effort_present?(options, target_key, opts) ->
        {:ok, options}

      true ->
        put_mapped_effort(options, nil, target_key, opts)
    end
  end

  defp put_mapped_effort(options, value, target_key, opts) do
    with {:ok, effort} <- normalize(value),
         {:ok, mapped} <- map_effort(effort, Keyword.get(opts, :map)) do
      {:ok,
       options
       |> Map.delete("reasoningEffort")
       |> Map.put(target_key, mapped)}
    end
  end

  defp map_effort(effort, nil), do: {:ok, effort}

  defp map_effort(effort, map) when is_map(map) do
    case Map.fetch(map, effort) do
      {:ok, mapped} ->
        {:ok, mapped}

      :error ->
        {:error, {:reasoning_effort, {:unsupported, effort, Map.keys(map) |> Enum.sort()}}}
    end
  end

  defp provider_native_effort_present?(options, target_key, opts) do
    skip_keys = opts |> Keyword.get(:skip_if_present, []) |> Enum.map(&to_string/1)

    Enum.any?([target_key | skip_keys], fn key ->
      key != "reasoningEffort" and present?(Map.get(options, key))
    end)
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true
end
