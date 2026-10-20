defmodule SlackOpenAPI.SocketMode.Dispatcher do
  @moduledoc "Routes Socket Mode envelopes to registered handlers."

  alias SlackOpenAPI.Event

  defstruct event_handlers: %{}, interactive_handlers: %{}

  @type handler :: (String.t(), Event.t() -> term())
  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(_opts \\ []), do: %__MODULE__{}

  @spec on(t(), String.t(), handler()) :: t()
  def on(%__MODULE__{} = dispatcher, event_type, handler) when is_function(handler, 2) do
    put_in(dispatcher.event_handlers[event_type], handler)
  end

  @spec on_interactive(t(), String.t(), handler()) :: t()
  def on_interactive(%__MODULE__{} = dispatcher, payload_type, handler)
      when is_function(handler, 2) do
    put_in(dispatcher.interactive_handlers[payload_type], handler)
  end

  @spec dispatch(t(), {:envelope, map()}) :: {:ok, term()} | {:error, term()}
  def dispatch(%__MODULE__{} = dispatcher, {:envelope, envelope}) do
    event = Event.from_envelope(envelope)

    handler =
      case Map.get(envelope, "type") do
        "interactive" -> Map.get(dispatcher.interactive_handlers, event.type)
        "events_api" -> Map.get(dispatcher.event_handlers, event.type)
        _type -> nil
      end

    case handler do
      nil -> {:ok, :no_handler}
      fun -> normalize_result(fun.(event.type, event))
    end
  rescue
    exception -> {:error, {:handler_exception, exception, __STACKTRACE__}}
  end

  defp normalize_result({:ok, _value} = result), do: result
  defp normalize_result({:error, _reason} = result), do: result
  defp normalize_result(result), do: {:ok, result}
end
