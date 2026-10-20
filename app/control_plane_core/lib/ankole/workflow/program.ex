defmodule Ankole.Workflow.Program do
  @moduledoc false

  alias Ankole.Workflow.Schemas.Run

  @terminal_call_statuses ~w(succeeded failed)

  @type pending_call :: %{
          required(:namespace) => String.t() | nil,
          required(:name) => String.t(),
          required(:arguments) => term()
        }

  @type new_call :: %{
          required(:call_seq) => non_neg_integer(),
          required(:arguments) => map()
        }

  @doc false
  @spec source(struct()) :: {:ok, String.t()} | {:error, term()}
  def source(%Run{args: args, script: script}) when is_map(args) and is_binary(script) do
    with {:ok, args_json} <- Torque.encode(args) do
      {:ok,
       IO.iodata_to_binary([
         "\"use strict\";\n",
         "const args = ",
         args_json,
         ";\n",
         "const agent = (prompt, opts = {}) => {\n",
         "  if (typeof prompt !== \"string\" || prompt.trim() === \"\") {\n",
         "    throw new Error(\"agent(prompt, opts) needs a non-empty prompt string\");\n",
         "  }\n",
         "  return tools.agent({ prompt, ...opts }).then((r) => (r && r.ok ? r.value : null));\n",
         "};\n",
         "const __wf_value = await (async () => {\n",
         script,
         "\n})();\n",
         "if (__wf_value !== undefined) {\n",
         "  text(typeof __wf_value === \"string\" ? __wf_value : JSON.stringify(__wf_value));\n",
         "}\n"
       ])}
    end
  end

  @doc false
  @spec memo_prefix([struct()]) :: {[map()], non_neg_integer()}
  def memo_prefix(calls) when is_list(calls) do
    calls
    |> Enum.sort_by(& &1.call_seq)
    |> Enum.take_while(&(&1.status in @terminal_call_statuses))
    |> Enum.map(fn call ->
      %{
        "namespace" => nil,
        "name" => "agent",
        "arguments" => call.arguments,
        "output" => call.result
      }
    end)
    |> then(&{&1, length(&1)})
  end

  @doc false
  @spec stall_diff([struct()], [pending_call()], pos_integer()) ::
          {:ok, %{memo_length: non_neg_integer(), new_calls: [new_call()]}}
          | {:error, term()}
  def stall_diff(calls, pending_calls, max_agent_calls)
      when is_list(calls) and is_list(pending_calls) and is_integer(max_agent_calls) and
             max_agent_calls > 0 do
    calls = Enum.sort_by(calls, & &1.call_seq)
    {_memo, memo_length} = memo_prefix(calls)

    with :ok <- validate_stored_sequence(calls),
         {:ok, pending_calls} <- normalize_pending_calls(pending_calls),
         :ok <- enforce_agent_limit(calls, memo_length, pending_calls, max_agent_calls),
         {:ok, new_calls} <- diff_pending(calls, memo_length, pending_calls) do
      {:ok, %{memo_length: memo_length, new_calls: new_calls}}
    end
  end

  defp validate_stored_sequence(calls) do
    calls
    |> Enum.map(& &1.call_seq)
    |> Enum.with_index()
    |> Enum.find(fn {call_seq, expected} -> call_seq != expected end)
    |> case do
      nil -> :ok
      {call_seq, expected} -> replay_diverged(expected, call_seq, :stored_sequence)
    end
  end

  defp normalize_pending_calls(pending_calls) do
    pending_calls
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {%{namespace: nil, name: "agent", arguments: arguments}, _index}, {:ok, acc}
      when is_map(arguments) ->
        {:cont, {:ok, [arguments | acc]}}

      {_pending, index}, {:ok, _acc} ->
        {:halt, replay_diverged(index, nil, :invalid_pending_call)}
    end)
    |> case do
      {:ok, arguments} -> {:ok, Enum.reverse(arguments)}
      {:error, _reason} = error -> error
    end
  end

  defp enforce_agent_limit(calls, memo_length, pending_calls, maximum) do
    used = max(length(calls), memo_length + length(pending_calls))

    if used <= maximum,
      do: :ok,
      else: {:error, {:workflow_agent_limit_exceeded, %{used: used, max: maximum}}}
  end

  defp diff_pending(calls, memo_length, pending_arguments) do
    existing = Map.new(calls, &{&1.call_seq, &1.arguments})

    result =
      pending_arguments
      |> Enum.with_index(memo_length)
      |> Enum.reduce_while({:ok, []}, fn {arguments, call_seq}, {:ok, new_calls} ->
        case Map.fetch(existing, call_seq) do
          {:ok, ^arguments} ->
            {:cont, {:ok, new_calls}}

          {:ok, stored_arguments} ->
            {:halt, replay_diverged(call_seq, stored_arguments, arguments)}

          :error ->
            {:cont, {:ok, [%{call_seq: call_seq, arguments: arguments} | new_calls]}}
        end
      end)

    with {:ok, new_calls} <- result,
         :ok <- reject_unmatched_stored_calls(existing, memo_length, length(pending_arguments)) do
      {:ok, Enum.reverse(new_calls)}
    end
  end

  defp reject_unmatched_stored_calls(existing, memo_length, pending_count) do
    first_unmatched = memo_length + pending_count

    existing
    |> Map.keys()
    |> Enum.filter(&(&1 >= first_unmatched))
    |> Enum.min(fn -> nil end)
    |> case do
      nil -> :ok
      call_seq -> replay_diverged(call_seq, Map.fetch!(existing, call_seq), :missing_pending_call)
    end
  end

  defp replay_diverged(call_seq, stored, replayed) do
    {:error,
     {:workflow_replay_diverged, %{call_seq: call_seq, stored: stored, replayed: replayed}}}
  end
end
