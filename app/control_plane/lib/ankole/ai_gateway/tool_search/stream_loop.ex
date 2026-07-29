defmodule Ankole.AIGateway.ToolSearch.StreamLoop do
  @moduledoc """
  Per-stream tool search state over one public response.

  The loop rewrites provider `function_call` events for the synthesized search
  tool into public `tool_search_call` items, executes server-mode searches, and
  turns intermediate provider terminals into continuation rounds. One public
  response can span several provider responses; the loop renumbers public
  events and accumulates raw provider items for the continuation input.

  Server rounds are bounded only as an incident stop: a model that keeps
  searching without progress would otherwise burn provider spend invisibly.
  """

  alias Ankole.AIGateway.ToolSearch

  @max_server_rounds 16

  defstruct plan: nil,
            provider_request: nil,
            provider_items: [],
            downstream_tools: nil,
            suppressed_item_ids: MapSet.new(),
            usage: nil,
            tool_usage: nil,
            rounds: 0,
            sequence: -1,
            program_run: nil

  @type t :: %__MODULE__{}

  @spec new(t() | map() | nil) :: t() | nil
  def new(nil), do: nil
  def new(%__MODULE__{} = loop), do: loop

  def new(%{plan: %ToolSearch.Plan{} = plan, provider_request: %{} = provider_request} = config) do
    %__MODULE__{
      plan: plan,
      provider_request: provider_request,
      downstream_tools: ToolSearch.list_tools(provider_request),
      program_run: Map.get(config, :program_run)
    }
  end

  @doc """
  Returns whether the plan carries an unsettled program that must resume
  before any provider round.
  """
  @spec pre_round?(t() | nil) :: boolean()
  def pre_round?(%__MODULE__{plan: %ToolSearch.Plan{pre_round: %{}}}), do: true
  def pre_round?(_loop), do: false

  @doc """
  Resumes the request's unsettled program by replaying its recorded calls.

  Returns `{:provider_round, items, request, loop}` when the settled program
  hands control back to the model, or `{:respond, items, loop}` when the
  program pauses again and the response answers the client without any
  provider call.
  """
  @spec pre_round(t()) ::
          {:provider_round, [map()], map(), t()} | {:respond, [map()], t()}
  def pre_round(%__MODULE__{plan: %ToolSearch.Plan{pre_round: %{} = pre_round} = plan} = loop) do
    bindings = plan.program.bindings
    loop = %{loop | plan: %{plan | pre_round: nil}}

    outcome = run_program(loop, pre_round.code, bindings, pre_round.memo, pre_round.fingerprint)

    case outcome.status do
      :pending ->
        items =
          paused_program_items(loop.plan, pre_round.call_id, outcome, length(pre_round.memo))

        {:respond, items, loop}

      _settled ->
        output_item = ToolSearch.public_program_output(pre_round.call_id, outcome)

        downstream = ToolSearch.downstream_program_output(pre_round.call_id, outcome)
        loop = remember_provider_items(loop, [downstream])

        continuation_request =
          loop.provider_request
          |> Map.put("input", continuation_input(loop))
          |> ToolSearch.put_tools(loop.downstream_tools)

        {:provider_round, [output_item], continuation_request, %{loop | rounds: loop.rounds + 1}}
    end
  end

  defp run_program(loop, code, bindings, memo, expected_fingerprint) do
    cond do
      not is_function(loop.program_run, 3) ->
        %{status: :failed, output: [], pending_calls: [], error: "program runtime unavailable"}

      is_binary(expected_fingerprint) and
          expected_fingerprint != ToolSearch.program_fingerprint(code, bindings) ->
        %{
          status: :failed,
          output: [],
          pending_calls: [],
          error: "program fingerprint mismatch: bindings changed between requests"
        }

      true ->
        case loop.program_run.(code, bindings, memo) do
          {:ok, outcome} -> outcome
          {:error, reason} -> %{status: :failed, output: [], pending_calls: [], error: reason}
        end
    end
  end

  defp paused_program_items(plan, program_call_id, outcome, memo_offset) do
    outcome.pending_calls
    |> Enum.with_index()
    |> Enum.map(fn {call, index} ->
      program_call_id
      |> ToolSearch.nested_program_call(memo_offset + index, call)
      |> then(&ToolSearch.public_function_call(plan, &1))
    end)
  end

  @doc """
  Rewrites or suppresses one provider event before public observation.

  Suppression covers the argument streaming of the synthesized search tool and
  the per-round `response.created`/`response.in_progress` lifecycle of
  continuation rounds; the public stream keeps one response lifecycle.
  """
  @terminal_event_types ~w(response.completed response.failed response.incomplete)

  @spec observe(t(), map()) :: {:emit, map(), t()} | {:suppress, t()}
  def observe(%__MODULE__{} = loop, %{"type" => type} = event) do
    cond do
      type in ["response.created", "response.in_progress"] and loop.rounds > 0 ->
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
  def intercept_terminal(%__MODULE__{} = loop, event_type, %{} = response) do
    loop = accumulate_usage(loop, response)
    output = response |> Map.get("output") |> list_of_maps()
    loop = remember_provider_items(loop, output)

    server_search_calls =
      if loop.plan.execution == :server and loop.rounds < @max_server_rounds,
        do: Enum.filter(output, &ToolSearch.search_call_item?(loop.plan, &1)),
        else: []

    program_calls = Enum.filter(output, &ToolSearch.program_call_item?(loop.plan, &1))

    if event_type != "response.completed" or (server_search_calls == [] and program_calls == []) do
      {:finalize, rewrite_items(loop, output), [], loop}
    else
      {loop, executed_searches} = execute_search_calls(loop, server_search_calls)
      search_outputs = search_output_items(loop, executed_searches)
      {loop, program_items, program_paused?} = execute_program_calls(loop, program_calls)
      extras = search_outputs ++ program_items

      finalize? =
        program_paused? or
          Enum.any?(output, &pending_client_call?(loop, &1)) or
          (server_search_calls != [] and loop.rounds >= @max_server_rounds)

      if finalize? do
        {:finalize, rewrite_items(loop, output), extras, loop}
      else
        continue_round(loop, extras)
      end
    end
  end

  # Client-owned calls the gateway cannot answer: ordinary function or custom
  # calls, plus client-mode search calls.
  defp pending_client_call?(loop, %{"type" => type} = item)
       when type in ["function_call", "custom_tool_call"] do
    cond do
      ToolSearch.program_call_item?(loop.plan, item) -> false
      not ToolSearch.search_call_item?(loop.plan, item) -> true
      true -> loop.plan.execution == :client
    end
  end

  defp pending_client_call?(_loop, _item), do: false

  # Runs each freshly issued program with an empty memo. A completed or failed
  # program answers the model in a continuation round; a paused program hands
  # its nested calls to the client and forces finalization.
  defp execute_program_calls(loop, program_calls) do
    Enum.reduce(program_calls, {loop, [], false}, fn call_item, {loop, items, paused?} ->
      call_id = Map.get(call_item, "call_id")
      %{code: code} = ToolSearch.parse_program_arguments(call_item)
      bindings = loop.plan.program.bindings
      outcome = run_program(loop, code, bindings, [], nil)

      case outcome.status do
        :pending ->
          nested = paused_program_items(loop.plan, call_id, outcome, 0)
          {loop, items ++ nested, true}

        _settled ->
          output_item = ToolSearch.public_program_output(call_id, outcome)

          downstream = ToolSearch.downstream_program_output(call_id, outcome)
          {remember_provider_items(loop, [downstream]), items ++ [output_item], paused?}
      end
    end)
  end

  @doc """
  Returns whether the loop exhausted its server round budget on a terminal
  that still carried search calls.
  """
  @spec round_budget_exhausted?(t() | nil) :: boolean()
  def round_budget_exhausted?(%__MODULE__{rounds: rounds}), do: rounds >= @max_server_rounds
  def round_budget_exhausted?(_loop), do: false

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
      ToolSearch.program_call_item?(loop.plan, item)
  end

  defp rewrite_call_item(loop, item) do
    cond do
      ToolSearch.search_call_item?(loop.plan, item) ->
        ToolSearch.public_search_call(loop.plan, item)

      ToolSearch.program_call_item?(loop.plan, item) ->
        ToolSearch.public_program_item(loop.plan, item)

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

    {:round, continuation_request, extras, %{loop | rounds: loop.rounds + 1}}
  end

  defp search_output_items(loop, executed) do
    Enum.map(executed, fn {call_item, loaded} ->
      ToolSearch.public_search_output(loop.plan, call_item, loaded)
    end)
  end

  defp execute_search_calls(loop, search_calls) do
    Enum.reduce(search_calls, {loop, []}, fn call_item, {loop, executed} ->
      %{query: query, limit: limit} = ToolSearch.parse_search_arguments(call_item)
      loaded = ToolSearch.search(loop.plan, query, limit)
      {plan, downstream_tools} = ToolSearch.load_tools(loop.plan, loop.downstream_tools, loaded)
      downstream_output = ToolSearch.downstream_search_output(call_item, loaded)

      loop = %{
        remember_provider_items(loop, [downstream_output])
        | plan: plan,
          downstream_tools: downstream_tools
      }

      {loop, executed ++ [{call_item, loaded}]}
    end)
  end

  defp continuation_input(loop) do
    original = loop.provider_request |> Map.get("input") |> input_items()
    original ++ loop.provider_items
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

  defp remember_provider_items(loop, items) do
    %{loop | provider_items: loop.provider_items ++ items}
  end

  # ─────────────────────────────────────────────────────────────────
  # Terminal helpers
  # ─────────────────────────────────────────────────────────────────

  defp rewrite_items(loop, items) do
    Enum.map(items, &rewrite_call_item(loop, &1))
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
