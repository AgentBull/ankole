defmodule WeComOpenAPI.Bot.Dispatcher do
  @moduledoc """
  Immutable routing table for bot channel push frames.

  Message frames (`aibot_msg_callback`) route to the single message handler;
  event frames (`aibot_event_callback`) route by `body.event.eventtype`. The
  protocol has no application-level ack for pushes, so `dispatch/2` only
  reports the handler outcome for telemetry — unregistered event types are
  dropped as `:ignored`, not failures.

  `disconnected_event` never reaches the dispatcher: the client consumes it as
  the connection-contended signal.
  """

  alias WeComOpenAPI.Bot.Event

  defstruct message_handler: nil, event_handlers: %{}

  @type handler :: (Event.t() -> term())
  @type outcome :: :ok | :ignored | {:error, term()}
  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Register the message handler (`aibot_msg_callback` frames)."
  @spec on_message(t(), handler()) :: t()
  def on_message(%__MODULE__{} = dispatcher, handler) when is_function(handler, 1) do
    %{dispatcher | message_handler: handler}
  end

  @doc "Register an event handler for one `eventtype`."
  @spec on_event(t(), String.t(), handler()) :: t()
  def on_event(%__MODULE__{} = dispatcher, event_type, handler) when is_function(handler, 1) do
    put_in(dispatcher.event_handlers[event_type], handler)
  end

  @doc "Route a push frame to its handler and report the outcome."
  @spec dispatch(t(), Event.t()) :: outcome()
  def dispatch(%__MODULE__{} = dispatcher, %Event{cmd: "aibot_msg_callback"} = event) do
    case dispatcher.message_handler do
      nil -> :ignored
      handler -> run(handler, event)
    end
  end

  def dispatch(%__MODULE__{} = dispatcher, %Event{cmd: "aibot_event_callback"} = event) do
    case Map.get(dispatcher.event_handlers, event.event_type) do
      nil -> :ignored
      handler -> run(handler, event)
    end
  end

  def dispatch(%__MODULE__{}, %Event{}), do: :ignored

  # Handlers may call user code (Ingress). A crash is converted to `{:error, _}`
  # so the client's telemetry stays deterministic; the protocol offers no ack to
  # withhold, and ingress idempotency (`msgid` uniqueness) absorbs any platform
  # re-delivery.
  defp run(handler, event) do
    case handler.(event) do
      {:error, _reason} = error -> error
      _ok -> :ok
    end
  rescue
    exception -> {:error, {:handler_exception, exception, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:handler_throw, kind, reason}}
  end
end
