defmodule Ankole.SignalsGateway.ReplyPreviewAdapter do
  @moduledoc """
  Provider-neutral lifecycle contract for one mutable AI reply surface.

  SignalsGateway owns the semantic presentation and its PostgreSQL checkpoint;
  adapters own only the provider handle and provider-native mutations. This
  keeps Slack Block Kit and Lark CardKit data out of worker events while each IM
  adapter implements its own transport rules.
  """

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.OutboundSecretFilter
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.Sanitizer
  alias Ankole.SignalsGateway.Utils

  defmodule Request do
    @moduledoc false

    @enforce_keys [:actor_event, :presentation, :mode]
    defstruct [
      :actor_event,
      :presentation,
      :previous_presentation,
      :checkpoint,
      :subject_uid,
      :conversation_id,
      :outbox,
      :mode
    ]

    @type t :: %__MODULE__{
            actor_event: ActorEvent.t(),
            presentation: map(),
            previous_presentation: map() | nil,
            checkpoint: map() | nil,
            subject_uid: String.t() | nil,
            conversation_id: String.t() | nil,
            outbox: OutboxEntry.t() | nil,
            mode: :working | :terminal
          }
  end

  @enforce_keys [:open_fun, :update_fun, :finalize_fun]
  defstruct [:open_fun, :update_fun, :finalize_fun, :refresh_fun]

  @type adapter_result :: {:ok, map()} | {:error, term()}
  @type t :: %__MODULE__{
          open_fun: (Request.t() -> term()),
          update_fun: (Request.t() -> term()),
          finalize_fun: (Request.t() -> term()),
          refresh_fun: (Request.t() -> term()) | nil
        }

  @callback open(Request.t()) :: adapter_result() | term()
  @callback update(Request.t()) :: adapter_result() | term()
  @callback finalize(Request.t()) :: adapter_result() | term()
  @callback refresh(Request.t()) :: adapter_result() | term()
  @optional_callbacks refresh: 1

  @spec from_module(module()) :: {:ok, t()} | {:error, term()}
  def from_module(module) when is_atom(module) do
    with true <- Code.ensure_loaded?(module) || {:error, :invalid_reply_preview_adapter},
         :ok <- Utils.validate_module_callback(module, :open, 1),
         :ok <- Utils.validate_module_callback(module, :update, 1),
         :ok <- Utils.validate_module_callback(module, :finalize, 1) do
      {:ok,
       %__MODULE__{
         open_fun: Function.capture(module, :open, 1),
         update_fun: Function.capture(module, :update, 1),
         finalize_fun: Function.capture(module, :finalize, 1),
         refresh_fun:
           if(function_exported?(module, :refresh, 1),
             do: Function.capture(module, :refresh, 1),
             else: nil
           )
       }}
    end
  end

  def from_module(_module), do: {:error, :invalid_reply_preview_adapter}

  @spec open(t(), Request.t()) :: adapter_result()
  def open(%__MODULE__{open_fun: fun}, %Request{} = request),
    do: call_adapter(fun, request)

  @spec update(t(), Request.t()) :: adapter_result()
  def update(%__MODULE__{update_fun: fun}, %Request{} = request),
    do: call_adapter(fun, request)

  @spec finalize(t(), Request.t()) :: adapter_result()
  def finalize(%__MODULE__{finalize_fun: fun}, %Request{} = request),
    do: call_adapter(fun, request)

  @spec refresh(t(), Request.t()) :: adapter_result()
  def refresh(%__MODULE__{refresh_fun: fun}, %Request{} = request) when is_function(fun, 1),
    do: call_adapter(fun, request)

  def refresh(%__MODULE__{refresh_fun: nil}, %Request{}),
    do: {:error, :reply_preview_refresh_unsupported}

  @doc """
  Finalizes through a reply-preview module a caller already knows by name,
  instead of a registry-resolved adapter. Goes through the same secret filter
  and result validation as `finalize/2` — a provider Outbox module that calls
  its own declared reply-preview module directly for terminal delivery should
  use this instead of calling the module's `finalize/1` on its own.
  """
  @spec finalize_module(module(), Request.t()) :: adapter_result()
  def finalize_module(module, %Request{} = request) when is_atom(module) do
    with {:ok, adapter} <- from_module(module) do
      finalize(adapter, request)
    end
  end

  defp call_adapter(fun, request) do
    with {:ok, filtered_request} <- OutboundSecretFilter.filter_reply_preview(request) do
      normalize_result(fun.(filtered_request))
    end
  end

  defp normalize_result({:ok, result}) when is_map(result) do
    case Enum.find(Map.keys(result), &(not is_atom(&1))) do
      nil -> {:ok, result}
      key -> {:error, {:invalid_reply_preview_adapter_result_key, Sanitizer.transport(key)}}
    end
  end

  defp normalize_result({:error, reason}), do: {:error, reason}

  defp normalize_result(result) do
    {:error, {:invalid_reply_preview_adapter_result, Sanitizer.transport(result)}}
  end
end
