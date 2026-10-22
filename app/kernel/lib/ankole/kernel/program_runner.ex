defmodule Ankole.Kernel.ProgramRunner do
  @moduledoc """
  Deterministic Workflow and PTC program execution on the native kernel.

  One call runs one program in a fresh bare V8 isolate until it completes or
  stalls on its first unanswered tool-call batch. Resume is replay: callers
  pass the recorded call transcript as `memo` and the program re-executes from
  the top with memoized answers. The engine owns timeouts, heap limits, and
  deterministic `Math.random`/`Date.now` shims.

  Native threads decode requests and execute V8. BEAM processes wait for an
  outcome message without reserving a scheduler. A handle owns cancellation
  before execution starts. Owner or executing process exit terminates the run.
  """

  alias Ankole.Kernel

  @run_option_keys [:timeout_ms, :max_pending_calls, :max_pending_bytes, :max_memo_bytes]

  @opaque handle :: reference()

  @type run_option ::
          {:timeout_ms, non_neg_integer()}
          | {:max_pending_calls, non_neg_integer()}
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
    run(new_handle(), program, tools, memo, [])
  end

  @doc "Creates one execution handle whose lifetime belongs to the given process."
  @spec new_handle(pid()) :: handle()
  def new_handle(owner \\ self()) when is_pid(owner), do: Kernel.program_handle_nif(owner)

  @doc false
  @spec run(handle(), String.t(), [tool_binding()], [memo_entry()]) ::
          {:ok, outcome()} | {:error, String.t()}
  def run(handle, program, tools, memo), do: run(handle, program, tools, memo, [])

  @doc false
  @spec run(handle(), String.t(), [tool_binding()], [memo_entry()], [run_option()]) ::
          {:ok, outcome()} | {:error, String.t()}
  def run(handle, program, tools, memo, options) do
    case start(handle, program, tools, memo, options) do
      {:ok, handle} -> await(handle)
      {:error, {:program_runner_busy, outcome}} -> {:ok, outcome}
      {:error, _reason} = error -> error
    end
  end

  @doc "Starts one native execution and returns without waiting for V8."
  @spec start(handle(), String.t(), [tool_binding()], [memo_entry()], [run_option()]) ::
          {:ok, handle()} | {:error, {:program_runner_busy, outcome()} | String.t()}
  def start(handle, program, tools, memo, options \\ [])
      when is_reference(handle) and is_binary(program) and is_list(tools) and is_list(memo) do
    with {:ok, options} <- validate_run_options(options),
         request =
           Enum.reduce(options, %{"program" => program, "tools" => tools, "memo" => memo}, fn
             {key, value}, request -> Map.put(request, Atom.to_string(key), value)
           end),
         {:ok, request_json} <- Torque.encode(request) do
      case Kernel.program_run_nif(handle, request_json) do
        ^handle ->
          {:ok, handle}

        {:error, :program_runner_busy, json} ->
          {:error, {:program_runner_busy, json |> Torque.decode!() |> decode_outcome()}}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    else
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  @doc "Waits for the outcome of an execution started by this process."
  @spec await(handle()) :: {:ok, outcome()} | {:error, String.t()}
  def await(handle) when is_reference(handle) do
    receive do
      {:program_runner, ^handle, {:ok, json}} ->
        {:ok, json |> Torque.decode!() |> decode_outcome()}

      {:program_runner, ^handle, {:error, reason}} ->
        {:error, format_error(reason)}
    end
  end

  @doc "Cancels one execution, including one that has not started yet."
  @spec cancel(handle()) :: :ok
  def cancel(handle) when is_reference(handle) do
    true = Kernel.program_cancel_nif(handle)
    :ok
  end

  @doc "Returns the number of native executions that hold a program slot."
  @spec active_runs() :: non_neg_integer()
  def active_runs, do: Kernel.program_active_runs_nif()

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

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
