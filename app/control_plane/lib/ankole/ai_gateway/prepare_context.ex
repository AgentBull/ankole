defmodule Ankole.AIGateway.PrepareContext do
  @moduledoc """
  Request preparation context passed to provider `prepare_*` functions.

  The context is the only object provider modules need in order to build a
  prepared UniversalAIClient request. It keeps provider options, per-request
  options, model selection, and the original public request together without
  making provider code query model profiles or decrypt secrets by itself.
  """

  import Ankole.AIGateway.MapUtils, only: [normalize_request_keys: 1]

  alias Ankole.AIGateway.ProviderDefinition
  alias Ankole.AIGateway.ProviderDefinition.Capability

  @enforce_keys [
    :provider,
    :capability,
    :runtime,
    :request,
    :provider_options,
    :settings,
    :model,
    :stream?
  ]
  defstruct [
    :provider,
    :capability,
    :runtime,
    :request,
    :provider_options,
    :settings,
    :model,
    :stream?
  ]

  @typedoc """
  Provider-facing request preparation context.

  `runtime` is the resolved model binding, `request` is the normalized public
  request body, and `settings` merges provider defaults with operator/runtime
  connection options.
  """
  @type t :: %__MODULE__{
          provider: ProviderDefinition.t(),
          capability: Capability.t(),
          runtime: map(),
          request: map(),
          provider_options: map(),
          settings: map(),
          model: String.t() | nil,
          stream?: boolean()
        }

  @doc """
  Builds the provider-facing context for one resolved runtime request.

  Settings are merged before provider code runs so a provider can read values
  from one stable map. Connection options and encrypted options are both
  operator-managed inputs; request-scoped provider options remain available
  separately as `provider_options`.
  """
  @spec build(ProviderDefinition.t(), Capability.kind(), map(), map(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def build(%ProviderDefinition{} = provider, capability_kind, runtime, request, opts \\ []) do
    with {:ok, capability} <- ProviderDefinition.capability(provider, capability_kind) do
      stream? = Keyword.get(opts, :stream?, false)

      {:ok,
       %__MODULE__{
         provider: provider,
         capability: capability,
         runtime: runtime,
         request: normalize_request_keys(request),
         provider_options: provider_options(runtime),
         settings: settings(provider, runtime),
         model: runtime["model"],
         stream?: stream?
       }}
    end
  end

  # Provider defaults come first, then operator/runtime values override them.
  # `base_url` is treated as a setting because provider prepare code needs the
  # same access pattern for both static and operator-overridden endpoints.
  defp settings(%ProviderDefinition{} = provider, runtime) do
    defaults =
      Map.new(provider.settings, fn setting -> {setting.key, setting.default} end)
      |> maybe_put(:base_url, provider.base_url)

    runtime_settings =
      %{}
      |> Map.merge(atomize_keys(Map.get(runtime, "connection_options", %{})))
      |> Map.merge(atomize_keys(Map.get(runtime, "provider_options", %{})))
      |> maybe_put(:base_url, get_in(runtime, ["connection_options", "base_url"]))

    Map.merge(defaults, runtime_settings)
  end

  # Runtime provider options are request-scoped knobs, not connection settings.
  # Keeping them separate avoids mixing per-call behavior into stored provider
  # rows while still giving provider code one normalized shape.
  defp provider_options(runtime) do
    case Map.get(runtime, "provider_options") do
      value when is_map(value) -> normalize_request_keys(value)
      _value -> %{}
    end
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {key, value}
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp atomize_keys(_value), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
