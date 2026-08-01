defmodule Ankole.AIGateway.ToolSearch.StreamLoop do
  @moduledoc """
  Per-stream tool search state over one public response.

  The loop rewrites provider `function_call` events for the synthesized search
  tool into public `tool_search_call` items, executes server-mode searches, and
  turns intermediate provider terminals into continuation rounds. One public
  response can span several provider responses; the loop renumbers public
  events and accumulates raw provider items for the continuation input.

  Internal rounds share one budget: search and program continuations cannot
  amplify provider spend independently.
  """

  alias Ankole.AIGateway.ProgrammaticToolCalling, as: PTC
  alias Ankole.AIGateway.ResponseItems
  alias Ankole.AIGateway.ToolSearch

  @max_internal_rounds 16
  @max_top_level_programs 8
  @max_provider_history_items 1_024
  @max_provider_history_bytes 8 * 1024 * 1024

  @default_limits %{
    top_level_programs: @max_top_level_programs,
    provider_history_items: @max_provider_history_items,
    provider_history_bytes: @max_provider_history_bytes
  }

  defstruct plan: nil,
            provider_request: nil,
            provider_items_rev: [],
            current_round_items_rev: [],
            provider_history_count: 0,
            provider_history_item_bytes: 0,
            provider_history_error: nil,
            downstream_tools: nil,
            suppressed_item_ids: MapSet.new(),
            usage: nil,
            tool_usage: nil,
            rounds: 0,
            sequence: -1,
            incomplete_reason: nil,
            limits: @default_limits

  @type t :: %__MODULE__{}

  @spec new(t() | map() | nil) :: t() | nil
  def new(nil), do: nil
  def new(%__MODULE__{} = loop), do: loop

  def new(%{plan: %ToolSearch.Plan{} = plan, provider_request: %{} = provider_request}) do
    base_items = provider_request |> Map.get("input") |> input_items()
    {base_count, base_bytes, history_error} = initial_history_stats(base_items)

    %__MODULE__{
      plan: plan,
      provider_request: provider_request,
      downstream_tools: ToolSearch.list_tools(provider_request),
      provider_history_count: base_count,
      provider_history_item_bytes: base_bytes,
      provider_history_error: history_error
    }
  end

  @doc "Returns whether this loop executes built-in effects inside AIGateway."
  @spec gateway_effects?(t() | nil) :: boolean()
  def gateway_effects?(%__MODULE__{plan: plan}), do: ToolSearch.response_stream_required?(plan)

  def gateway_effects?(_loop), do: false

  @doc "Applies the remaining public built-in tool budget to one provider round."
  @spec apply_tool_budget(t() | ToolSearch.Plan.t() | nil, map(), non_neg_integer() | nil) ::
          map()
  def apply_tool_budget(_loop_or_plan, %{} = request, nil), do: request

  def apply_tool_budget(loop_or_plan, %{} = request, 0),
    do: disable_budgeted_effects(loop_or_plan, request)

  def apply_tool_budget(_loop_or_plan, %{} = request, remaining)
      when is_integer(remaining) and remaining > 0,
      do: Map.put(request, "max_tool_calls", remaining)

  @doc "Removes all built-in tools after the public tool budget is exhausted."
  @spec disable_budgeted_effects(t() | ToolSearch.Plan.t() | nil, map()) :: map()
  def disable_budgeted_effects(%__MODULE__{plan: plan}, %{} = request),
    do: disable_budgeted_effects(plan, request)

  def disable_budgeted_effects(plan, %{} = request)
      when is_nil(plan) or is_struct(plan, ToolSearch.Plan) do
    names =
      [plan && plan.tool_name, plan && PTC.active_tool_name(plan.ptc)]
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    tools =
      request
      |> ToolSearch.list_tools()
      |> Enum.reject(fn tool ->
        MapSet.member?(names, Map.get(tool, "name")) or
          ResponseItems.budgeted_tool_declaration?(tool)
      end)

    request
    |> Map.delete("max_tool_calls")
    |> ToolSearch.put_tools(tools)
    |> disable_removed_tool_choice(names, tools)
  end

  @doc """
  Returns whether the loop has a local effect before its first provider round.
  """
  @spec initial_local_effect?(t() | nil) :: boolean()
  def initial_local_effect?(%__MODULE__{plan: %ToolSearch.Plan{ptc: ptc}}),
    do: PTC.resumes_pending?(ptc)

  def initial_local_effect?(_loop), do: false

  @doc """
  Takes and freezes the local effects that precede the first provider round.
  """
  @spec take_initial_local_effect(t()) :: {:ok, [map()], map(), t()}
  def take_initial_local_effect(
        %__MODULE__{plan: %ToolSearch.Plan{ptc: %PTC.Plan{resumes: [_ | _]}} = plan} = loop
      ) do
    {resumes, ptc} = PTC.take_resumes(plan.ptc)
    loop = %{loop | plan: %{plan | ptc: ptc}}

    {:ok, programs} = PTC.build_resume_jobs(plan.ptc, resumes)

    {programs, loop} = preflight_resume_jobs(loop, programs)

    {:ok, programs, %{programs: programs}, loop}
  end

  defp preflight_resume_jobs(loop, programs) do
    condition =
      cond do
        length(programs) > loop.limits.top_level_programs ->
          {:error,
           {:program_batch_limit_exceeded, length(programs), loop.limits.top_level_programs}}

        true ->
          provider_history_size(loop, PTC.output_reservations(programs))
      end

    case condition do
      {:ok, _count, _bytes, _item_bytes} ->
        {programs, loop}

      {:error, reason} ->
        preflight = PTC.failed_outcome("program_admission_failed", reason)

        {Enum.map(programs, &Map.put(&1, :preflight_outcome, preflight)),
         mark_incomplete(loop, reason_code(reason))}
    end
  end

  @doc """
  Applies one batch of local program outcomes regardless of where that batch
  occurs in the public response loop.
  """
  @spec complete_local_effect(t(), map(), [map()]) ::
          {:round, map(), [map()], t()}
          | {:finalize, [map()], [map()], t()}
          | {:error, term(), t()}
  def complete_local_effect(%__MODULE__{} = loop, %{programs: programs} = context, outcomes) do
    with {:ok, program_items, downstream, paused?} <-
           PTC.settle(loop.plan.ptc, programs, outcomes) do
      extra_items = Map.get(context, :search_outputs, []) ++ program_items

      case remember_provider_items(loop, downstream) do
        {:ok, loop} ->
          complete_remembered_local_effect(loop, context, programs, extra_items, paused?)

        {:error, reason} ->
          loop = mark_incomplete(loop, reason_code(reason))
          {:finalize, local_effect_terminal_output(loop, context, programs), extra_items, loop}
      end
    else
      {:error, reason} -> {:error, reason, mark_incomplete(loop, reason_code(reason))}
    end
  end

  defp complete_remembered_local_effect(loop, context, programs, extra_items, paused?) do
    cond do
      Map.has_key?(context, :output) and (paused? or Map.get(context, :pending_client?, false)) ->
        {:finalize, local_effect_terminal_output(loop, context, programs), extra_items, loop}

      not Map.has_key?(context, :output) and
          (paused? or not is_nil(loop.incomplete_reason)) ->
        {:finalize, [], extra_items, loop}

      true ->
        continue_round(loop, extra_items)
    end
  end

  defp local_effect_terminal_output(loop, %{output: output}, programs),
    do: rewrite_items(loop, output, programs)

  defp local_effect_terminal_output(_loop, _context, _programs), do: []

  @doc """
  Rewrites or suppresses one provider event before public observation.

  Suppression covers the argument streaming of the synthesized search tool and
  the per-round admission lifecycle of continuation rounds; the public stream
  keeps one response lifecycle.
  """
  @terminal_event_types ~w(response.completed response.failed response.incomplete)

  @spec observe(t(), map()) :: {:emit, map(), t()} | {:suppress, t()}
  def observe(%__MODULE__{} = loop, %{"type" => type} = event) do
    cond do
      type in ["response.created", "response.queued", "response.in_progress"] and
          loop.rounds > 0 ->
        {:suppress, loop}

      # Terminal events are numbered by the terminal path after any appended
      # loop items, so their sequence stays behind the items they follow.
      type in @terminal_event_types ->
        {:emit, event, loop}

      type == "response.output_item.added" ->
        observe_item_added(loop, event)

      suppressed_delta?(loop, event) ->
        {:suppress, loop}

      type == "response.output_item.done" ->
        observe_item_done(loop, event)

      true ->
        {:emit, renumber(event, loop), bump_sequence(loop, event)}
    end
  end

  @doc """
  Decides what one provider terminal means for the public response.

  Returns `{:finalize, output_items, extra_public_items, loop}` when the public
  response ends here, or `{:round, continuation_request, public_items, loop}`
  when AIGateway must run another provider round in the same public response.

  A terminal that carries both server search calls and pending client-owned
  calls executes the searches and still finalizes: the client must answer its
  own calls, and the recorded `tool_search_output` items replay the loaded
  tools into the next request.
  """
  @spec intercept_terminal(t(), String.t(), map()) ::
          {:finalize, [map()], [map()], t()}
          | {:round, map(), [map()], t()}
          | {:local, [map()], map(), t()}
  def intercept_terminal(%__MODULE__{} = loop, event_type, %{} = response) do
    loop = accumulate_usage(loop, response)
    output = terminal_output(loop, response)

    case remember_provider_items(loop, output) do
      {:ok, loop} ->
        intercept_remembered_terminal(loop, event_type, output)

      {:error, reason} ->
        {:finalize, rewrite_items(loop, output), [], mark_incomplete(loop, reason_code(reason))}
    end
  end

  defp intercept_remembered_terminal(loop, event_type, output) do
    search_calls =
      if loop.plan.execution == :server,
        do: Enum.filter(output, &ToolSearch.search_call_item?(loop.plan, &1)),
        else: []

    program_calls = Enum.filter(output, &PTC.call_item?(loop.plan.ptc, &1))
    internal_calls? = search_calls != [] or program_calls != []

    cond do
      event_type != "response.completed" or not internal_calls? ->
        {:finalize, rewrite_items(loop, output), [], loop}

      loop.rounds >= @max_internal_rounds ->
        {:finalize, rewrite_items(loop, output), [],
         mark_incomplete(loop, "tool_loop_rounds_exhausted")}

      length(program_calls) > loop.limits.top_level_programs ->
        {:finalize, rewrite_items(loop, output), [],
         mark_incomplete(loop, "program_batch_limit_exceeded")}

      true ->
        # Program bindings are frozen before Tool Search can load anything in
        # this terminal. One program therefore cannot gain capabilities based
        # on provider item ordering.
        with {:ok, programs} <- PTC.build_jobs(loop.plan.ptc, program_calls),
             {:ok, parsed_search_calls} <- validate_search_calls(loop.plan, search_calls),
             {:ok, loop, executed_searches} <-
               execute_search_calls(loop, parsed_search_calls) do
          search_outputs = search_output_items(loop, executed_searches)
          pending_client? = Enum.any?(output, &pending_client_call?(loop, &1))

          cond do
            programs != [] ->
              case provider_history_size(loop, PTC.output_reservations(programs)) do
                {:ok, _count, _bytes, _item_bytes} ->
                  context = %{
                    output: output,
                    search_outputs: search_outputs,
                    programs: programs,
                    pending_client?: pending_client?
                  }

                  {:local, programs, context, loop}

                {:error, reason} ->
                  {:finalize, rewrite_items(loop, output, programs), search_outputs,
                   mark_incomplete(loop, reason_code(reason))}
              end

            pending_client? ->
              {:finalize, rewrite_items(loop, output), search_outputs, loop}

            true ->
              continue_round(loop, search_outputs)
          end
        else
          {:error, reason} ->
            {:finalize, rewrite_items(loop, output), [],
             mark_incomplete(loop, reason_code(reason))}
        end
    end
  end

  # Client-owned calls the gateway cannot answer: ordinary function or custom
  # calls, plus client-mode search calls.
  defp pending_client_call?(loop, item) do
    ResponseItems.client_call_item?(item) and
      cond do
        PTC.call_item?(loop.plan.ptc, item) -> false
        not ToolSearch.search_call_item?(loop.plan, item) -> true
        true -> loop.plan.execution == :client
      end
  end

  defp validate_search_calls(plan, search_calls) do
    Enum.reduce_while(
      search_calls,
      {:ok, MapSet.new(), []},
      fn call, {:ok, seen, parsed_calls_rev} ->
        public = ToolSearch.public_search_call(plan, call)
        provider_call_id = Map.get(call, "call_id")

        cond do
          not ResponseItems.executable_call?(public) ->
            {:halt, {:error, {:incomplete_tool_search_call, provider_call_id}}}

          not is_binary(provider_call_id) or provider_call_id == "" ->
            {:halt, {:error, {:invalid_provider_search_call_id, provider_call_id}}}

          MapSet.member?(seen, provider_call_id) ->
            {:halt, {:error, {:duplicate_tool_search_call_id, provider_call_id}}}

          true ->
            case ToolSearch.parse_search_arguments(plan, call) do
              {:ok, selection} ->
                {:cont,
                 {:ok, MapSet.put(seen, provider_call_id), [{call, selection} | parsed_calls_rev]}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end
        end
      end
    )
    |> case do
      {:ok, _seen, parsed_calls_rev} -> {:ok, Enum.reverse(parsed_calls_rev)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns the explicit reason why an internal loop must terminate incomplete.
  """
  @spec incomplete_reason(t() | nil) :: String.t() | nil
  def incomplete_reason(%__MODULE__{incomplete_reason: reason}), do: reason
  def incomplete_reason(_loop), do: nil

  defp mark_incomplete(loop, reason), do: %{loop | incomplete_reason: reason}

  defp reason_code(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
       do: reason |> elem(0) |> Atom.to_string()

  defp reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code(_reason), do: "tool_loop_invalid_state"

  @doc """
  Returns the accumulated usage across provider rounds, or `nil` for a single
  round where the provider value passes through unchanged.
  """
  @spec accumulated_usage(t() | nil) :: map() | nil
  def accumulated_usage(%__MODULE__{rounds: rounds, usage: usage}) when rounds > 0, do: usage
  def accumulated_usage(_loop), do: nil

  @doc """
  Returns native tool usage accumulated across provider rounds.
  """
  @spec accumulated_tool_usage(t() | nil) :: map() | nil
  def accumulated_tool_usage(%__MODULE__{rounds: rounds, tool_usage: usage}) when rounds > 0,
    do: usage

  def accumulated_tool_usage(_loop), do: nil

  @doc false
  @spec next_sequence(t()) :: non_neg_integer()
  def next_sequence(%__MODULE__{sequence: sequence}), do: sequence + 1

  @doc false
  @spec bump(t()) :: t()
  def bump(%__MODULE__{} = loop), do: %{loop | sequence: loop.sequence + 1}

  # ─────────────────────────────────────────────────────────────────
  # Event observation
  # ─────────────────────────────────────────────────────────────────

  defp observe_item_added(loop, %{"item" => %{} = item} = event) do
    if rewritable_call_item?(loop, item) do
      {:suppress, remember_suppressed(loop, item)}
    else
      event = Map.put(event, "item", ToolSearch.public_function_call(loop.plan, item))
      {:emit, renumber(event, loop), bump_sequence(loop, event)}
    end
  end

  defp observe_item_added(loop, event),
    do: {:emit, renumber(event, loop), bump_sequence(loop, event)}

  defp observe_item_done(loop, %{"item" => %{} = item} = event) do
    loop = %{loop | current_round_items_rev: [item | loop.current_round_items_rev]}

    if rewritable_call_item?(loop, item) do
      event = event |> Map.put("item", rewrite_call_item(loop, item)) |> renumber(loop)
      {:emit, event, bump_sequence(loop, event)}
    else
      event = Map.put(event, "item", ToolSearch.public_function_call(loop.plan, item))
      {:emit, renumber(event, loop), bump_sequence(loop, event)}
    end
  end

  defp observe_item_done(loop, event),
    do: {:emit, renumber(event, loop), bump_sequence(loop, event)}

  defp rewritable_call_item?(loop, item) do
    ToolSearch.search_call_item?(loop.plan, item) or
      PTC.call_item?(loop.plan.ptc, item)
  end

  defp rewrite_call_item(loop, item) do
    cond do
      ToolSearch.search_call_item?(loop.plan, item) ->
        ToolSearch.public_search_call(loop.plan, item)

      PTC.call_item?(loop.plan.ptc, item) ->
        PTC.public_item(loop.plan.ptc, item)

      true ->
        ToolSearch.public_function_call(loop.plan, item)
    end
  end

  defp suppressed_delta?(loop, event) do
    case Map.get(event, "item_id") do
      item_id when is_binary(item_id) -> MapSet.member?(loop.suppressed_item_ids, item_id)
      _missing -> false
    end
  end

  defp remember_suppressed(loop, item) do
    case Map.get(item, "id") do
      item_id when is_binary(item_id) and item_id != "" ->
        %{loop | suppressed_item_ids: MapSet.put(loop.suppressed_item_ids, item_id)}

      _missing ->
        loop
    end
  end

  # Public sequence numbers restart per provider round; the loop renumbers all
  # public events monotonically so one response has one sequence.
  defp renumber(event, loop) do
    case Map.get(event, "sequence_number") do
      nil -> event
      _sequence -> Map.put(event, "sequence_number", loop.sequence + 1)
    end
  end

  defp bump_sequence(loop, event) do
    case Map.get(event, "sequence_number") do
      nil -> loop
      _sequence -> bump(loop)
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Server rounds
  # ─────────────────────────────────────────────────────────────────

  # The public `tool_search_call` and `program` call items were already emitted
  # when their `response.output_item.done` events passed through, so a round
  # only adds the executed output items.
  defp continue_round(loop, extras) do
    continuation_request =
      loop.provider_request
      |> Map.put("input", continuation_input(loop))
      |> ToolSearch.put_tools(loop.downstream_tools)

    {:round, continuation_request, extras, begin_next_round(loop)}
  end

  defp begin_next_round(loop) do
    %{
      loop
      | rounds: loop.rounds + 1,
        suppressed_item_ids: MapSet.new(),
        current_round_items_rev: []
    }
  end

  defp search_output_items(loop, executed) do
    Enum.map(executed, fn {call_item, loaded} ->
      ToolSearch.public_search_output(loop.plan, call_item, loaded)
    end)
  end

  defp execute_search_calls(loop, parsed_search_calls) do
    result =
      Enum.reduce_while(
        parsed_search_calls,
        {:ok, loop, [], []},
        fn {call_item, %{paths: paths}}, {:ok, loop, executed, downstream_outputs} ->
          with {:ok, loaded} <- ToolSearch.search_paths(loop.plan, paths),
               {:ok, plan, downstream_tools} <-
                 ToolSearch.load_tools(loop.plan, loop.downstream_tools, loaded) do
            downstream_output = ToolSearch.downstream_search_output(call_item, loaded)
            loop = %{loop | plan: plan, downstream_tools: downstream_tools}

            {:cont,
             {:ok, loop, [{call_item, loaded} | executed],
              [downstream_output | downstream_outputs]}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end
      )

    case result do
      {:ok, loop, executed, downstream_outputs} ->
        with {:ok, loop} <- remember_provider_items(loop, Enum.reverse(downstream_outputs)) do
          {:ok, loop, Enum.reverse(executed)}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp continuation_input(loop) do
    original = loop.provider_request |> Map.get("input") |> input_items()
    original ++ Enum.reverse(loop.provider_items_rev)
  end

  defp input_items(input) when is_list(input), do: input

  defp input_items(input) when is_binary(input) do
    [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => input}]
      }
    ]
  end

  defp input_items(_input), do: []

  defp disable_removed_tool_choice(request, names, tools) do
    choice = Map.get(request, "tool_choice")

    cond do
      tools == [] ->
        Map.put(request, "tool_choice", "none")

      match?(%{"type" => "allowed_tools", "tools" => allowed} when is_list(allowed), choice) ->
        filter_allowed_tool_choice(request, choice, names)

      chosen_tool_removed?(choice, names) ->
        Map.put(request, "tool_choice", "auto")

      true ->
        request
    end
  end

  defp filter_allowed_tool_choice(request, choice, names) do
    allowed = Enum.reject(choice["tools"], &chosen_tool_removed?(&1, names))

    if allowed == [] do
      Map.put(request, "tool_choice", "none")
    else
      Map.put(request, "tool_choice", Map.put(choice, "tools", allowed))
    end
  end

  defp chosen_tool_removed?(%{} = choice, names) do
    ResponseItems.budgeted_tool_choice?(choice) or
      choice_name_removed?(choice, names)
  end

  defp chosen_tool_removed?(_choice, _names), do: false

  defp choice_name_removed?(%{"name" => name}, names), do: MapSet.member?(names, name)

  defp choice_name_removed?(%{"function" => %{"name" => name}}, names),
    do: MapSet.member?(names, name)

  defp choice_name_removed?(_choice, _names), do: false

  defp remember_provider_items(loop, items) do
    case provider_history_size(loop, items) do
      {:ok, count, _bytes, item_bytes} ->
        {:ok,
         %{
           loop
           | provider_items_rev: Enum.reverse(items, loop.provider_items_rev),
             provider_history_count: count,
             provider_history_item_bytes: loop.provider_history_item_bytes + item_bytes
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp provider_history_size(loop, new_items) do
    count = loop.provider_history_count + length(new_items)

    cond do
      not is_nil(loop.provider_history_error) ->
        {:error, {:provider_history_encoding_failed, loop.provider_history_error}}

      count > loop.limits.provider_history_items ->
        {:error,
         {:provider_history_item_limit_exceeded, count, loop.limits.provider_history_items}}

      true ->
        case json_items_size(new_items) do
          {:ok, item_bytes} ->
            bytes = json_array_size(count, loop.provider_history_item_bytes + item_bytes)

            if bytes <= loop.limits.provider_history_bytes do
              {:ok, count, bytes, item_bytes}
            else
              {:error,
               {:provider_history_byte_limit_exceeded, bytes, loop.limits.provider_history_bytes}}
            end

          {:error, reason} ->
            {:error, {:provider_history_encoding_failed, reason}}
        end
    end
  end

  defp initial_history_stats(items) do
    case json_items_size(items) do
      {:ok, bytes} -> {length(items), bytes, nil}
      {:error, reason} -> {length(items), 0, reason}
    end
  end

  defp json_items_size(items) do
    Enum.reduce_while(items, {:ok, 0}, fn item, {:ok, bytes} ->
      case Ankole.JSON.encode(item) do
        {:ok, encoded} -> {:cont, {:ok, bytes + byte_size(encoded)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp json_array_size(0, _item_bytes), do: 2
  defp json_array_size(count, item_bytes), do: item_bytes + count + 1

  # ─────────────────────────────────────────────────────────────────
  # Terminal helpers
  # ─────────────────────────────────────────────────────────────────

  defp terminal_output(loop, response) do
    case response |> Map.get("output") |> list_of_maps() do
      [] -> Enum.reverse(loop.current_round_items_rev)
      output -> output
    end
  end

  defp rewrite_items(loop, items) do
    Enum.map(items, &rewrite_call_item(loop, &1))
  end

  defp rewrite_items(loop, items, program_rounds) do
    frozen_bindings = Map.new(program_rounds, &{&1.call_id, &1.bindings})

    Enum.map(items, fn item ->
      call_id = Map.get(item, "call_id")

      case {PTC.call_item?(loop.plan.ptc, item), Map.get(frozen_bindings, call_id)} do
        {true, bindings} when is_list(bindings) ->
          PTC.public_item_with_bindings(item, bindings)

        _ordinary_or_unfrozen ->
          rewrite_call_item(loop, item)
      end
    end)
  end

  @doc false
  @spec rewrite_public_items(t() | nil, [map()]) :: [map()]
  def rewrite_public_items(nil, items), do: items
  def rewrite_public_items(%__MODULE__{} = loop, items), do: rewrite_items(loop, items)

  defp accumulate_usage(loop, response) do
    loop
    |> merge_response_usage(:usage, Map.get(response, "usage"))
    |> merge_response_usage(:tool_usage, Map.get(response, "tool_usage"))
  end

  defp merge_response_usage(loop, field, %{} = usage),
    do: Map.update!(loop, field, &merge_usage(&1, usage))

  defp merge_response_usage(loop, _field, _missing), do: loop

  defp merge_usage(nil, usage), do: usage

  defp merge_usage(%{} = accumulated, %{} = usage) do
    Map.merge(accumulated, usage, fn _key, left, right ->
      cond do
        is_number(left) and is_number(right) -> left + right
        is_map(left) and is_map(right) -> merge_usage(left, right)
        true -> right
      end
    end)
  end

  defp list_of_maps(value) when is_list(value), do: Enum.filter(value, &is_map/1)
  defp list_of_maps(_value), do: []
end
