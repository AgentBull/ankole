defmodule Ankole.AIGateway.ProviderDefinition do
  @moduledoc """
  Compiled provider declaration consumed by the AIGateway registry.

  Provider modules own request preparation. The compiled definition only
  describes stable metadata, settings, and which prepare function owns each
  user-facing capability.
  """

  defmodule Setting do
    @moduledoc """
    Declares one operator or request option accepted by a provider.

    `encrypted?` is storage metadata only. Provider code still reads the
    decrypted value from the same settings map, so request construction does not
    need a separate credential abstraction.
    """

    @enforce_keys [:key]
    defstruct [
      :key,
      :type,
      :default,
      required?: false,
      encrypted?: false,
      scope: :connection
    ]

    @typedoc """
    Provider option metadata stored in the compiled provider definition.
    """
    @type t :: %__MODULE__{
            key: atom(),
            type: atom() | nil,
            default: term(),
            required?: boolean(),
            encrypted?: boolean(),
            scope: :connection | :request
          }
  end

  defmodule Capability do
    @moduledoc """
    Describes one user-facing model capability exposed by a provider.

    The capability binds an Elixir prepare function to the Rust-side
    `api_resolver` and upstream wire shape. Provider selection, URL, auth, and
    headers stay in Elixir; protocol request encoding, transport, and response
    normalization stay in UniversalAIClient.
    """

    @enforce_keys [:kind, :upstream, :api_resolver, :prepare]
    defstruct [
      :kind,
      :upstream,
      :api_resolver,
      :prepare,
      :timeout_ms
    ]

    @type kind :: :language_model | :embedding_model | :rerank_model

    @typedoc """
    Capability metadata used to route a public model capability to provider
    request preparation and native response normalization.
    """
    @type t :: %__MODULE__{
            kind: kind(),
            upstream: :sse | :eventstream | :websocket_text | :json,
            api_resolver: atom(),
            prepare: atom(),
            timeout_ms: pos_integer() | nil
          }
  end

  @enforce_keys [:provider_kind, :label, :module, :capabilities]
  defstruct [
    :provider_kind,
    :label,
    :module,
    :base_url,
    settings: [],
    capabilities: []
  ]

  @typedoc """
  Compiled provider metadata consumed by the registry and runtime dispatcher.
  """
  @type t :: %__MODULE__{
          provider_kind: String.t(),
          label: map(),
          module: module(),
          base_url: String.t() | nil,
          settings: [Setting.t()],
          capabilities: [Capability.t()]
        }

  @doc """
  Fetches the provider capability declaration for one capability kind.
  """
  @spec capability(t(), Capability.kind()) :: {:ok, Capability.t()} | {:error, term()}
  def capability(%__MODULE__{capabilities: capabilities}, kind) do
    case Enum.find(capabilities, &(&1.kind == kind)) do
      %Capability{} = capability -> {:ok, capability}
      nil -> {:error, {:unsupported_capability, capability_name(kind)}}
    end
  end

  @doc """
  Returns the public capability name used in runtime maps and catalog output.

  The DSL uses Elixir names such as `:language_model`; runtime selectors use
  shorter external names such as `"llm"` to match existing AIGateway contracts.
  """
  @spec capability_name(Capability.kind()) :: String.t()
  def capability_name(:language_model), do: "llm"
  def capability_name(:embedding_model), do: "embedding"
  def capability_name(:rerank_model), do: "rerank"
end
