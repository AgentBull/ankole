defmodule Ankole.AIGateway.ResponseItems do
  @moduledoc """
  Canonical Responses item and dependency semantics.

  This module is deliberately provider- and transport-neutral. It is the one
  place that knows which call item pairs with which output item, how a program
  owns nested calls, what makes a call executable, and whether a history cut
  would split an open aggregate.

  Persistence, compaction, streaming, and tool execution consume these
  semantics; they must not grow their own item-type registries.
  """

  # Every Responses call/output family is declared once here. `call_key` and
  # `output_key` name the wire fields that carry the same logical identity;
  # local-shell is the one current family whose output uses `id` instead of
  # `call_id`. Consumers must ask this module rather than copying item enums.
  @pair_families %{
    "function_call" => %{
      output: "function_call_output",
      call_key: "call_id",
      output_key: "call_id"
    },
    "custom_tool_call" => %{
      output: "custom_tool_call_output",
      call_key: "call_id",
      output_key: "call_id"
    },
    "program" => %{output: "program_output", call_key: "call_id", output_key: "call_id"},
    "tool_search_call" => %{
      output: "tool_search_output",
      call_key: "call_id",
      output_key: "call_id"
    },
    "computer_call" => %{
      output: "computer_call_output",
      call_key: "call_id",
      output_key: "call_id"
    },
    "local_shell_call" => %{
      output: "local_shell_call_output",
      call_key: "call_id",
      output_key: "id"
    },
    "shell_call" => %{
      output: "shell_call_output",
      call_key: "call_id",
      output_key: "call_id",
      caller_scoped: true
    },
    "apply_patch_call" => %{
      output: "apply_patch_call_output",
      call_key: "call_id",
      output_key: "call_id",
      caller_scoped: true
    },
    "mcp_approval_request" => %{
      output: "mcp_approval_response",
      call_key: "id",
      output_key: "approval_request_id"
    }
  }
  @call_output_types Map.new(@pair_families, fn {call_type, family} ->
                       {call_type, family.output}
                     end)
  @output_call_types Map.new(@call_output_types, fn {call_type, output_type} ->
                       {output_type, call_type}
                     end)
  @client_call_output_types Map.take(@call_output_types, [
                              "function_call",
                              "custom_tool_call"
                            ])
  @call_types Map.keys(@call_output_types)
  @output_types Map.values(@call_output_types)
  @provider_budget_call_types ~w(
    apply_patch_call
    code_interpreter_call
    computer_call
    file_search_call
    image_generation_call
    local_shell_call
    mcp_call
    mcp_list_tools
    shell_call
    web_search_call
  )
  @provider_replay_id_required_types ~w(
    code_interpreter_call
    computer_call
    file_search_call
    image_generation_call
    item_reference
    local_shell_call
    local_shell_call_output
    mcp_approval_request
    mcp_call
    mcp_list_tools
    program
    program_output
    reasoning
    web_search_call
  )
  @budgeted_tool_declaration_types ~w(
    apply_patch
    code_interpreter
    computer
    computer_use_preview
    file_search
    image_generation
    local_shell
    mcp
    programmatic_tool_calling
    shell
    tool_search
    web_search
    web_search_2025_08_26
    web_search_preview
    web_search_preview_2025_03_11
  )
  @budgeted_tool_choice_types ["computer_use" | @budgeted_tool_declaration_types]

  defstruct items: [],
            count: 0,
            identities: %{},
            calls: %{},
            outputs: %{},
            programs: %{},
            server_search_queue: :queue.new(),
            server_search_ordinal: 0

  defmodule History do
    @moduledoc false

    defstruct input: nil, ledger: %Ankole.AIGateway.ResponseItems{}, entries: [], error: nil

    @type entry :: %{
            item: term(),
            index: non_neg_integer(),
            managed?: boolean(),
            pair_key: term() | nil
          }

    @type t :: %__MODULE__{
            input: term(),
            ledger: Ankole.AIGateway.ResponseItems.t(),
            entries: [entry()],
            error: nil | %{reason: term(), item: map(), index: non_neg_integer()}
          }
  end

  @type source :: :history | :request_input | :local_effect | {:provider, non_neg_integer()}
  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec call_types() :: [String.t()]
  def call_types, do: @call_types

  @spec output_types() :: [String.t()]
  def output_types, do: @output_types

  @spec expected_output_type(String.t()) :: String.t() | nil
  def expected_output_type(call_type), do: Map.get(@call_output_types, call_type)

  @doc "Returns the wire field that carries one call/output pair identity."
  @spec pair_identity_field(term()) :: String.t() | nil
  def pair_identity_field(%{"type" => type}) when is_map_key(@pair_families, type),
    do: @pair_families[type].call_key

  def pair_identity_field(%{"type" => type}) when is_map_key(@output_call_types, type) do
    call_type = Map.fetch!(@output_call_types, type)
    @pair_families[call_type].output_key
  end

  # Provider-owned item families that have no separate output type can still
  # carry a call identity. Preserve that generic Responses field without
  # extending a second item registry.
  def pair_identity_field(%{"call_id" => _call_id}), do: "call_id"
  def pair_identity_field(_item), do: nil

  @spec client_expected_output_type(String.t()) :: String.t() | nil
  def client_expected_output_type(call_type), do: Map.get(@client_call_output_types, call_type)

  @spec call_item?(term()) :: boolean()
  def call_item?(%{"type" => type}) when type in @call_types, do: true
  def call_item?(_item), do: false

  @spec output_item?(term()) :: boolean()
  def output_item?(%{"type" => type}) when type in @output_types, do: true
  def output_item?(_item), do: false

  @doc "Returns whether Responses replay requires this item's provider identity."
  @spec provider_replay_id_required?(term()) :: boolean()
  def provider_replay_id_required?(%{
        "type" => "message",
        "role" => "assistant",
        "status" => status
      })
      when status in ["in_progress", "completed", "incomplete"],
      do: true

  def provider_replay_id_required?(%{"type" => type})
      when type in @provider_replay_id_required_types,
      do: true

  def provider_replay_id_required?(_item), do: false

  @spec client_call_item?(term()) :: boolean()
  def client_call_item?(%{"type" => type}) when is_map_key(@client_call_output_types, type),
    do: true

  def client_call_item?(_item), do: false

  @doc """
  Classifies a public Responses item for the `max_tool_calls` owner.

  Gateway effects are counted when the response owner admits the executable
  call. Provider effects are counted from their provider lifecycle. Ordinary
  function/custom calls and every output item are outside this built-in-tool
  budget.
  """
  @spec budget_role(term()) :: :gateway_effect | :provider_effect | :none
  def budget_role(%{"type" => "program"}), do: :gateway_effect

  # Tool Search is translated to an ordinary provider function call in both
  # modes. AIGateway therefore owns its public budget semantics even when the
  # client, rather than the gateway, will execute the returned search call.
  def budget_role(%{"type" => "tool_search_call"}), do: :gateway_effect

  def budget_role(%{"type" => type}) when type in @provider_budget_call_types,
    do: :provider_effect

  def budget_role(_item), do: :none

  @doc "Returns whether one tool declaration consumes the built-in tool budget."
  @spec budgeted_tool_declaration?(term()) :: boolean()
  def budgeted_tool_declaration?(%{"type" => type})
      when type in @budgeted_tool_declaration_types,
      do: true

  def budgeted_tool_declaration?(_tool), do: false

  @doc "Returns whether one exact or allowed tool choice selects a budgeted tool."
  @spec budgeted_tool_choice?(term()) :: boolean()
  def budgeted_tool_choice?(%{"type" => type}) when type in @budgeted_tool_choice_types,
    do: true

  def budgeted_tool_choice?(_choice), do: false

  @spec client_output_item?(term()) :: boolean()
  def client_output_item?(%{"type" => type})
      when type in ["function_call_output", "custom_tool_call_output"],
      do: true

  def client_output_item?(_item), do: false

  @spec valid_client_output?(term()) :: boolean()
  def valid_client_output?(item) do
    client_output_item?(item) and validate_client_output(item) == :ok
  end

  @doc """
  Validates one client-executed call/output relation.

  Pair identity includes the caller, so a direct output can never settle a
  program-scoped call that happens to reuse the same `call_id`.
  """
  @spec validate_client_call_output(map(), map()) :: :ok | {:error, atom()}
  def validate_client_call_output(call, output) when is_map(call) and is_map(output) do
    cond do
      not client_call_item?(call) ->
        {:error, :not_a_client_call}

      not client_output_item?(output) ->
        {:error, :not_a_client_output}

      not valid_client_output?(output) ->
        {:error, :invalid_output}

      not executable_call?(call) ->
        {:error, :non_executable_call}

      pair_key(call) != pair_key(output) ->
        {:error, :pair_mismatch}

      expected_output_type(call["type"]) != output["type"] ->
        {:error, :type_mismatch}

      output_name_mismatch?(call, output) ->
        {:error, :name_mismatch}

      true ->
        :ok
    end
  end

  def validate_client_call_output(_call, _output), do: {:error, :invalid_item}

  @doc """
  Returns true only for a structurally complete call that may cross an
  execution boundary. Drafts and partial terminal fragments are never
  executable.
  """
  @spec executable_call?(term()) :: boolean()
  def executable_call?(%{"type" => "function_call"} = item) do
    completed_status?(item) and
      non_empty_binary?(item["call_id"]) and
      non_empty_binary?(item["name"]) and
      is_binary(item["arguments"]) and
      valid_caller?(item)
  end

  def executable_call?(%{"type" => "custom_tool_call"} = item) do
    completed_status?(item) and
      non_empty_binary?(item["call_id"]) and
      non_empty_binary?(item["name"]) and
      is_binary(item["input"]) and
      valid_caller?(item)
  end

  def executable_call?(%{"type" => "program"} = item) do
    completed_status?(item) and
      non_empty_binary?(item["call_id"]) and
      is_binary(item["code"]) and
      non_empty_binary?(item["fingerprint"])
  end

  def executable_call?(%{"type" => "tool_search_call"} = item) do
    completed_status?(item) and
      item["execution"] in ["client", "server"] and
      is_map(item["arguments"]) and
      valid_search_call_id?(item)
  end

  def executable_call?(%{"type" => "computer_call"} = item) do
    completed_status?(item) and not is_nil(pair_key(item)) and
      is_list(item["pending_safety_checks"])
  end

  def executable_call?(%{"type" => "local_shell_call"} = item) do
    completed_status?(item) and not is_nil(pair_key(item)) and is_map(item["action"])
  end

  def executable_call?(%{"type" => "shell_call"} = item) do
    completed_status?(item) and not is_nil(pair_key(item)) and is_map(item["action"]) and
      valid_caller?(item)
  end

  def executable_call?(%{"type" => "apply_patch_call"} = item) do
    completed_status?(item) and not is_nil(pair_key(item)) and is_map(item["operation"]) and
      valid_caller?(item)
  end

  def executable_call?(%{"type" => "mcp_approval_request"} = item) do
    not is_nil(pair_key(item)) and is_binary(item["arguments"]) and
      non_empty_binary?(item["name"]) and non_empty_binary?(item["server_label"])
  end

  def executable_call?(_item), do: false

  @spec incomplete_call?(term()) :: boolean()
  def incomplete_call?(%{"type" => type} = item) when type in @call_types,
    do: not executable_call?(item)

  def incomplete_call?(_item), do: false

  @spec validate_executable_call(term()) :: :ok | {:error, term()}
  def validate_executable_call(%{"type" => type} = item) when type in @call_types do
    if executable_call?(item),
      do: :ok,
      else: {:error, {:incomplete_call_item, type, item["call_id"]}}
  end

  def validate_executable_call(item), do: {:error, {:not_a_call_item, item}}

  @spec reduce(t(), map(), source()) ::
          {:ok, t(), :inserted | :duplicate} | {:error, term()}
  def reduce(%__MODULE__{} = ledger, %{} = item, source \\ :history) do
    case reduce_with_key(ledger, item, source) do
      {:ok, ledger, disposition, _pair_key} -> {:ok, ledger, disposition}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reduces an item and also returns its resolved pair key.

  The resolved key is useful to policy owners that need to attach lifecycle
  decisions to a pair without reimplementing client caller scoping or the
  provider's FIFO rule for server-side tool search.
  """
  @spec reduce_with_key(t(), map(), source()) ::
          {:ok, t(), :inserted | :duplicate, term()} | {:error, term()}
  def reduce_with_key(%__MODULE__{} = ledger, %{} = item, source \\ :history) do
    with :ok <- validate_item(item),
         {:ok, ledger, semantic_key} <- resolve_semantic_key(ledger, item),
         {:ok, disposition} <- duplicate_disposition(ledger, semantic_key, item) do
      pair_key = semantic_pair_from_identity(semantic_key)

      case disposition do
        :duplicate ->
          {:ok, ledger, :duplicate, pair_key}

        :inserted ->
          index = ledger.count

          ledger =
            ledger
            |> Map.update!(:items, &[item | &1])
            |> Map.update!(:count, &(&1 + 1))
            |> put_identity(semantic_key, item)
            |> remember_pair_fact(item, semantic_key, index, source)

          {:ok, ledger, :inserted, pair_key}
      end
    end
  end

  @spec reduce_many([map()], source()) :: {:ok, t()} | {:error, term()}
  def reduce_many(items, source \\ :history) when is_list(items) do
    Enum.reduce_while(items, {:ok, new()}, fn item, {:ok, ledger} ->
      case reduce(ledger, item, source) do
        {:ok, ledger, _disposition} -> {:cont, {:ok, ledger}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Analyzes gateway-owned request history in one physical pass.

  Direct function and custom-tool history can refer to a stored response that
  is outside the current input, so it stays opaque. Tool Search items, program
  items, and all program-owned children enter the canonical pair ledger. The
  first structural error is retained while the pass continues only to classify
  later declaration-owned items.
  """
  @spec analyze_history(term()) :: History.t()
  def analyze_history(items) when is_list(items) do
    {ledger, entries_rev, error} =
      items
      |> Enum.with_index()
      |> Enum.reduce({new(), [], nil}, fn {item, index}, {ledger, entries, error} ->
        managed? = managed_history_item?(item)

        cond do
          not managed? ->
            entry = %{item: item, index: index, managed?: false, pair_key: nil}
            {ledger, [entry | entries], error}

          not is_nil(error) ->
            entry = %{item: item, index: index, managed?: true, pair_key: nil}
            {ledger, [entry | entries], error}

          true ->
            case reduce_with_key(ledger, item, :request_input) do
              {:ok, next_ledger, :inserted, pair_key} ->
                entry = %{item: item, index: index, managed?: true, pair_key: pair_key}
                {next_ledger, [entry | entries], nil}

              {:ok, _next_ledger, :duplicate, pair_key} ->
                entry = %{item: item, index: index, managed?: true, pair_key: pair_key}

                duplicate = %{
                  reason: {:duplicate_history_item, pair_key},
                  item: item,
                  index: index
                }

                {ledger, [entry | entries], duplicate}

              {:error, reason} ->
                entry = %{item: item, index: index, managed?: true, pair_key: pair_key(item)}
                {ledger, [entry | entries], %{reason: reason, item: item, index: index}}
            end
        end
      end)

    %History{input: items, ledger: ledger, entries: Enum.reverse(entries_rev), error: error}
  end

  def analyze_history(input), do: %History{input: input}

  @doc "Returns true for one item whose replay semantics belong to this ledger."
  @spec managed_history_item?(term()) :: boolean()
  def managed_history_item?(%{"type" => type})
      when type in ["program", "program_output", "tool_search_call", "tool_search_output"],
      do: true

  def managed_history_item?(%{"caller" => %{"type" => "program"}}), do: true
  def managed_history_item?(_item), do: false

  @doc false
  @spec search_pairs(t()) :: [map()]
  def search_pairs(%__MODULE__{} = ledger) do
    ledger.calls
    |> Enum.filter(fn {pair_key, _fact} -> match?({:search, _, _}, pair_key) end)
    |> Enum.sort_by(fn {_pair_key, fact} -> fact.index end)
    |> Enum.map(fn {pair_key, call} ->
      %{pair_key: pair_key, call: call, output: Map.get(ledger.outputs, pair_key)}
    end)
  end

  @doc false
  @spec program_groups(t()) :: [map()]
  def program_groups(%__MODULE__{} = ledger) do
    items = ledger.items |> Enum.reverse() |> List.to_tuple()

    ledger.programs
    |> Enum.map(fn {call_id, indices} -> program_group(ledger, items, call_id, indices) end)
    |> Enum.sort_by(& &1.first_index)
  end

  @spec items(t()) :: [map()]
  def items(%__MODULE__{items: items}), do: Enum.reverse(items)

  @spec call_for_pair(t(), term()) :: map() | nil
  def call_for_pair(%__MODULE__{calls: calls}, pair_key) do
    case Map.get(calls, pair_key) do
      %{item: item} -> item
      nil -> nil
    end
  end

  @doc """
  Applies aggregate context to structural executability.

  A nested call is executable only while its owning program call is itself a
  complete executable item in the same ledger.
  """
  @spec executable_in_ledger?(t(), term()) :: boolean()
  def executable_in_ledger?(%__MODULE__{} = ledger, item) do
    executable_call?(item) and enclosing_program_executable?(ledger, item)
  end

  @doc """
  Returns whether a prefix/tail split preserves every call pair and program or
  search aggregate. An open call in the prefix makes the boundary unsafe.
  """
  @spec safe_boundary?([map()], [map()]) :: boolean()
  def safe_boundary?(prefix, tail) when is_list(prefix) and is_list(tail) do
    items = prefix ++ tail
    MapSet.member?(safe_boundary_cuts(items), length(prefix))
  end

  @doc """
  Plans every safe physical cut in one pass over an item stream.

  Physical occurrences remain distinct even when the canonical ledger treats
  an exact replay as idempotent. This prevents a repeated call or output from
  shifting semantic indexes and lets compaction test row boundaries in O(1)
  after one O(n) plan.
  """
  @spec safe_boundary_cuts([map()]) :: MapSet.t(non_neg_integer())
  def safe_boundary_cuts(items) when is_list(items) do
    case reduce_for_boundary(items) do
      {:ok, _ledger} ->
        facts = boundary_facts(items)
        item_count = length(items)

        facts.pairs
        |> unsafe_pair_intervals(item_count)
        |> maybe_add_loaded_program_interval(facts)
        |> safe_cuts(item_count)

      {:error, _reason} ->
        MapSet.new()
    end
  end

  @spec pair_key(map()) :: term() | nil
  def pair_key(%{"type" => type, "call_id" => call_id} = item)
      when type in ["function_call", "custom_tool_call"] and is_binary(call_id) and
             call_id != "" do
    {:call, caller_scope(item), call_id}
  end

  def pair_key(%{"type" => "program", "call_id" => call_id})
      when is_binary(call_id) and call_id != "",
      do: {:program, call_id}

  def pair_key(%{"type" => "program_output", "call_id" => call_id})
      when is_binary(call_id) and call_id != "",
      do: {:program, call_id}

  def pair_key(%{"type" => type, "call_id" => call_id} = item)
      when type in ["function_call_output", "custom_tool_call_output"] and
             is_binary(call_id) and call_id != "" do
    {:call, caller_scope(item), call_id}
  end

  def pair_key(%{"type" => type, "execution" => "client", "call_id" => call_id})
      when type in ["tool_search_call", "tool_search_output"] and is_binary(call_id) and
             call_id != "",
      do: {:search, :client, call_id}

  def pair_key(%{"type" => type, "execution" => "server"})
      when type in ["tool_search_call", "tool_search_output"],
      do: nil

  def pair_key(%{"type" => type} = item) when is_map_key(@pair_families, type) do
    family = Map.fetch!(@pair_families, type)
    response_pair_key(type, Map.get(item, family.call_key), item, family)
  end

  def pair_key(%{"type" => type} = item) when is_map_key(@output_call_types, type) do
    call_type = Map.fetch!(@output_call_types, type)
    family = Map.fetch!(@pair_families, call_type)
    response_pair_key(call_type, Map.get(item, family.output_key), item, family)
  end

  def pair_key(_item), do: nil

  @doc """
  Resolves each call/output item's canonical pair key in sequence.

  Server Tool Search has no public call ID, so its output can only be paired by
  reducing the ordered item stream. Consumers such as compaction rendering use
  this API instead of inventing a second, lossy call-ID registry.
  """
  @spec resolved_pair_keys([map()]) :: [term() | nil]
  def resolved_pair_keys(items) when is_list(items) do
    {keys, _ledger} =
      Enum.map_reduce(items, new(), fn item, ledger ->
        if call_item?(item) or output_item?(item) do
          case reduce_with_key(ledger, item) do
            {:ok, ledger, _disposition, pair_key} -> {pair_key, ledger}
            {:error, _reason} -> {pair_key(item), ledger}
          end
        else
          {nil, ledger}
        end
      end)

    keys
  end

  # In-progress call items are valid ledger entries: they must participate in
  # compaction/dependency checks, but `executable_call?/1` keeps them from ever
  # crossing the execution boundary.
  defp validate_item(%{"type" => type}) when type in @call_types, do: :ok

  defp validate_item(%{"type" => "function_call_output"} = item),
    do: validate_client_output(item)

  defp validate_item(%{"type" => "custom_tool_call_output"} = item),
    do: validate_client_output(item)

  defp validate_item(%{"type" => "computer_call_output"} = item),
    do: validate_paired_output(item, is_map(item["output"]))

  defp validate_item(%{"type" => "local_shell_call_output"} = item),
    do: validate_paired_output(item, is_binary(item["output"]))

  defp validate_item(%{"type" => "shell_call_output"} = item),
    do: validate_paired_output(item, is_list(item["output"]) and valid_caller?(item))

  defp validate_item(%{"type" => "apply_patch_call_output"} = item),
    do:
      validate_paired_output(
        item,
        item["status"] in ["completed", "failed"] and valid_caller?(item)
      )

  defp validate_item(%{"type" => "mcp_approval_response"} = item),
    do: validate_paired_output(item, is_boolean(item["approve"]))

  defp validate_item(%{"type" => "program_output"} = item) do
    if non_empty_binary?(item["call_id"]) and
         item["status"] in ["completed", "incomplete"] and
         is_binary(item["result"]) do
      :ok
    else
      {:error, {:invalid_program_output, item["call_id"]}}
    end
  end

  defp validate_item(%{"type" => "tool_search_output"} = item) do
    if completed_status?(item) and
         item["execution"] in ["client", "server"] and
         is_list(item["tools"]) and
         valid_search_call_id?(item) do
      :ok
    else
      {:error, {:invalid_tool_search_output, item["call_id"]}}
    end
  end

  defp validate_item(%{"type" => type} = item) when type in @output_types do
    if is_nil(pair_key(item)),
      do: {:error, {:invalid_paired_output, type}},
      else: :ok
  end

  defp validate_item(%{}), do: :ok

  defp validate_client_output(item) do
    if non_empty_binary?(item["call_id"]) and valid_caller?(item) and
         valid_client_output_value?(item["output"]),
       do: :ok,
       else: {:error, {:invalid_tool_call_output, item["call_id"]}}
  end

  defp validate_paired_output(item, payload_valid?) do
    if payload_valid? and not is_nil(pair_key(item)),
      do: :ok,
      else: {:error, {:invalid_paired_output, item["type"]}}
  end

  defp resolve_semantic_key(ledger, %{"type" => type} = item) do
    case pair_key(item) do
      nil ->
        resolve_unkeyed_semantic_key(ledger, item)

      pair_key when type in @output_types ->
        with :ok <- validate_output_pair(ledger, item, pair_key) do
          {:ok, ledger, identity_key(item, pair_key)}
        end

      pair_key when type in @call_types ->
        with :ok <- validate_call_pair(ledger, item, pair_key) do
          {:ok, ledger, identity_key(item, pair_key)}
        end

      pair_key ->
        {:ok, ledger, identity_key(item, pair_key)}
    end
  end

  defp resolve_semantic_key(ledger, %{} = item),
    do: resolve_unkeyed_semantic_key(ledger, item)

  defp resolve_unkeyed_semantic_key(
         %__MODULE__{} = ledger,
         %{"type" => "tool_search_call", "execution" => "server"} = item
       ) do
    ordinal = ledger.server_search_ordinal
    key = {:search, :server, {:ordinal, ordinal}}

    ledger = %{
      ledger
      | server_search_queue: :queue.in(key, ledger.server_search_queue),
        server_search_ordinal: ordinal + 1
    }

    with :ok <- validate_call_pair(ledger, item, key) do
      {:ok, ledger, identity_key(item, key)}
    end
  end

  defp resolve_unkeyed_semantic_key(
         %__MODULE__{server_search_queue: queue} = ledger,
         %{"type" => "tool_search_output", "execution" => "server"} = item
       ) do
    case :queue.out(queue) do
      {{:value, key}, queue} ->
        ledger = %{ledger | server_search_queue: queue}

        with :ok <- validate_output_pair(ledger, item, key) do
          {:ok, ledger, identity_key(item, key)}
        end

      {:empty, _queue} ->
        {:error, :orphan_server_tool_search_output}
    end
  end

  defp resolve_unkeyed_semantic_key(ledger, item) do
    key =
      case item["id"] do
        id when is_binary(id) and id != "" -> {:item, item["type"], id}
        _missing -> {:item, item["type"], ledger.count}
      end

    {:ok, ledger, key}
  end

  defp validate_call_pair(ledger, item, pair_key) do
    case Map.get(ledger.calls, pair_key) do
      nil ->
        :ok

      %{type: existing_type, item: existing} ->
        if existing_type == item["type"] and existing == item do
          :ok
        else
          {:error, {:conflicting_call_pair, pair_key, existing_type, item["type"]}}
        end
    end
  end

  defp validate_output_pair(ledger, item, pair_key) do
    expected_call_type = Map.get(@output_call_types, item["type"])

    with %{type: call_type, item: call_item} <- Map.get(ledger.calls, pair_key),
         true <- call_type == expected_call_type,
         false <- output_name_mismatch?(call_item, item) do
      case Map.get(ledger.outputs, pair_key) do
        nil ->
          :ok

        %{type: existing_type, item: existing} ->
          if existing_type == item["type"] and existing == item do
            :ok
          else
            {:error, {:conflicting_output_pair, pair_key, existing_type, item["type"]}}
          end
      end
    else
      nil ->
        {:error, {:orphan_call_output, pair_key, item["type"]}}

      false ->
        {:error, {:mismatched_call_output, pair_key, expected_call_type}}

      true ->
        {:error, {:mismatched_call_output_name, pair_key}}
    end
  end

  defp duplicate_disposition(ledger, semantic_key, item) do
    case Map.fetch(ledger.identities, semantic_key) do
      :error -> {:ok, :inserted}
      {:ok, ^item} -> {:ok, :duplicate}
      {:ok, _different} -> {:error, {:conflicting_duplicate_item, semantic_key}}
    end
  end

  defp put_identity(ledger, semantic_key, item),
    do: %{ledger | identities: Map.put(ledger.identities, semantic_key, item)}

  defp remember_pair_fact(ledger, item, semantic_key, index, source) do
    type = item["type"]
    pair_key = semantic_pair_from_identity(semantic_key)
    fact = %{type: type, item: item, index: index, source: source}

    cond do
      type in @call_types ->
        ledger
        |> Map.update!(:calls, &Map.put(&1, pair_key, fact))
        |> remember_program_fact(item, pair_key, index, :call)

      type in @output_types ->
        ledger
        |> Map.update!(:outputs, &Map.put(&1, pair_key, fact))
        |> remember_program_fact(item, pair_key, index, :output)

      true ->
        ledger
    end
  end

  defp remember_program_fact(ledger, %{"type" => "program"}, {:program, id}, index, :call) do
    put_program_index(ledger, id, :root, index)
  end

  defp remember_program_fact(
         ledger,
         %{"type" => "program_output"},
         {:program, id},
         index,
         :output
       ) do
    put_program_index(ledger, id, :output, index)
  end

  defp remember_program_fact(ledger, _item, {:call, {:program, id}, _call_id}, index, role) do
    key = if role == :call, do: :children, else: :child_outputs
    update_program_indices(ledger, id, key, index)
  end

  defp remember_program_fact(
         ledger,
         _item,
         {:response_pair, _type, {:program, id}, _call_id},
         index,
         role
       ) do
    key = if role == :call, do: :children, else: :child_outputs
    update_program_indices(ledger, id, key, index)
  end

  defp remember_program_fact(ledger, _item, _pair_key, _index, _role), do: ledger

  defp put_program_index(ledger, id, key, index) do
    programs =
      Map.update(ledger.programs, id, %{key => index}, &Map.put(&1, key, index))

    %{ledger | programs: programs}
  end

  defp update_program_indices(ledger, id, key, index) do
    programs =
      Map.update(ledger.programs, id, %{key => [index]}, fn program ->
        Map.update(program, key, [index], &[index | &1])
      end)

    %{ledger | programs: programs}
  end

  defp program_group(ledger, items, call_id, indices) do
    root = fact_at(items, Map.get(indices, :root))
    output = fact_at(items, Map.get(indices, :output))

    children =
      indices
      |> Map.get(:children, [])
      |> Enum.reverse()
      |> Enum.map(fn index ->
        call = fact_at(items, index)
        pair_key = pair_key(call.item)
        %{call: call, output: Map.get(ledger.outputs, pair_key)}
      end)

    first_index =
      [root && root.index, output && output.index | Enum.map(children, & &1.call.index)]
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> ledger.count end)

    %{
      call_id: call_id,
      root: root,
      output: output,
      children: children,
      first_index: first_index
    }
  end

  defp fact_at(_items, nil), do: nil

  defp fact_at(items, index) do
    %{item: elem(items, index), index: index}
  end

  defp boundary_facts(items) do
    initial = %{
      pairs: %{},
      server_search_queue: :queue.new(),
      next_server_search: 0,
      first_search_output: nil,
      last_program_root: nil
    }

    items
    |> Enum.with_index()
    |> Enum.reduce(initial, fn {item, index}, facts ->
      {pair_key, facts} = boundary_pair_key(item, facts)

      facts
      |> remember_boundary_pair(pair_key, item, index)
      |> remember_boundary_aggregate(item, index)
    end)
  end

  defp boundary_pair_key(%{} = item, facts) do
    case pair_key(item) do
      nil -> boundary_unkeyed_search_pair(item, facts)
      pair_key -> {pair_key, facts}
    end
  end

  defp boundary_pair_key(_item, facts), do: {nil, facts}

  defp boundary_unkeyed_search_pair(
         %{"type" => "tool_search_call", "execution" => "server"},
         facts
       ) do
    ordinal = facts.next_server_search
    key = {:search, :server, {:physical, ordinal}}

    {key,
     %{
       facts
       | next_server_search: ordinal + 1,
         server_search_queue: :queue.in(key, facts.server_search_queue)
     }}
  end

  defp boundary_unkeyed_search_pair(
         %{"type" => "tool_search_output", "execution" => "server"},
         facts
       ) do
    case :queue.out(facts.server_search_queue) do
      {{:value, key}, queue} -> {key, %{facts | server_search_queue: queue}}
      {:empty, _queue} -> {nil, facts}
    end
  end

  defp boundary_unkeyed_search_pair(_item, facts), do: {nil, facts}

  defp remember_boundary_pair(facts, nil, _item, _index), do: facts

  defp remember_boundary_pair(facts, pair_key, item, index) do
    cond do
      call_item?(item) ->
        update_in(facts, [:pairs, pair_key], fn stat ->
          stat =
            stat || %{first_call: index, last_call: index, first_output: nil, last_output: nil}

          %{stat | last_call: index}
        end)

      output_item?(item) and match?(%{first_call: _}, Map.get(facts.pairs, pair_key)) ->
        update_in(facts, [:pairs, pair_key], fn stat ->
          %{
            stat
            | first_output: stat.first_output || index,
              last_output: index
          }
        end)

      true ->
        facts
    end
  end

  defp remember_boundary_aggregate(facts, %{"type" => "tool_search_output"}, index),
    do: %{facts | first_search_output: facts.first_search_output || index}

  defp remember_boundary_aggregate(facts, %{"type" => "program"}, index),
    do: %{facts | last_program_root: index}

  defp remember_boundary_aggregate(facts, _item, _index), do: facts

  defp unsafe_pair_intervals(pairs, item_count) do
    closed_programs =
      pairs
      |> Enum.reduce(MapSet.new(), fn
        {{:program, id}, %{first_output: output}}, closed when is_integer(output) ->
          MapSet.put(closed, id)

        {_pair, _stat}, closed ->
          closed
      end)

    Enum.reduce(pairs, %{}, fn {pair_key, stat}, intervals ->
      if nested_in_closed_program?(pair_key, closed_programs) do
        intervals
      else
        intervals
        |> add_prefix_pair_interval(stat, item_count)
        |> add_tail_pair_interval(stat, item_count)
      end
    end)
  end

  defp add_prefix_pair_interval(intervals, %{first_call: call, first_output: nil}, item_count),
    do: add_unsafe_interval(intervals, call + 1, item_count, item_count)

  defp add_prefix_pair_interval(
         intervals,
         %{first_call: call, first_output: output},
         item_count
       ) do
    add_unsafe_interval(intervals, call + 1, output, item_count)
  end

  defp add_tail_pair_interval(intervals, %{last_output: nil}, _item_count), do: intervals

  defp add_tail_pair_interval(
         intervals,
         %{last_call: call, last_output: output},
         item_count
       ) do
    add_unsafe_interval(intervals, call + 1, output, item_count)
  end

  defp nested_in_closed_program?(
         {:call, {:program, program_id}, _call_id},
         closed_programs
       ),
       do: MapSet.member?(closed_programs, program_id)

  defp nested_in_closed_program?(
         {:response_pair, _type, {:program, program_id}, _call_id},
         closed_programs
       ),
       do: MapSet.member?(closed_programs, program_id)

  defp nested_in_closed_program?(_pair_key, _closed_programs), do: false

  defp maybe_add_loaded_program_interval(
         intervals,
         %{first_search_output: search, last_program_root: program} = _facts
       )
       when is_integer(search) and is_integer(program) do
    add_unsafe_interval(intervals, search + 1, program, max(search, program) + 1)
  end

  defp maybe_add_loaded_program_interval(intervals, _facts), do: intervals

  # Difference-map intervals let all safe cuts be materialized in O(n + d),
  # where d is the number of distinct dependency families.
  defp add_unsafe_interval(intervals, first, last, item_count) do
    first = max(first, 0)
    last = min(last, item_count)

    if first <= last do
      intervals
      |> Map.update(first, 1, &(&1 + 1))
      |> Map.update(last + 1, -1, &(&1 - 1))
    else
      intervals
    end
  end

  defp safe_cuts(intervals, item_count) do
    {safe, _open_intervals} =
      Enum.reduce(0..item_count, {MapSet.new(), 0}, fn cut, {safe, open_intervals} ->
        open_intervals = open_intervals + Map.get(intervals, cut, 0)
        safe = if open_intervals == 0, do: MapSet.put(safe, cut), else: safe
        {safe, open_intervals}
      end)

    safe
  end

  # Boundary analysis is deliberately tolerant only of malformed outputs. Such
  # an item cannot establish a pair, but it also must not poison compaction
  # forever. Its matching call remains open unless a surrounding completed
  # program aggregate closes the nested lifecycle.
  defp reduce_for_boundary(items) do
    Enum.reduce_while(items, {:ok, new()}, fn item, {:ok, ledger} ->
      case reduce(ledger, item) do
        {:ok, ledger, _disposition} ->
          {:cont, {:ok, ledger}}

        {:error, _reason} ->
          if output_item?(item) do
            {:cont, {:ok, remember_unpaired_item(ledger, item)}}
          else
            {:halt, {:error, :invalid_call_ledger}}
          end
      end
    end)
  end

  defp remember_unpaired_item(ledger, item) do
    ledger
    |> Map.update!(:items, &[item | &1])
    |> Map.update!(:count, &(&1 + 1))
  end

  defp identity_key(item, pair_key), do: {item["type"], pair_key}

  defp semantic_pair_from_identity({_type, pair_key}), do: pair_key
  defp semantic_pair_from_identity(other), do: other

  defp caller_scope(%{"caller" => %{"type" => "program", "caller_id" => caller_id}})
       when is_binary(caller_id) and caller_id != "",
       do: {:program, caller_id}

  defp caller_scope(_item), do: :direct

  defp valid_caller?(%{"caller" => nil}), do: true
  defp valid_caller?(item) when not is_map_key(item, "caller"), do: true

  defp valid_caller?(%{"caller" => %{"type" => "direct"} = caller}),
    do: map_size(caller) == 1

  defp valid_caller?(%{
         "caller" => %{"type" => "program", "caller_id" => caller_id} = caller
       }),
       do: non_empty_binary?(caller_id) and map_size(caller) == 2

  defp valid_caller?(_item), do: false

  defp valid_search_call_id?(%{"execution" => "client", "call_id" => call_id}),
    do: non_empty_binary?(call_id)

  defp valid_search_call_id?(%{"execution" => "server"} = item),
    do: is_nil(Map.get(item, "call_id"))

  defp valid_search_call_id?(_item), do: false

  defp enclosing_program_executable?(
         ledger,
         %{"caller" => %{"type" => "program", "caller_id" => caller_id}}
       ) do
    ledger
    |> call_for_pair({:program, caller_id})
    |> executable_call?()
  end

  defp enclosing_program_executable?(_ledger, _item), do: true

  defp completed_status?(item), do: Map.get(item, "status") in [nil, "completed"]

  defp output_name_mismatch?(call, output) do
    call_name = Map.get(call, "name")
    output_name = Map.get(output, "name")
    is_binary(call_name) and is_binary(output_name) and call_name != output_name
  end

  defp response_pair_key(call_type, identity, item, %{caller_scoped: true})
       when is_binary(identity) and identity != "",
       do: {:response_pair, call_type, caller_scope(item), identity}

  defp response_pair_key(call_type, identity, _item, _family)
       when is_binary(identity) and identity != "",
       do: {:response_pair, call_type, identity}

  defp response_pair_key(_call_type, _identity, _item, _family), do: nil

  defp valid_client_output_value?(value) when is_binary(value), do: true

  defp valid_client_output_value?(value) when is_list(value),
    do: Enum.all?(value, &valid_client_output_part?/1)

  defp valid_client_output_value?(_value), do: false

  defp valid_client_output_part?(%{"type" => "input_text", "text" => text}),
    do: is_binary(text)

  defp valid_client_output_part?(%{"type" => "input_image"} = part),
    do: non_empty_binary?(part["image_url"]) or non_empty_binary?(part["file_id"])

  defp valid_client_output_part?(%{"type" => "input_file"} = part) do
    Enum.any?(["file_data", "file_id", "file_url"], &non_empty_binary?(part[&1]))
  end

  defp valid_client_output_part?(_part), do: false

  defp non_empty_binary?(value), do: is_binary(value) and value != ""
end
