defmodule Ankole.SignalsGateway.WebhookHandlers do
  @moduledoc """
  Resolves `signals_gateway.webhook_handler` plugin declarations.

  A webhook handler is the plugin-owned receiver behind one
  `/webhooks/v1/:handler_id/:instance_id/:kind` route segment. The host owns
  routing and the declared-kind whitelist; the plugin owns provider
  authentication, payload interpretation, and the response instruction. One
  handler is the webhook analog of a long-connection owner: a single transport
  entry that the plugin may fan out to chat and identity consumers.

  Provider webhook payloads carry no host credentials, so the route itself is
  unauthenticated — every handler module must authenticate the provider
  (signature, JWT, or shared secret) before acting on a request.
  """

  alias Ankole.Plugins.Registry
  alias Ankole.SignalsGateway.Utils

  @contract_id "signals_gateway.webhook_handler"

  defmodule Definition do
    @moduledoc """
    Normalized webhook-handler declaration consumed by the webhook route.
    """

    @enforce_keys [:id, :module, :kinds]
    defstruct [:id, :plugin_id, :module, kinds: []]

    @type t :: %__MODULE__{
            id: String.t(),
            plugin_id: String.t() | nil,
            module: module(),
            kinds: [String.t()]
          }
  end

  @type request :: %{
          required(:handler_id) => String.t(),
          required(:instance_id) => String.t(),
          required(:kind) => String.t(),
          required(:query_params) => map(),
          required(:body_params) => map(),
          required(:headers) => %{String.t() => String.t()}
        }

  @type response :: %{
          required(:status) => non_neg_integer(),
          optional(:body) => map() | String.t(),
          optional(:content_type) => String.t()
        }

  @doc """
  Lists active webhook handlers as normalized definitions.
  """
  @spec list(GenServer.server()) ::
          {:ok, [Definition.t()]} | {:error, :webhook_handler_registry_unavailable | term()}
  def list(server \\ Registry) do
    with {:ok, declarations} <- declarations(server) do
      declarations
      |> Enum.map(&resolve_declaration/1)
      |> Utils.collect_results()
    end
  end

  @doc """
  Fetches one active webhook handler by id.
  """
  @spec fetch(String.t(), GenServer.server()) ::
          {:ok, Definition.t()}
          | {:error,
             :webhook_handler_registry_unavailable
             | {:webhook_handler_not_found, String.t()}
             | term()}
  def fetch(handler_id, server \\ Registry) when is_binary(handler_id) do
    with {:ok, declarations} <- declarations(server),
         declaration when not is_nil(declaration) <-
           Enum.find(declarations, &(value(&1, :id) == handler_id)) do
      resolve_declaration(declaration)
    else
      nil -> {:error, {:webhook_handler_not_found, handler_id}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Dispatches one webhook request to its declared handler module.

  The kind whitelist is enforced here so a handler only ever sees kinds it
  declared. The handler returns a `t:response/0` instruction; anything else is
  an adapter contract violation surfaced to the caller.
  """
  @spec dispatch(request(), GenServer.server()) ::
          {:ok, response()}
          | {:error,
             :webhook_handler_registry_unavailable
             | {:webhook_handler_not_found, String.t()}
             | {:webhook_kind_not_declared, String.t(), String.t()}
             | term()}
  def dispatch(%{handler_id: handler_id, kind: kind} = request, server \\ Registry) do
    with {:ok, %Definition{} = definition} <- fetch(handler_id, server),
         :ok <- ensure_kind(definition, kind) do
      case definition.module.handle_webhook(request) do
        {:ok, %{status: status} = response} when is_integer(status) -> {:ok, response}
        {:error, _reason} = error -> error
        other -> {:error, {:invalid_webhook_handler_result, definition.id, other}}
      end
    end
  end

  @doc false
  @spec validate_declaration(map()) :: :ok | {:error, term()}
  def validate_declaration(declaration) when is_map(declaration) do
    case resolve_declaration(declaration) do
      {:ok, %Definition{}} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def validate_declaration(declaration),
    do: {:error, {:invalid_webhook_handler_declaration, declaration}}

  defp declarations(server) do
    try do
      {:ok, Registry.adapter_declarations(@contract_id, server)}
    catch
      :exit, _reason -> {:error, :webhook_handler_registry_unavailable}
    end
  end

  defp resolve_declaration(declaration) do
    with handler_id when is_binary(handler_id) and handler_id != "" <- value(declaration, :id),
         {:ok, module} <- declaration_module(declaration),
         :ok <- Utils.validate_module_callback(module, :handle_webhook, 1),
         {:ok, kinds} <- declared_kinds(declaration) do
      {:ok,
       %Definition{
         id: handler_id,
         plugin_id: value(declaration, :plugin_id),
         module: module,
         kinds: kinds
       }}
    else
      {:error, _reason} = error -> error
      _handler_id -> {:error, {:invalid_webhook_handler_declaration, declaration}}
    end
  end

  defp declaration_module(declaration) do
    case value(declaration, :module) do
      module when is_atom(module) and not is_nil(module) ->
        case Code.ensure_loaded(module) do
          {:module, ^module} -> {:ok, module}
          {:error, reason} -> {:error, {:webhook_handler_module_not_loaded, module, reason}}
        end

      module ->
        {:error, {:invalid_webhook_handler_module, module}}
    end
  end

  defp declared_kinds(declaration) do
    case value(declaration, :kinds) do
      [_head | _tail] = kinds ->
        if Enum.all?(kinds, &(is_binary(&1) and &1 != "")) do
          {:ok, kinds}
        else
          {:error, {:invalid_webhook_handler_kinds, kinds}}
        end

      kinds ->
        {:error, {:invalid_webhook_handler_kinds, kinds}}
    end
  end

  defp ensure_kind(%Definition{kinds: kinds} = definition, kind) do
    if kind in kinds do
      :ok
    else
      {:error, {:webhook_kind_not_declared, definition.id, kind}}
    end
  end

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
