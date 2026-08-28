defmodule Ankole.Kernel.ProgramRunner do
  @moduledoc """
  Deterministic PTC program execution on the native kernel.

  One call runs one program in a fresh bare V8 isolate until it completes or
  stalls on its first unanswered tool-call batch. Resume is replay: callers
  pass the recorded call transcript as `memo` and the program re-executes from
  the top with memoized answers. The engine owns timeouts, heap limits, and
  deterministic `Math.random`/`Date.now` shims.

  The call blocks a dirty CPU scheduler for up to the program timeout, so
  stream owners run it from a task, never from their own process loop.
  """

  alias Ankole.Kernel

  @run_option_keys [:max_pending_calls, :max_pending_bytes, :max_memo_bytes]

  @type run_id :: String.t()

  @type run_option ::
          {:max_pending_calls, non_neg_integer()}
          | {:max_pending_bytes, non_neg_integer()}
          | {:max_memo_bytes, non_neg_integer()}

  @type memo_entry :: %{
          required(String.t()) => term()
        }

  @type tool_binding :: %{
          required(String.t()) => String.t() | nil
        }

  @type outcome :: %{
          required(:status) => :completed | :pending | :failed,
          required(:output) => [%{kind: String.t(), value: String.t()}],
          required(:pending_calls) => [
            %{namespace: String.t() | nil, name: String.t(), arguments: term()}
          ],
          required(:error) => String.t() | nil,
          required(:error_code) => String.t() | nil
        }

  @doc """
  Runs one program and returns its outcome.

  `tools` keeps each public `namespace` and `name` beside the JavaScript
  `global_name` available as `tools[global_name](args)`. `memo` entries answer
  replayed calls in order with the same structured identity.
  """
  @spec run(String.t(), [tool_binding()], [memo_entry()]) ::
          {:ok, outcome()} | {:error, String.t()}
  def run(program, tools, memo)
      when is_binary(program) and is_list(tools) and is_list(memo) do
    run(new_run_id(), program, tools, memo)
  end

  @doc false
  @spec run(run_id(), String.t(), [tool_binding()], [memo_entry()]) ::
          {:ok, outcome()} | {:error, String.t()}
  def run(run_id, program, tools, memo)
      when is_binary(run_id) and is_binary(program) and is_list(tools) and is_list(memo) do
    run(run_id, program, tools, memo, [])
  end

  @doc false
  @spec run(run_id(), String.t(), [tool_binding()], [memo_entry()], [run_option()]) ::
          {:ok, outcome()} | {:error, String.t()}
  def run(run_id, program, tools, memo, options)
      when is_binary(run_id) and is_binary(program) and is_list(tools) and is_list(memo) and
             is_list(options) do
    with {:ok, options} <- validate_run_options(options),
         request =
           Enum.reduce(options, %{"program" => program, "tools" => tools, "memo" => memo}, fn
             {key, value}, request -> Map.put(request, Atom.to_string(key), value)
           end),
         {:ok, request_json} <- Torque.encode(request),
         outcome_json when is_binary(outcome_json) <- Kernel.program_run_nif(run_id, request_json),
         {:ok, outcome} <- Torque.decode(outcome_json) do
      {:ok, decode_outcome(outcome)}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc false
  @spec new_run_id() :: run_id()
  def new_run_id, do: Kernel.gen_uuid()

  @doc "Cancels the matching execution when it is currently running."
  @spec cancel(run_id()) :: :ok | {:error, String.t()}
  def cancel(run_id) when is_binary(run_id) do
    case Kernel.program_cancel_nif(run_id) do
      found when is_boolean(found) -> :ok
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
      result -> {:error, "invalid program cancellation result: #{inspect(result)}"}
    end
  end

  defp validate_run_options(options) do
    case Keyword.validate(options, @run_option_keys) do
      {:ok, options} ->
        {:ok, options}

      {:error, unsupported} ->
        {:error,
         "unsupported program run options: #{Enum.map_join(unsupported, ", ", &inspect/1)}"}
    end
  end

  defp decode_outcome(outcome) do
    %{
      status: decode_status(outcome["status"]),
      output:
        outcome
        |> Map.get("output", [])
        |> Enum.map(&%{kind: &1["kind"], value: &1["value"]}),
      pending_calls:
        outcome
        |> Map.get("pending_calls", [])
        |> Enum.map(
          &%{
            namespace: Map.get(&1, "namespace"),
            name: &1["name"],
            arguments: Map.get(&1, "arguments")
          }
        ),
      error: outcome["error"],
      error_code: outcome["error_code"]
    }
  end

  defp decode_status("completed"), do: :completed
  defp decode_status("pending"), do: :pending
  defp decode_status(_status), do: :failed
end
