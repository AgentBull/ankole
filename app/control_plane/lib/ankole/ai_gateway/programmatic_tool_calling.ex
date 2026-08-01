defmodule Ankole.AIGateway.ProgrammaticToolCalling do
  @moduledoc """
  Owns Programmatic Tool Calling declarations, contracts, history, and jobs.

  Tool Search can add deferred bindings to this plan, but it does not own the
  program wire format or execution lifecycle. StreamLoop remains the one owner
  of ordering across search and program effects.
  """

  alias Ankole.AIGateway.ResponseItems
  alias Ankole.AIGateway.ToolContract
  alias Ankole.AIGateway.ToolContract.Descriptor

  @tool_name "program"
  @contract_description_budget_bytes 32_768
  @fingerprint_prefix "ankole_ptc_v1."
  @fingerprint_max_bytes 16_384
  @fingerprint_payload_max_bytes 12_000
  @fingerprint_max_bindings 128
  @fingerprint_max_name_bytes 64
  @max_nested_tool_calls 256

  defmodule Plan do
    @moduledoc false

    alias Ankole.AIGateway.ToolContract.Descriptor

    defstruct enabled?: false, program: nil, resumes: []

    @type program :: %{
            tool_name: String.t(),
            bindings: [Descriptor.t()],
            synthesized_tool: map()
          }

    @type resume :: %{
            optional(:bindings) => [Descriptor.t()],
            call_id: String.t(),
            code: String.t(),
            fingerprint: String.t(),
            memo: [map()]
          }

    @type t :: %__MODULE__{
            enabled?: boolean(),
            program: program() | nil,
            resumes: [resume()]
          }
  end

  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  @spec new(boolean()) :: Plan.t()
  def new(enabled?), do: %Plan{enabled?: enabled?}

  @spec enabled?(Plan.t() | nil) :: boolean()
  def enabled?(%Plan{enabled?: enabled?}), do: enabled?
  def enabled?(_plan), do: false

  @spec response_stream_required?(Plan.t() | nil) :: boolean()
  def response_stream_required?(%Plan{program: program, resumes: resumes}),
    do: not is_nil(program) or resumes != []

  def response_stream_required?(_plan), do: false

  @spec active_tool_name(Plan.t() | nil) :: String.t() | nil
  def active_tool_name(%Plan{program: %{tool_name: tool_name}}), do: tool_name
  def active_tool_name(_plan), do: nil

  @spec provider_tool(Plan.t() | nil) :: map() | nil
  def provider_tool(%Plan{program: %{synthesized_tool: tool}}), do: tool
  def provider_tool(_plan), do: nil

  @spec append_provider_tool([map()], Plan.t()) :: [map()]
  def append_provider_tool(tools, %Plan{} = plan) do
    case provider_tool(plan) do
      nil -> tools
      tool -> tools ++ [tool]
    end
  end

  @spec resumes_pending?(Plan.t() | nil) :: boolean()
  def resumes_pending?(%Plan{resumes: [_ | _]}), do: true
  def resumes_pending?(_plan), do: false

  @spec take_resumes(Plan.t()) :: {[Plan.resume()], Plan.t()}
  def take_resumes(%Plan{resumes: rounds} = plan),
    do: {rounds, %{plan | resumes: []}}

  @spec split_declaration([map()]) :: {:ok, Plan.t(), [map()]} | {:error, term()}
  def split_declaration(tools) do
    case Enum.split_with(tools, &(Map.get(&1, "type") == "programmatic_tool_calling")) do
      {[], plain} -> {:ok, new(false), plain}
      {[_declaration], plain} -> {:ok, new(true), plain}
      {_multiple, _plain} -> {:error, {:invalid_program, :duplicate_declaration}}
    end
  end

  @spec partition_tools([Descriptor.t()], Plan.t()) :: {[Descriptor.t()], [Descriptor.t()]}
  def partition_tools(tools, %Plan{enabled?: enabled?}) do
    {direct_rev, bindings_rev} =
      Enum.reduce(tools, {[], []}, fn tool, {direct, bindings} ->
        callers = tool.allowed_callers
        direct? = "direct" in callers
        programmatic? = enabled? and "programmatic" in callers

        {
          if(direct?, do: [tool | direct], else: direct),
          if(programmatic?, do: [tool | bindings], else: bindings)
        }
      end)

    {Enum.reverse(direct_rev), Enum.reverse(bindings_rev)}
  end

  @spec build_plan(Plan.t(), [Descriptor.t()], ResponseItems.History.t()) ::
          {:ok, Plan.t()} | {:error, term()}
  def build_plan(%Plan{} = plan, bindings, %ResponseItems.History{} = history) do
    with {:ok, program} <- merge_program(nil, bindings, plan.enabled?),
         {:ok, resumes} <- resolve_resumes(history, program) do
      {:ok, %{plan | program: program, resumes: resumes}}
    end
  end

  @spec load_bindings(Plan.t(), [Descriptor.t()]) :: {:ok, Plan.t()} | {:error, term()}
  def load_bindings(%Plan{} = plan, bindings) do
    with {:ok, program} <- merge_program(plan.program, bindings, plan.enabled?) do
      {:ok, %{plan | program: program}}
    end
  end

  @spec ensure_no_collision([Descriptor.t()], [map()], Plan.t()) :: :ok | {:error, term()}
  def ensure_no_collision(_base_tools, _passthrough_tools, %Plan{program: nil}), do: :ok

  def ensure_no_collision(base_tools, passthrough_tools, %Plan{
        program: %{tool_name: tool_name}
      }) do
    collision? =
      Enum.any?(base_tools, &(&1.provider_name == tool_name)) or
        Enum.any?(passthrough_tools, &(Map.get(&1, "name") == tool_name))

    case collision? do
      false -> :ok
      true -> {:error, {:invalid_program, {:tool_name_collision, tool_name}}}
    end
  end

  defp merge_program(program, _bindings, false), do: {:ok, program}
  defp merge_program(%{} = program, [], true), do: {:ok, program}

  defp merge_program(program, bindings, true) do
    bindings =
      ((program && program.bindings) || [])
      |> Kernel.++(bindings)
      |> Enum.uniq_by(& &1.provider_name)

    with {:ok, synthesized_tool} <- synthesized_program_tool(bindings) do
      {:ok,
       %{
         tool_name: @tool_name,
         bindings: bindings,
         synthesized_tool: synthesized_tool
       }}
    end
  end

  defp synthesized_program_tool(bindings) do
    binding_names = Enum.map(bindings, & &1.provider_name)

    with :ok <- validate_program_binding_snapshot(binding_names) do
      {direct_bindings, programmatic_only_bindings} =
        Enum.split_with(bindings, &("direct" in &1.allowed_callers))

      direct_binding_names =
        direct_bindings
        |> Enum.map(& &1.provider_name)
        |> Enum.sort()
        |> Ankole.JSON.encode!()

      embedded_contracts =
        programmatic_only_bindings
        |> ToolContract.executable_snapshot()
        |> Ankole.JSON.encode!()

      description =
        "Runs JavaScript that orchestrates tool calls: loops, conditionals, " <>
          "parallel calls with Promise.all, and intermediate processing. " <>
          "The code runs in an isolated runtime without Node, network, " <>
          "filesystem, or timers. Call tools with `await tools[\"<name>\"](args)`; " <>
          "bindings with matching direct tool declarations: #{direct_binding_names}; " <>
          "programmatic-only bindings and contracts: #{embedded_contracts}. Emit results " <>
          "with `text(value)` or `image(url)`. tool_search is not callable " <>
          "from code; load deferred tools before starting a program."

      tool = %{
        "type" => "function",
        "name" => @tool_name,
        "description" => description,
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "code" => %{
              "type" => "string",
              "description" => "JavaScript source. Top-level await is available."
            }
          },
          "required" => ["code"],
          "additionalProperties" => false
        }
      }

      bytes = byte_size(description)

      if bytes <= @contract_description_budget_bytes do
        {:ok, tool}
      else
        {:error,
         {:invalid_program,
          {:program_contract_too_large, bytes, @contract_description_budget_bytes}}}
      end
    end
  end

  defp validate_program_binding_snapshot(binding_names) do
    case validate_fingerprint_binding_names(binding_names) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, {:invalid_program, {:program_binding_snapshot_invalid, reason}}}
    end
  end

  @spec call_item?(Plan.t() | nil, map()) :: boolean()
  def call_item?(
        %Plan{program: %{tool_name: tool_name}},
        %{"type" => "function_call", "name" => name}
      ),
      do: name == tool_name

  def call_item?(_plan, _item), do: false

  @spec parse_arguments(map()) :: %{code: String.t() | nil}
  def parse_arguments(%{} = item) do
    arguments = decode_arguments(Map.get(item, "arguments"))
    %{code: Map.get(arguments, "code")}
  end

  @spec public_item(Plan.t(), map()) :: map()
  def public_item(%Plan{program: %{bindings: bindings}}, %{} = call_item) do
    public_item_with_bindings(call_item, bindings)
  end

  @spec public_item_with_bindings(map(), [Descriptor.t()]) :: map()
  def public_item_with_bindings(%{} = call_item, bindings) when is_list(bindings) do
    %{code: code} = parse_arguments(call_item)

    item = %{
      "type" => "program",
      "id" => public_item_id(call_item, "prog"),
      "call_id" => Map.get(call_item, "call_id"),
      "code" => code,
      "status" => Map.get(call_item, "status", "completed")
    }

    if is_binary(code) and completed_item?(call_item) do
      Map.put(item, "fingerprint", fingerprint(code, bindings))
    else
      item
    end
  end

  @spec fingerprint(String.t(), [Descriptor.t()]) :: String.t()
  def fingerprint(code, bindings) when is_binary(code) and is_list(bindings) do
    binding_names = Enum.map(bindings, & &1.provider_name)

    payload = %{
      "bindings" => binding_names,
      "code_sha256" => sha256(code),
      "contracts_sha256" => ToolContract.fingerprint(bindings)
    }

    encoded_payload = Ankole.JSON.encode!(payload)
    fingerprint = @fingerprint_prefix <> Base.url_encode64(encoded_payload, padding: false)

    case validate_fingerprint_bounds(fingerprint, encoded_payload, binding_names) do
      :ok ->
        fingerprint

      {:error, reason} ->
        raise ArgumentError, "invalid program fingerprint snapshot: #{inspect(reason)}"
    end
  end

  @spec job(Plan.t(), map(), [map()]) :: {:ok, map()} | {:error, term()}
  def job(plan, call_item, memo \\ [])

  def job(%Plan{program: %{bindings: bindings}} = plan, %{} = call_item, memo) do
    public = public_item(plan, call_item)

    with :ok <- ResponseItems.validate_executable_call(public) do
      {:ok,
       %{
         call_id: public["call_id"],
         code: public["code"],
         fingerprint: public["fingerprint"],
         bindings: bindings,
         binding_names: Enum.map(bindings, & &1.provider_name),
         memo: memo
       }}
    end
  end

  def job(_plan, call_item, _memo),
    do: {:error, {:program_runtime_unavailable, Map.get(call_item, "call_id")}}

  @spec resume_job(Plan.t(), map()) :: {:ok, map()} | {:error, term()}
  def resume_job(%Plan{program: %{bindings: bindings}}, %{} = resume) do
    case frozen_program_bindings(resume.fingerprint, resume.code, bindings) do
      {:ok, frozen_bindings} ->
        {:ok,
         %{
           call_id: resume.call_id,
           code: resume.code,
           fingerprint: resume.fingerprint,
           bindings: frozen_bindings,
           binding_names: Enum.map(frozen_bindings, & &1.provider_name),
           memo: resume.memo
         }}

      {:error, _reason} ->
        {:error, {:program_fingerprint_mismatch, resume.call_id}}
    end
  end

  def resume_job(_plan, resume),
    do: {:error, {:program_runtime_unavailable, Map.get(resume, :call_id)}}

  @spec build_resume_jobs(Plan.t(), [Plan.resume()]) :: {:ok, [map()]}
  def build_resume_jobs(%Plan{} = plan, resumes) do
    jobs =
      Enum.map(resumes, fn resume ->
        case resume_job(plan, resume) do
          {:ok, job} ->
            job

          {:error, reason} ->
            %{
              call_id: resume.call_id,
              preflight_outcome: failed_outcome("program_contract_changed", reason)
            }
        end
      end)

    {:ok, jobs}
  end

  @spec build_jobs(Plan.t(), [map()]) :: {:ok, [map()]} | {:error, term()}
  def build_jobs(%Plan{} = plan, program_calls) do
    Enum.reduce_while(program_calls, {:ok, [], MapSet.new()}, fn call, {:ok, jobs_rev, seen} ->
      call_id = Map.get(call, "call_id")

      cond do
        MapSet.member?(seen, call_id) ->
          {:halt, {:error, {:duplicate_program_call_id, call_id}}}

        true ->
          case job(plan, call, []) do
            {:ok, job} ->
              {:cont, {:ok, [job | jobs_rev], MapSet.put(seen, call_id)}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, jobs_rev, _seen} ->
        {:ok, Enum.reverse(jobs_rev)}

      {:error, _reason} = error ->
        error
    end
  end

  @spec settle(Plan.t(), [map()], [map()]) ::
          {:ok, [map()], [map()], boolean()} | {:error, term()}
  def settle(%Plan{} = plan, programs, outcomes) do
    with :ok <- ensure_matching_outcomes(programs, outcomes) do
      settle_programs(plan, programs, outcomes)
    end
  end

  defp ensure_matching_outcomes(programs, outcomes)
       when is_list(programs) and is_list(outcomes) and length(programs) == length(outcomes) do
    if Enum.zip(programs, outcomes)
       |> Enum.all?(fn
         {%{call_id: call_id}, %{call_id: call_id, outcome: %{} = _outcome}} -> true
         _mismatch -> false
       end) do
      :ok
    else
      {:error, :program_outcome_identity_mismatch}
    end
  end

  defp ensure_matching_outcomes(_programs, _outcomes),
    do: {:error, :program_outcome_count_mismatch}

  defp settle_programs(plan, programs, outcomes) do
    Enum.zip(programs, outcomes)
    |> Enum.reduce_while({:ok, [], [], false}, fn
      {program, %{outcome: outcome}}, {:ok, public_rev, downstream_rev, paused?} ->
        case settle_program(plan, program, outcome) do
          {:ok, items, provider_items, current_paused?} ->
            {:cont,
             {:ok, Enum.reverse(items, public_rev), Enum.reverse(provider_items, downstream_rev),
              paused? or current_paused?}}

          {:error, reason} ->
            failed = failed_outcome("program_result_invalid", reason)
            output = public_output(program.call_id, failed)
            provider_output = downstream_output(program.call_id, failed)
            {:cont, {:ok, [output | public_rev], [provider_output | downstream_rev], paused?}}
        end
    end)
    |> case do
      {:ok, public_rev, downstream_rev, paused?} ->
        {:ok, Enum.reverse(public_rev), Enum.reverse(downstream_rev), paused?}

      {:error, _reason} = error ->
        error
    end
  end

  defp settle_program(plan, program, %{status: :pending} = outcome) do
    memo_offset = length(program.memo)
    pending = Map.get(outcome, :pending_calls, [])
    bindings = Map.get(program, :bindings, plan.program.bindings)

    if memo_offset + length(pending) > @max_nested_tool_calls do
      failed =
        failed_outcome(
          "program_continuation_limit_exceeded",
          "program exceeded #{@max_nested_tool_calls} nested tool calls"
        )

      {:ok, [public_output(program.call_id, failed)],
       [downstream_output(program.call_id, failed)], false}
    else
      with {:ok, nested} <- paused_program_items(bindings, program.call_id, outcome, memo_offset) do
        {:ok, nested, [], true}
      end
    end
  end

  defp settle_program(_plan, program, %{} = outcome) do
    {:ok, [public_output(program.call_id, outcome)],
     [downstream_output(program.call_id, outcome)], false}
  end

  defp paused_program_items(bindings, program_call_id, outcome, memo_offset) do
    outcome
    |> Map.get(:pending_calls, [])
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {call, index}, {:ok, items_rev} ->
      case nested_call(program_call_id, memo_offset + index, call, bindings) do
        {:ok, item} -> {:cont, {:ok, [item | items_rev]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, items_rev} -> {:ok, Enum.reverse(items_rev)}
      {:error, _reason} = error -> error
    end
  end

  @spec failed_outcome(String.t(), term()) :: map()
  def failed_outcome(code, reason) do
    %{
      status: :failed,
      output: [],
      pending_calls: [],
      error: format_reason(reason),
      error_code: code
    }
  end

  @spec output_reservations([map()]) :: [map()]
  def output_reservations(programs) do
    Enum.map(programs, fn program ->
      downstream_output(program.call_id, failed_outcome("program_output_reserved", ""))
    end)
  end

  @spec public_output(String.t(), map()) :: map()
  def public_output(call_id, outcome) do
    %{
      "type" => "program_output",
      "id" => public_item_id(%{"call_id" => call_id}, "prog_out"),
      "call_id" => call_id,
      "status" => if(outcome[:status] == :completed, do: "completed", else: "incomplete"),
      "result" => program_result(outcome)
    }
  end

  @spec downstream_output(String.t(), map()) :: map()
  def downstream_output(call_id, %{} = outcome) do
    body = %{
      "status" => if(outcome[:status] == :completed, do: "completed", else: "incomplete"),
      "result" => program_result(outcome)
    }

    %{
      "type" => "function_call_output",
      "call_id" => call_id,
      "output" => Ankole.JSON.encode!(body)
    }
  end

  @spec nested_call(String.t(), non_neg_integer(), map(), [Descriptor.t()]) ::
          {:ok, map()} | {:error, term()}
  def nested_call(program_call_id, index, %{name: provider_name, arguments: arguments}, bindings) do
    case Enum.find(bindings, &(&1.provider_name == provider_name)) do
      %Descriptor{type: "function"} = binding ->
        case Ankole.JSON.encode(arguments) do
          {:ok, encoded_arguments} ->
            {:ok,
             nested_call_base(program_call_id, index, binding)
             |> Map.put("type", "function_call")
             |> Map.put("arguments", encoded_arguments)}

          {:error, reason} ->
            {:error,
             {:invalid_program_tool_arguments, binding.provider_name, binding.type, reason}}
        end

      %Descriptor{type: "custom"} = binding when is_binary(arguments) ->
        {:ok,
         nested_call_base(program_call_id, index, binding)
         |> Map.put("type", "custom_tool_call")
         |> Map.put("input", arguments)}

      %Descriptor{} = binding ->
        {:error,
         {:invalid_program_tool_arguments, binding.provider_name, binding.type, arguments}}

      nil ->
        {:error, {:program_tool_not_allowed, provider_name}}
    end
  end

  defp nested_call_base(program_call_id, index, %Descriptor{} = binding) do
    %{
      "id" => "#{program_call_id}_fc#{index}",
      "call_id" => "#{program_call_id}_c#{index}",
      "name" => binding.name,
      "status" => "completed",
      "caller" => %{"type" => "program", "caller_id" => program_call_id}
    }
    |> maybe_put("namespace", binding.namespace)
  end

  @doc false
  @spec provider_history_item(term()) :: {:handled, map() | nil} | :unhandled
  def provider_history_item(%{"type" => "program"} = item) do
    call = %{
      "type" => "function_call",
      "name" => @tool_name,
      "call_id" => Map.get(item, "call_id"),
      "arguments" => Ankole.JSON.encode!(%{"code" => Map.get(item, "code") || ""}),
      "status" => "completed"
    }

    {:handled, call}
  end

  def provider_history_item(%{"type" => "program_output"} = item) do
    output = %{
      "type" => "function_call_output",
      "call_id" => Map.get(item, "call_id"),
      "output" => Ankole.JSON.encode!(Map.take(item, ["status", "result"]))
    }

    {:handled, output}
  end

  def provider_history_item(%{"caller" => %{"type" => "program"}}), do: {:handled, nil}
  def provider_history_item(_item), do: :unhandled

  @doc false
  @spec history_error(term(), map(), ResponseItems.t()) :: term()
  def history_error(reason, %{"type" => "program", "call_id" => call_id}, _ledger)
      when elem(reason, 0) in [
             :duplicate_history_item,
             :conflicting_call_pair,
             :conflicting_duplicate_item
           ],
      do: {:duplicate_program_call_id, call_id}

  def history_error(reason, %{"type" => "program_output", "call_id" => call_id}, _ledger)
      when elem(reason, 0) in [
             :duplicate_history_item,
             :conflicting_output_pair,
             :conflicting_duplicate_item
           ],
      do: {:duplicate_program_output, call_id}

  def history_error(
        reason,
        %{"type" => type, "call_id" => call_id, "caller" => %{"caller_id" => program_id}},
        _ledger
      )
      when type in ["function_call", "custom_tool_call"] and
             elem(reason, 0) in [
               :duplicate_history_item,
               :conflicting_call_pair,
               :conflicting_duplicate_item
             ],
      do: {:duplicate_nested_call_id, program_id, call_id}

  def history_error(
        reason,
        %{"type" => type, "call_id" => call_id, "caller" => %{"caller_id" => program_id}},
        _ledger
      )
      when type in ["function_call_output", "custom_tool_call_output"] and
             elem(reason, 0) in [
               :duplicate_history_item,
               :conflicting_output_pair,
               :conflicting_duplicate_item
             ],
      do: {:duplicate_program_call_output, program_id, call_id}

  def history_error(
        {:orphan_call_output, _pair_key, "program_output"},
        %{"call_id" => call_id},
        _ledger
      ),
      do: {:orphan_program_output, call_id}

  def history_error(
        {:orphan_call_output, _pair_key, _type},
        %{"call_id" => call_id, "caller" => %{"caller_id" => program_id}},
        ledger
      ) do
    if program_closed?(ledger, program_id),
      do: {:late_program_call_output, program_id, call_id},
      else: {:orphan_program_call_output, program_id, call_id}
  end

  def history_error(
        {:mismatched_call_output, _pair_key, _expected},
        %{"call_id" => call_id, "caller" => %{"caller_id" => program_id}},
        _ledger
      ),
      do: {:invalid_program_call_output, program_id, call_id, :type_mismatch}

  def history_error(
        {:mismatched_call_output_name, _pair_key},
        %{"call_id" => call_id, "caller" => %{"caller_id" => program_id}},
        _ledger
      ),
      do: {:invalid_program_call_output, program_id, call_id, :name_mismatch}

  def history_error(
        {:invalid_tool_call_output, _call_id},
        %{"call_id" => call_id, "caller" => %{"caller_id" => program_id}} = item,
        _ledger
      ) do
    detail = if Map.has_key?(item, "output"), do: :invalid_output, else: :missing_output
    {:invalid_program_call_output, program_id, call_id, detail}
  end

  def history_error(reason, _item, _ledger), do: reason

  defp program_closed?(ledger, program_id) do
    Enum.any?(ResponseItems.program_groups(ledger), fn group ->
      group.call_id == program_id and not is_nil(group.output)
    end)
  end

  defp resolve_resumes(%ResponseItems.History{} = history, program) do
    with :ok <- validate_program_children(history.entries),
         {:ok, groups} <- validate_program_groups(ResponseItems.program_groups(history.ledger)) do
      unsettled = Enum.reject(groups, & &1.output)

      cond do
        unsettled == [] ->
          {:ok, []}

        is_nil(program) ->
          {:error, {:invalid_program, :bindings_missing_for_resume}}

        true ->
          build_resumes(unsettled, program)
      end
    end
  end

  defp validate_program_children(entries) do
    Enum.reduce_while(entries, :ok, fn
      %{
        item:
          %{
            "type" => type,
            "caller" => %{"type" => "program"}
          } = item
      },
      :ok
      when type not in [
             "function_call",
             "custom_tool_call",
             "function_call_output",
             "custom_tool_call_output"
           ] ->
        {:halt,
         {:error,
          {:invalid_program,
           {:invalid_program_child, Map.get(item, "type"), Map.get(item, "call_id")}}}}

      _entry, :ok ->
        {:cont, :ok}
    end)
  end

  defp validate_program_groups(groups) do
    Enum.reduce_while(groups, {:ok, []}, fn group, {:ok, groups_rev} ->
      case validate_program_group(group) do
        {:ok, group} -> {:cont, {:ok, [group | groups_rev]}}
        {:error, reason} -> {:halt, {:error, {:invalid_program, reason}}}
      end
    end)
    |> case do
      {:ok, groups_rev} -> {:ok, Enum.reverse(groups_rev)}
      {:error, _reason} = error -> error
    end
  end

  defp validate_program_group(%{call_id: call_id, root: nil, children: [child | _rest]}) do
    {:error, {:orphan_program_call, call_id, child.call.item["call_id"]}}
  end

  defp validate_program_group(%{call_id: call_id, root: nil}) do
    {:error, {:orphan_program_output, call_id}}
  end

  defp validate_program_group(%{call_id: call_id, root: root} = group) do
    cond do
      not ResponseItems.executable_call?(root.item) ->
        {:error, {:incomplete_program, call_id}}

      child_before_root = Enum.find(group.children, &(&1.call.index < root.index)) ->
        {:error, {:orphan_program_call, call_id, child_before_root.call.item["call_id"]}}

      incomplete = Enum.find(group.children, &(not ResponseItems.executable_call?(&1.call.item))) ->
        {:error, {:incomplete_program_call, incomplete.call.item["call_id"]}}

      group.output ->
        validate_settled_program_group(group)

      Enum.any?(group.children, &is_nil(&1.output)) ->
        {:error, {:program_calls_unanswered, call_id}}

      true ->
        {:ok, group}
    end
  end

  defp validate_settled_program_group(group) do
    output_index = group.output.index

    cond do
      late_call = Enum.find(group.children, &(&1.call.index > output_index)) ->
        {:error, {:late_program_call, group.call_id, late_call.call.item["call_id"]}}

      late_output =
          Enum.find(group.children, fn child ->
            child.output && child.output.index > output_index
          end) ->
        {:error, {:late_program_call_output, group.call_id, late_output.call.item["call_id"]}}

      Enum.any?(group.children, &is_nil(&1.output)) ->
        {:error, {:program_calls_unanswered, group.call_id}}

      true ->
        {:ok, group}
    end
  end

  defp build_resumes(groups, program) do
    Enum.reduce_while(groups, {:ok, []}, fn group, {:ok, rounds_rev} ->
      call_id = group.call_id
      code = group.root.item["code"]
      fingerprint = group.root.item["fingerprint"]

      case frozen_program_bindings(fingerprint, code, program.bindings) do
        {:ok, frozen_bindings} ->
          with {:ok, calls} <- replay_calls(group.children),
               {:ok, memo} <- replay_memo(calls, frozen_bindings) do
            round = %{
              call_id: call_id,
              code: code,
              fingerprint: fingerprint,
              bindings: frozen_bindings,
              memo: memo
            }

            {:cont, {:ok, [round | rounds_rev]}}
          else
            {:error, reason} -> {:halt, {:error, {:invalid_program, {reason, call_id}}}}
          end

        {:error, _reason} ->
          round = %{call_id: call_id, code: code, fingerprint: fingerprint, memo: []}
          {:cont, {:ok, [round | rounds_rev]}}
      end
    end)
    |> case do
      {:ok, rounds_rev} -> {:ok, Enum.reverse(rounds_rev)}
      {:error, _reason} = error -> error
    end
  end

  defp replay_calls(children) do
    Enum.reduce_while(children, {:ok, []}, fn child, {:ok, calls_rev} ->
      item = child.call.item

      with {:ok, arguments} <- replay_tool_arguments(item) do
        call = %{
          item: item,
          call_id: Map.get(item, "call_id"),
          type: Map.get(item, "type"),
          name: replay_tool_name(item),
          arguments: arguments,
          output: child.output.item["output"]
        }

        {:cont, {:ok, [call | calls_rev]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, calls_rev} -> {:ok, Enum.reverse(calls_rev)}
      {:error, _reason} = error -> error
    end
  end

  defp replay_memo(calls, bindings) do
    bindings_by_name = Map.new(bindings, &{&1.provider_name, &1})

    case Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, memo_rev} ->
           case Map.get(bindings_by_name, call.name) do
             %Descriptor{} = binding ->
               with {:ok, output} <- ToolContract.decode_output(binding, call.output) do
                 entry = %{
                   "name" => call.name,
                   "arguments" => call.arguments,
                   "output" => output
                 }

                 {:cont, {:ok, [entry | memo_rev]}}
               else
                 {:error, reason} -> {:halt, {:error, reason}}
               end

             nil ->
               {:halt, {:error, {:binding_missing, call.name}}}
           end
         end) do
      {:ok, memo_rev} -> {:ok, Enum.reverse(memo_rev)}
      {:error, _reason} = error -> error
    end
  end

  defp replay_tool_name(%{"namespace" => namespace, "name" => name})
       when is_binary(namespace) and is_binary(name),
       do: ToolContract.provider_alias(namespace, name)

  defp replay_tool_name(item), do: Map.get(item, "name")

  defp replay_tool_arguments(%{"type" => "function_call"} = item) do
    case Ankole.JSON.decode(Map.get(item, "arguments")) do
      {:ok, arguments} ->
        {:ok, arguments}

      {:error, reason} ->
        {:error, {:invalid_program_tool_arguments_json, item["call_id"], reason}}
    end
  end

  defp replay_tool_arguments(%{"type" => "custom_tool_call"} = item),
    do: {:ok, Map.get(item, "input")}

  defp frozen_program_bindings(fingerprint, code, current_bindings)
       when is_binary(fingerprint) and is_binary(code) and is_list(current_bindings) do
    with :ok <- validate_fingerprint_token_size(fingerprint),
         {:ok, encoded_payload} <- fingerprint_payload(fingerprint),
         {:ok, payload_json} <- Base.url_decode64(encoded_payload, padding: false),
         :ok <- validate_fingerprint_payload_size(payload_json),
         {:ok, payload} <- Ankole.JSON.decode(payload_json),
         {:ok, binding_names, code_hash, contracts_hash} <- fingerprint_fields(payload),
         :ok <- validate_fingerprint_bounds(fingerprint, payload_json, binding_names),
         true <- code_hash == sha256(code),
         {:ok, frozen_bindings} <- select_frozen_bindings(binding_names, current_bindings),
         true <- contracts_hash == ToolContract.fingerprint(frozen_bindings) do
      {:ok, frozen_bindings}
    else
      _invalid_or_drifted -> {:error, :invalid_program_fingerprint}
    end
  end

  defp frozen_program_bindings(_fingerprint, _code, _current_bindings),
    do: {:error, :invalid_program_fingerprint}

  defp fingerprint_payload(fingerprint) do
    if String.starts_with?(fingerprint, @fingerprint_prefix) do
      prefix_bytes = byte_size(@fingerprint_prefix)
      payload_bytes = byte_size(fingerprint) - prefix_bytes

      if payload_bytes > 0 do
        {:ok, binary_part(fingerprint, prefix_bytes, payload_bytes)}
      else
        {:error, :invalid_program_fingerprint_payload}
      end
    else
      {:error, :unsupported_program_fingerprint_version}
    end
  end

  defp fingerprint_fields(%{} = payload) when map_size(payload) == 3 do
    case payload do
      %{
        "bindings" => binding_names,
        "code_sha256" => code_hash,
        "contracts_sha256" => contracts_hash
      } ->
        with :ok <- validate_sha256(code_hash),
             :ok <- validate_sha256(contracts_hash) do
          {:ok, binding_names, code_hash, contracts_hash}
        end

      _invalid_shape ->
        {:error, :invalid_program_fingerprint_payload}
    end
  end

  defp fingerprint_fields(_payload), do: {:error, :invalid_program_fingerprint_payload}

  defp validate_fingerprint_bounds(fingerprint, payload, binding_names) do
    with :ok <- validate_fingerprint_token_size(fingerprint),
         :ok <- validate_fingerprint_payload_size(payload),
         :ok <- validate_fingerprint_binding_names(binding_names) do
      :ok
    end
  end

  defp validate_fingerprint_token_size(fingerprint)
       when is_binary(fingerprint) and byte_size(fingerprint) <= @fingerprint_max_bytes,
       do: :ok

  defp validate_fingerprint_token_size(_fingerprint),
    do: {:error, :program_fingerprint_too_large}

  defp validate_fingerprint_payload_size(payload)
       when is_binary(payload) and byte_size(payload) <= @fingerprint_payload_max_bytes,
       do: :ok

  defp validate_fingerprint_payload_size(_payload),
    do: {:error, :program_fingerprint_payload_too_large}

  defp validate_fingerprint_binding_names(binding_names)
       when is_list(binding_names) and length(binding_names) <= @fingerprint_max_bindings do
    valid? =
      Enum.all?(binding_names, fn name ->
        is_binary(name) and name != "" and byte_size(name) <= @fingerprint_max_name_bytes
      end)

    cond do
      not valid? ->
        {:error, :invalid_program_fingerprint_binding_name}

      MapSet.size(MapSet.new(binding_names)) != length(binding_names) ->
        {:error, :duplicate_program_fingerprint_binding}

      true ->
        :ok
    end
  end

  defp validate_fingerprint_binding_names(_binding_names),
    do: {:error, :invalid_program_fingerprint_bindings}

  defp validate_sha256(hash) when is_binary(hash) and byte_size(hash) == 64 do
    if String.match?(hash, ~r/\A[0-9a-f]{64}\z/), do: :ok, else: {:error, :invalid_sha256}
  end

  defp validate_sha256(_hash), do: {:error, :invalid_sha256}

  defp select_frozen_bindings(binding_names, current_bindings) do
    current_names =
      Enum.map(current_bindings, fn
        %Descriptor{provider_name: provider_name} -> provider_name
        _invalid -> nil
      end)

    cond do
      Enum.any?(current_names, &is_nil/1) ->
        {:error, :invalid_current_program_bindings}

      MapSet.size(MapSet.new(current_names)) != length(current_names) ->
        {:error, :duplicate_current_program_binding}

      true ->
        current_by_name = Map.new(Enum.zip(current_names, current_bindings))

        case Enum.reduce_while(binding_names, {:ok, []}, fn provider_name, {:ok, selected_rev} ->
               case Map.get(current_by_name, provider_name) do
                 %Descriptor{allowed_callers: callers} = binding when is_list(callers) ->
                   if "programmatic" in callers do
                     {:cont, {:ok, [binding | selected_rev]}}
                   else
                     {:halt, {:error, {:binding_not_programmatic, provider_name}}}
                   end

                 nil ->
                   {:halt, {:error, {:binding_missing, provider_name}}}
               end
             end) do
          {:ok, selected_rev} -> {:ok, Enum.reverse(selected_rev)}
          {:error, _reason} = error -> error
        end
    end
  end

  defp program_result(outcome) do
    parts =
      outcome
      |> Map.get(:output, [])
      |> Enum.map(fn part -> %{"kind" => part[:kind], "value" => part[:value]} end)

    case {parts, outcome[:error]} do
      {[%{"kind" => "text", "value" => value}], nil} when is_binary(value) -> value
      {parts, nil} -> Ankole.JSON.encode!(parts)
      {parts, error} -> Ankole.JSON.encode!(%{"error" => error, "output" => parts})
    end
  end

  defp decode_arguments(arguments) when is_map(arguments), do: arguments

  defp decode_arguments(arguments) when is_binary(arguments) do
    case Ankole.JSON.decode(arguments) do
      {:ok, %{} = decoded} -> decoded
      _invalid -> %{"query" => arguments}
    end
  end

  defp decode_arguments(_arguments), do: %{}

  defp completed_item?(item), do: Map.get(item, "status") in [nil, "completed"]

  defp public_item_id(item, prefix) do
    case Map.get(item, "id") do
      id when is_binary(id) and id != "" ->
        id

      _missing ->
        seed = Map.get(item, "call_id") || Ankole.JSON.encode!(item)
        digest = :crypto.hash(:sha256, seed) |> Base.encode16(case: :lower) |> binary_part(0, 20)
        "#{prefix}_#{digest}"
    end
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp maybe_put(map, _key, nil), do: map

  defp maybe_put(map, key, value) when is_binary(value) and value != "",
    do: Map.put(map, key, value)

  defp maybe_put(map, _key, _value), do: map
end
