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

  @type memo_entry :: %{
          required(String.t()) => term()
        }

  @type outcome :: %{
          required(:status) => :completed | :pending | :failed,
          required(:output) => [%{kind: String.t(), value: String.t()}],
          required(:pending_calls) => [%{name: String.t(), arguments: map()}],
          required(:error) => String.t() | nil
        }

  @doc """
  Runs one program and returns its outcome.

  `tools` lists the binding names available as `tools.<name>(args)` inside the
  program. `memo` entries answer replayed calls in order:
  `%{"name" => name, "arguments" => args, "output" => output}`.
  """
  @spec run(String.t(), [String.t()], [memo_entry()], keyword()) ::
          {:ok, outcome()} | {:error, String.t()}
  def run(program, tools, memo, opts \\ [])
      when is_binary(program) and is_list(tools) and is_list(memo) do
    request =
      %{
        "program" => program,
        "tools" => tools,
        "memo" => memo
      }
      |> put_option("timeout_ms", Keyword.get(opts, :timeout_ms))
      |> put_option("heap_limit_bytes", Keyword.get(opts, :heap_limit_bytes))

    with {:ok, request_json} <- Torque.encode(request),
         outcome_json when is_binary(outcome_json) <- Kernel.program_run_nif(request_json),
         {:ok, outcome} <- Torque.decode(outcome_json) do
      {:ok, decode_outcome(outcome)}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp put_option(request, _key, nil), do: request
  defp put_option(request, key, value), do: Map.put(request, key, value)

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
        |> Enum.map(&%{name: &1["name"], arguments: &1["arguments"] || %{}}),
      error: outcome["error"]
    }
  end

  defp decode_status("completed"), do: :completed
  defp decode_status("pending"), do: :pending
  defp decode_status(_status), do: :failed
end
