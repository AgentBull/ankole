defmodule Ankole.Kernel.AppletRuntime do
  @moduledoc """
  One native V8 invocation with asynchronous, caller-owned capabilities.

  Each call starts a dedicated native thread and a fresh isolate. The caller
  receives `{:applet_runtime, run_id, :call, id, operation, arguments_json}` and
  answers it with `reply/3`. Completion is
  `{:applet_runtime, run_id, :done, outcome_json}`. The JSON boundary contains no
  credentials. Owner process exit and `cancel/1` terminate the invocation.
  """
  alias Ankole.Kernel

  @spec start(String.t(), map(), keyword()) :: {:ok, reference(), String.t()} | {:error, term()}
  def start(source, context, options \\ []) when is_binary(source) and is_map(context) do
    with {:ok, options} <-
           Keyword.validate(options, timeout_ms: 60_000, heap_mb: 128, inspect: false),
         request = Map.new(options, fn {key, value} -> {Atom.to_string(key), value} end),
         {:ok, encoded} <-
           Torque.encode(Map.merge(request, %{"source" => source, "context" => context})),
         run_id = Kernel.gen_uuid(),
         handle when is_reference(handle) <- Kernel.applet_start_nif(run_id, encoded) do
      {:ok, handle, run_id}
    else
      {:error, _reason} = error -> error
      other -> {:error, other}
    end
  end

  @spec inspect(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, map() | term()}
  def inspect(source, options \\ []) do
    with {:ok, handle, run_id} <- start(source, %{}, Keyword.put(options, :inspect, true)) do
      receive do
        {:applet_runtime, ^run_id, :done, json} ->
          with {:ok, outcome} <- Torque.decode(json) do
            case outcome do
              %{"status" => 200, "routes" => routes} ->
                {:ok, routes}

              %{"status" => status, "body" => %{"error" => error}} ->
                {:error, Map.put(error, "status", status)}
            end
          end
      after
        Keyword.get(options, :timeout_ms, 60_000) + 5_000 ->
          cancel(handle)

          {:error,
           %{
             "status" => 504,
             "code" => "handler_timeout",
             "message" => "Applet inspection timed out"
           }}
      end
    end
  end

  @spec reply(reference(), non_neg_integer(), {:ok, term()} | {:error, map()}) ::
          :ok | {:error, term()}
  def reply(handle, call_id, result) when is_reference(handle) and is_integer(call_id) do
    value =
      case result do
        {:ok, value} -> %{"value" => value}
        {:error, error} when is_map(error) -> %{"error" => error}
      end

    with {:ok, encoded} <- Torque.encode(value) do
      case Kernel.applet_reply_nif(handle, call_id, encoded) do
        true -> :ok
        false -> {:error, :invocation_ended}
        error -> error
      end
    end
  end

  @spec cancel(reference()) :: :ok
  def cancel(handle) when is_reference(handle) do
    Kernel.applet_cancel_nif(handle)
    :ok
  end
end
