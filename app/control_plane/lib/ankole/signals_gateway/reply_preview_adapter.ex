defmodule Ankole.SignalsGateway.ReplyPreviewAdapter do
  @moduledoc """
  Provider-neutral lifecycle contract for one mutable AI reply surface.

  SignalsGateway owns the semantic presentation and its PostgreSQL checkpoint;
  adapters own only the provider handle and CardKit mutations. This keeps Lark
  card JSON out of worker events and lets another IM adapter implement the same
  lifecycle without inheriting Lark-specific sequence rules.
  """

  alias Ankole.SignalsGateway.ActorEvent
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
    do: normalize_result(fun.(request))

  @spec update(t(), Request.t()) :: adapter_result()
  def update(%__MODULE__{update_fun: fun}, %Request{} = request),
    do: normalize_result(fun.(request))

  @spec finalize(t(), Request.t()) :: adapter_result()
  def finalize(%__MODULE__{finalize_fun: fun}, %Request{} = request),
    do: normalize_result(fun.(request))

  @spec refresh(t(), Request.t()) :: adapter_result()
  def refresh(%__MODULE__{refresh_fun: fun}, %Request{} = request) when is_function(fun, 1),
    do: normalize_result(fun.(request))

  def refresh(%__MODULE__{refresh_fun: nil}, %Request{}),
    do: {:error, :reply_preview_refresh_unsupported}

  defp normalize_result({:ok, result}) when is_map(result), do: {:ok, result}
  defp normalize_result({:error, reason}), do: {:error, reason}

  defp normalize_result(result) do
    {:error, {:invalid_reply_preview_adapter_result, Sanitizer.transport(result)}}
  end
end
