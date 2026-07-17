defmodule DingTalkOpenAPI.Stream.Dispatcher do
  @moduledoc """
  Immutable routing table for DingTalk Stream frames.

  CALLBACK frames route by `headers.topic` (e.g.
  `/v1.0/im/bot/messages/get`); EVENT frames route by `headers.eventType`
  (e.g. `user_add_org`). SYSTEM frames (`ping`, `disconnect`) are handled by the
  Stream client directly and never reach the dispatcher.

  `dispatch/2` returns an ack decision the client encodes into the response
  frame:

    * `{:reply, code, data}` — send a response frame with `code` and `data`.
    * `{:withhold, reason}` — send no ack, letting the platform re-deliver
      (callback handler failure or crash).

  Ack shapes follow the protocol:

    * CALLBACK success → `{:reply, 200, %{"response" => map}}`.
    * CALLBACK unregistered topic → `{:reply, 404, %{}}`.
    * CALLBACK handler `{:error, _}` / crash → `{:withhold, reason}`.
    * EVENT handler `:ok` / `{:ok, _}` / unregistered type → `{:reply, 200,
      %{"status" => "SUCCESS"}}` (unregistered events are dropped, not our
      failure).
    * EVENT handler `{:error, _}` → `{:reply, 200, %{"status" => "LATER"}}`
      (platform re-delivers).
  """

  alias DingTalkOpenAPI.Event

  defstruct callback_handlers: %{}, event_handlers: %{}

  @type handler :: (String.t(), Event.t() -> term())
  @type ack :: {:reply, non_neg_integer(), map()} | {:withhold, term()}
  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Register a CALLBACK handler for a topic."
  @spec on_callback(t(), String.t(), handler()) :: t()
  def on_callback(%__MODULE__{} = dispatcher, topic, handler) when is_function(handler, 2) do
    put_in(dispatcher.callback_handlers[topic], handler)
  end

  @doc "Register an EVENT handler for an eventType."
  @spec on_event(t(), String.t(), handler()) :: t()
  def on_event(%__MODULE__{} = dispatcher, event_type, handler) when is_function(handler, 2) do
    put_in(dispatcher.event_handlers[event_type], handler)
  end

  @doc "Registered CALLBACK topics (used to build the Stream subscription list)."
  @spec callback_topics(t()) :: [String.t()]
  def callback_topics(%__MODULE__{callback_handlers: handlers}), do: Map.keys(handlers)

  @doc "Whether any EVENT handler is registered (drives the EVENT `*` subscription)."
  @spec events?(t()) :: boolean()
  def events?(%__MODULE__{event_handlers: handlers}), do: map_size(handlers) > 0

  @doc "Route a frame to its handler and return the ack decision."
  @spec dispatch(t(), Event.t()) :: ack()
  def dispatch(%__MODULE__{} = dispatcher, %Event{type: "CALLBACK", topic: topic} = event) do
    case Map.get(dispatcher.callback_handlers, topic) do
      nil ->
        {:reply, 404, %{}}

      handler ->
        case run(handler, topic, event) do
          {:ok, response} when is_map(response) -> {:reply, 200, %{"response" => response}}
          {:ok, _other} -> {:reply, 200, %{"response" => %{}}}
          {:error, reason} -> {:withhold, reason}
        end
    end
  end

  def dispatch(%__MODULE__{} = dispatcher, %Event{type: "EVENT", event_type: event_type} = event) do
    case Map.get(dispatcher.event_handlers, event_type) do
      nil ->
        # Unregistered events are outside our interest set, not a failure — ack
        # SUCCESS so the platform stops re-delivering them.
        {:reply, 200, %{"status" => "SUCCESS"}}

      handler ->
        case run(handler, event_type, event) do
          {:error, _reason} -> {:reply, 200, %{"status" => "LATER"}}
          _ok -> {:reply, 200, %{"status" => "SUCCESS"}}
        end
    end
  end

  def dispatch(%__MODULE__{}, %Event{type: type}) do
    {:reply, 404, %{"unhandled" => type}}
  end

  # Handlers may call user code (Ingress). A crash is converted to `{:error, _}`
  # here so the client's ack decision is deterministic: withhold for callbacks,
  # LATER for events — both cause the platform to re-deliver, and ingress
  # idempotency (the actor_events unique constraint) keeps re-delivery safe.
  defp run(handler, key, event) do
    handler.(key, event)
  rescue
    exception -> {:error, {:handler_exception, exception, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:handler_throw, kind, reason}}
  end
end
