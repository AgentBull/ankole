defmodule Ankole.AIGateway.ToolSearch do
  @moduledoc """
  Self-implemented OpenAI tool search and deferred loading.

  AIGateway implements the official `tool_search` tool type, the
  `defer_loading` tool marker for every downstream provider. It coordinates
  loaded tools with `ProgrammaticToolCalling`, which owns the PTC declaration,
  history, and job semantics. Upstream providers only see plain function tools
  and plain function call items.

  Two search execution modes exist and one request declares one of them:

  - `"client"`: the caller owns the searchable catalog. The model call becomes a
    public `tool_search_call` item with a string `call_id`, the caller answers
    with a `tool_search_output` item on the next request.
  - `"server"`: the request declares the catalog as `defer_loading: true` tools.
    AIGateway hides them from the provider, searches them itself, and loads the
    matching subset inside the same response (`call_id: null`).

  Tool Search never runs inside a program. Deferred tools join program bindings
  only after loading.
  """

  alias Ankole.AIGateway.ProgrammaticToolCalling, as: PTC
  alias Ankole.AIGateway.ResponseItems
  alias Ankole.AIGateway.ToolContract
  alias Ankole.AIGateway.ToolContract.Descriptor
  alias Ankole.AIGateway.ToolSearch.Index

  @default_tool_name "tool_search"
  @default_result_limit 8
  @max_result_limit 50
  @max_search_path_bytes 256
  @search_context_budget_bytes 8_192
  @catalog_listing_budget_bytes 8_192
  @server_call_id_prefix "ts_srv_"

  defmodule Plan do
    @moduledoc false

    defstruct execution: nil,
              tool_name: nil,
              synthesized_tool: nil,
              catalog: [],
              search_context: "",
              contracts: [],
              loaded_names: MapSet.new(),
              provider_tool_paths: %{},
              ptc: %PTC.Plan{}

    @type t :: %__MODULE__{
            execution: :server | :client | nil,
            tool_name: String.t() | nil,
            synthesized_tool: map() | nil,
            catalog: [map()],
            search_context: String.t(),
            contracts: [Descriptor.t()],
            loaded_names: MapSet.t(String.t()),
            provider_tool_paths: %{String.t() => map()},
            ptc: PTC.Plan.t()
          }
  end

  @doc """
  Rewrites one Responses request into a provider-safe request plus a plan.

  Requests without a `tool_search` declaration, without `defer_loading` tools,
  and without PTC surface pass through unchanged with a `nil` plan. Invalid
  declarations fail loudly instead of reaching a provider that cannot serve
  them.
  """
  @spec plan(map()) :: {:ok, map(), Plan.t() | nil} | {:error, term()}
  def plan(%{} = request) do
    tools = list_tools(request)

    with {:ok, declaration, plain_tools} <- split_tool_search_declaration(tools),
         {:ok, ptc, plain_tools} <- PTC.split_declaration(plain_tools),
         {contract_specs, passthrough_tools} = split_contract_tools(plain_tools),
         :ok <- validate_passthrough_tools(passthrough_tools),
         tool_name = declared_tool_name(declaration),
         {:ok, contracts} <-
           ToolContract.normalize(contract_specs,
             reserved_names: [PTC.tool_name(), tool_name]
           ) do
      deferred = Enum.filter(contracts, & &1.deferred?)
      declared_search? = not is_nil(declaration) or deferred != []
      history = ResponseItems.analyze_history(Map.get(request, "input"))

      search_managed? =
        declared_search? or settled_search_history?(history) or client_search_history?(history)

      projection_required? =
        settled_program_history?(history) or
          Enum.any?(contracts, fn contract ->
            contract.deferred? or
              not is_nil(contract.namespace) or
              contract.allowed_callers != ["direct"]
          end)

      with :ok <-
             validate_managed_history(
               history,
               search_managed?,
               ptc
             ),
           :ok <- validate_history_error(history) do
        if not search_managed? and not PTC.enabled?(ptc) and not projection_required? do
          {:ok, request, nil}
        else
          build_plan(request, declaration, contracts, passthrough_tools, ptc, history)
        end
      end
    end
  end

  @doc "Returns whether a composite tool plan requires ResponseStream ownership."
  @spec response_stream_required?(Plan.t() | nil) :: boolean()
  def response_stream_required?(%Plan{execution: execution, ptc: ptc}) do
    execution in [:server, :client] or PTC.response_stream_required?(ptc)
  end

  def response_stream_required?(_plan), do: false

  @doc """
  Resolves the official hosted Tool Search `paths` selection.

  A root function path loads that function. A namespace path searches only
  within that namespace using the immutable request context captured by the
  plan, matching OpenAI's behavior of returning a relevant subset. Unknown
  paths fail closed and a multi-path selection is committed atomically.
  """
  @spec search_paths(Plan.t(), [String.t()]) :: {:ok, [map()]} | {:error, term()}
  def search_paths(%Plan{} = plan, paths) when is_list(paths) do
    catalog = unloaded_catalog(plan)

    with :ok <- ensure_known_search_paths(plan.catalog, paths) do
      loaded =
        paths
        |> Enum.flat_map(&resolve_search_path(plan, catalog, &1))
        |> Enum.uniq_by(&Map.get(&1, "name"))

      if length(loaded) <= @max_result_limit do
        {:ok, Enum.map(loaded, &Map.put(&1, "defer_loading", true))}
      else
        {:error, {:tool_search_result_limit_exceeded, length(loaded), @max_result_limit}}
      end
    end
  end

  @doc """
  Returns whether an output item is a call of the synthesized search tool.
  """
  @spec search_call_item?(Plan.t() | nil, map()) :: boolean()
  def search_call_item?(%Plan{tool_name: tool_name}, %{"type" => "function_call", "name" => name}),
      do: name == tool_name

  def search_call_item?(_plan, _item), do: false

  @doc """
  Rewrites one provider `function_call` output item into the public
  `tool_search_call` item shape.
  """
  @spec public_search_call(Plan.t(), map()) :: map()
  def public_search_call(%Plan{} = plan, %{} = item) do
    %{
      "type" => "tool_search_call",
      "id" => public_item_id(item, "ts_call"),
      "call_id" => public_search_call_id(plan, item),
      "status" => Map.get(item, "status", "completed"),
      "execution" => Atom.to_string(plan.execution),
      "arguments" => strict_arguments(Map.get(item, "arguments"))
    }
  end

  @doc """
  Builds the public `tool_search_output` item for one executed server search.
  """
  @spec public_search_output(Plan.t(), map(), [map()]) :: map()
  def public_search_output(%Plan{execution: :server}, %{} = call_item, loaded_tools) do
    %{
      "type" => "tool_search_output",
      "id" => public_item_id(%{"call_id" => Map.get(call_item, "call_id")}, "ts_out"),
      "call_id" => nil,
      "status" => "completed",
      "execution" => "server",
      "tools" => public_tool_specs(loaded_tools)
    }
  end

  @doc """
  Builds the downstream `function_call_output` that answers one search call.
  """
  @spec downstream_search_output(map(), [map()]) :: map()
  def downstream_search_output(%{} = call_item, loaded_tools) do
    %{
      "type" => "function_call_output",
      "call_id" => Map.get(call_item, "call_id"),
      "output" => render_search_result_text(loaded_tools)
    }
  end

  @doc """
  Merges freshly loaded tools into the plan and returns the updated downstream
  tools array for the next server round.
  """
  @spec load_tools(Plan.t(), [map()], [map()]) ::
          {:ok, Plan.t(), [map()]} | {:error, term()}
  def load_tools(%Plan{} = plan, downstream_tools, loaded_tools) do
    with {:ok, loaded_contracts} <-
           ToolContract.validate_loaded(loaded_tools,
             known: plan.contracts,
             reserved_names: [PTC.tool_name(), plan.tool_name || @default_tool_name]
           ),
         loaded =
           Enum.reject(loaded_contracts, &MapSet.member?(plan.loaded_names, &1.provider_name)) do
      merge_loaded_tools(plan, downstream_tools, loaded)
    end
  end

  defp merge_loaded_tools(plan, downstream_tools, []), do: {:ok, plan, downstream_tools}

  defp merge_loaded_tools(plan, downstream_tools, loaded) do
    {direct, program_bindings} = PTC.partition_tools(loaded, plan.ptc)

    with {:ok, ptc} <- PTC.load_bindings(plan.ptc, program_bindings) do
      plan = %{
        plan
        | contracts: merge_contracts(plan.contracts, loaded),
          loaded_names: Enum.into(Enum.map(loaded, & &1.provider_name), plan.loaded_names),
          provider_tool_paths: Map.merge(plan.provider_tool_paths, provider_tool_paths(loaded)),
          ptc: ptc
      }

      downstream_tools =
        downstream_tools
        |> Enum.reject(&(Map.get(&1, "name") == PTC.tool_name()))
        |> Kernel.++(Enum.map(direct, &ToolContract.provider_spec/1))
        |> PTC.append_provider_tool(ptc)

      {:ok, plan, downstream_tools}
    end
  end

  @doc false
  @spec list_tools(map()) :: [map()]
  def list_tools(%{} = request) do
    case additional_tools_carrier(request) do
      nil -> list_of_maps(Map.get(request, "tools"))
      {_index, item} -> list_of_maps(Map.get(item, "tools"))
    end
  end

  @doc false
  @spec put_tools(map(), [map()]) :: map()
  def put_tools(%{} = request, tools) when is_list(tools) do
    case additional_tools_carrier(request) do
      nil ->
        Map.put(request, "tools", tools)

      {index, item} ->
        input =
          request
          |> Map.get("input")
          |> List.replace_at(index, Map.put(item, "tools", tools))

        request
        |> Map.put("input", input)
        |> Map.put("tools", nil)
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Request planning
  # ─────────────────────────────────────────────────────────────────

  defp build_plan(request, declaration, contracts, passthrough_tools, ptc, history) do
    deferred = Enum.filter(contracts, & &1.deferred?)
    remaining_tools = Enum.reject(contracts, & &1.deferred?)
    execution = execution_mode(declaration, deferred)
    tool_name = declared_tool_name(declaration)

    with :ok <- validate_search_execution_contract(declaration, execution),
         :ok <- validate_search_history(history),
         {:ok, input_items, loaded_spec_groups, current_client_loaded_spec_groups,
          server_loaded_spec_groups} <-
           rewrite_input_items(history, tool_name),
         {:ok, loaded_tools} <-
           validate_loaded_history(
             loaded_spec_groups,
             contracts,
             [PTC.tool_name(), tool_name]
           ),
         {:ok, current_client_loaded_tools} <-
           validate_loaded_history(
             current_client_loaded_spec_groups,
             contracts,
             [PTC.tool_name(), tool_name]
           ),
         {:ok, server_loaded_tools} <-
           validate_loaded_history(
             server_loaded_spec_groups,
             contracts,
             [PTC.tool_name(), tool_name]
           ) do
      search_declared? = not is_nil(declaration) or deferred != []

      callable_loaded_tools =
        case {search_declared?, execution} do
          {true, :client} ->
            current_client_loaded_tools

          {true, :server} ->
            deferred_names = MapSet.new(deferred, & &1.provider_name)
            Enum.filter(server_loaded_tools, &MapSet.member?(deferred_names, &1.provider_name))

          {false, _execution} ->
            []
        end

      {direct_tools, program_bindings} =
        PTC.partition_tools(remaining_tools ++ callable_loaded_tools, ptc)

      with {:ok, ptc} <- PTC.build_plan(ptc, program_bindings, history),
           :ok <- ensure_no_tool_name_collision(direct_tools, passthrough_tools, tool_name),
           :ok <- PTC.ensure_no_collision(direct_tools, passthrough_tools, ptc),
           :ok <- validate_search_surface_paths(deferred, execution) do
        catalog = Enum.map(deferred, &expanded_spec/1)
        callable_loaded_specs = Enum.map(callable_loaded_tools, &expanded_spec/1)

        synthesized =
          synthesized_search_tool(
            tool_name,
            declaration,
            execution,
            catalog,
            callable_loaded_specs
          )

        plan = %Plan{
          execution: if(search_declared?, do: execution),
          tool_name: if(search_declared?, do: tool_name),
          synthesized_tool: if(search_declared?, do: synthesized),
          catalog: catalog,
          search_context: search_context(Map.get(request, "input")),
          contracts: merge_contracts(contracts, loaded_tools),
          loaded_names: MapSet.new(Enum.map(callable_loaded_tools, & &1.provider_name)),
          provider_tool_paths: provider_tool_paths(remaining_tools ++ deferred ++ loaded_tools),
          ptc: ptc
        }

        provider_tools =
          passthrough_tools ++
            Enum.map(direct_tools, &ToolContract.provider_spec/1) ++
            if(search_declared?, do: [synthesized], else: [])

        provider_tools = PTC.append_provider_tool(provider_tools, ptc)

        provider_request =
          request
          |> put_input(input_items)
          |> put_tools(provider_tools)

        {:ok, provider_request, plan}
      end
    end
  end

  defp additional_tools_carrier(%{"input" => input}) when is_list(input) do
    input
    |> Enum.with_index()
    |> Enum.find_value(fn
      {%{"type" => "additional_tools"} = item, index} -> {index, item}
      {_item, _index} -> nil
    end)
  end

  defp additional_tools_carrier(_request), do: nil

  defp provider_tool_paths(tools) do
    tools
    |> Enum.filter(&is_binary(&1.namespace))
    |> Map.new(fn descriptor ->
      {descriptor.provider_name,
       %{
         "namespace" => descriptor.namespace,
         "name" => descriptor.name
       }}
    end)
  end

  @doc false
  @spec public_function_call(Plan.t(), map()) :: map()
  def public_function_call(%Plan{} = plan, %{"name" => provider_name} = item) do
    case Map.get(plan.provider_tool_paths, provider_name) do
      %{"namespace" => namespace, "name" => name} ->
        item
        |> Map.put("namespace", namespace)
        |> Map.put("name", name)

      nil ->
        item
    end
  end

  def public_function_call(_plan, item), do: item

  defp split_tool_search_declaration(tools) do
    case Enum.split_with(tools, &(Map.get(&1, "type") == "tool_search")) do
      {[], plain} ->
        {:ok, nil, plain}

      {[declaration], plain} ->
        with :ok <- validate_tool_search_declaration(declaration) do
          {:ok, declaration, plain}
        end

      {_multiple, _plain} ->
        {:error, {:invalid_tool_search, :duplicate_declaration}}
    end
  end

  defp validate_tool_search_declaration(declaration) do
    cond do
      Map.get(declaration, "execution") not in [nil, "client", "server"] ->
        {:error, {:invalid_tool_search, :invalid_execution}}

      Map.has_key?(declaration, "name") and
          not (is_binary(declaration["name"]) and declaration["name"] != "") ->
        {:error, {:invalid_tool_search, :invalid_name}}

      Map.has_key?(declaration, "description") and
          not is_binary(declaration["description"]) ->
        {:error, {:invalid_tool_search, :invalid_description}}

      Map.has_key?(declaration, "parameters") and not is_map(declaration["parameters"]) ->
        {:error, {:invalid_tool_search, :invalid_parameters}}

      true ->
        :ok
    end
  end

  defp validate_search_execution_contract(
         %{"parameters" => %{}},
         :server
       ),
       do: {:error, {:invalid_tool_search, :server_custom_parameters_unsupported}}

  defp validate_search_execution_contract(_declaration, _execution), do: :ok

  defp execution_mode(declaration, deferred) do
    case declaration && Map.get(declaration, "execution") do
      "server" -> :server
      "client" -> :client
      # codex declares tool_search without an execution field and keeps its
      # catalog local, so an empty declared catalog can only mean client mode.
      _unspecified when deferred == [] -> :client
      _unspecified -> :server
    end
  end

  defp declared_tool_name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp declared_tool_name(_declaration), do: @default_tool_name

  defp ensure_no_tool_name_collision(base_tools, passthrough_tools, tool_name) do
    collision? =
      Enum.any?(base_tools, &(&1.provider_name == tool_name)) or
        Enum.any?(passthrough_tools, &(Map.get(&1, "name") == tool_name))

    case collision? do
      false -> :ok
      true -> {:error, {:invalid_tool_search, {:tool_name_collision, tool_name}}}
    end
  end

  defp validate_search_surface_paths(_deferred, execution) when execution != :server, do: :ok

  defp validate_search_surface_paths(deferred, :server) do
    root_paths =
      deferred
      |> Enum.filter(&is_nil(&1.namespace))
      |> MapSet.new(& &1.name)

    namespace_paths =
      deferred
      |> Enum.filter(&is_binary(&1.namespace))
      |> MapSet.new(& &1.namespace)

    case root_paths |> MapSet.intersection(namespace_paths) |> Enum.sort() do
      [] -> :ok
      [path | _rest] -> {:error, {:invalid_tool_search, {:surface_path_collision, path}}}
    end
  end

  defp split_contract_tools(tools) do
    Enum.split_with(tools, fn
      %{"type" => type} when type in ["function", "custom", "namespace"] -> true
      _tool -> false
    end)
  end

  defp validate_passthrough_tools(tools) do
    Enum.reduce_while(tools, :ok, fn
      %{} = tool, :ok ->
        if Map.has_key?(tool, "allowed_callers") or Map.get(tool, "defer_loading") == true do
          {:halt, {:error, {:unsupported_tool_type, Map.get(tool, "type")}}}
        else
          {:cont, :ok}
        end

      tool, :ok ->
        {:halt, {:error, {:invalid_tool_contract, {:tool_must_be_an_object, tool}}}}
    end)
  end

  defp validate_managed_history(
         %ResponseItems.History{entries: entries} = history,
         search_managed?,
         ptc
       ) do
    settled_program_history? = settled_program_history?(history)

    Enum.reduce_while(entries, :ok, fn %{item: item}, :ok ->
      cond do
        search_history_item?(item) and not search_managed? ->
          {:halt, {:error, {:invalid_tool_search_history, :declaration_missing}}}

        program_history_item?(item) and not PTC.enabled?(ptc) and
            not settled_program_history? ->
          {:halt, {:error, {:invalid_program, :declaration_missing}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp settled_program_history?(%ResponseItems.History{error: nil, ledger: ledger}) do
    groups = ResponseItems.program_groups(ledger)
    groups != [] and Enum.all?(groups, & &1.output)
  end

  defp settled_program_history?(_history), do: false

  defp settled_search_history?(%ResponseItems.History{error: nil, ledger: ledger}) do
    pairs = ResponseItems.search_pairs(ledger)
    pairs != [] and Enum.all?(pairs, & &1.output)
  end

  defp settled_search_history?(_history), do: false

  defp client_search_history?(%ResponseItems.History{entries: entries}) do
    search_items =
      Enum.flat_map(entries, fn
        %{item: %{"type" => type} = item}
        when type in ["tool_search_call", "tool_search_output"] ->
          [item]

        _entry ->
          []
      end)

    search_items != [] and
      Enum.all?(search_items, &(Map.get(&1, "execution") == "client"))
  end

  defp search_history_item?(%{"type" => type})
       when type in ["tool_search_call", "tool_search_output"],
       do: true

  defp search_history_item?(_item), do: false

  defp program_history_item?(%{"type" => type}) when type in ["program", "program_output"],
    do: true

  defp program_history_item?(%{"caller" => %{"type" => "program"}}), do: true
  defp program_history_item?(_item), do: false

  defp validate_history_error(%ResponseItems.History{error: nil}), do: :ok

  defp validate_history_error(%ResponseItems.History{
         error: %{reason: reason, item: item},
         ledger: ledger
       }) do
    if search_history_item?(item) do
      {:error, {:invalid_tool_search_history, search_history_error(reason, item, ledger)}}
    else
      {:error, {:invalid_program, PTC.history_error(reason, item, ledger)}}
    end
  end

  defp search_history_error(
         reason,
         %{"type" => "tool_search_call", "execution" => "client", "call_id" => call_id},
         _ledger
       )
       when elem(reason, 0) in [
              :duplicate_history_item,
              :conflicting_call_pair,
              :conflicting_duplicate_item
            ],
       do: {:duplicate_client_search_call, call_id}

  defp search_history_error(
         reason,
         %{"type" => "tool_search_output", "execution" => "client", "call_id" => call_id},
         _ledger
       )
       when elem(reason, 0) in [
              :duplicate_history_item,
              :conflicting_output_pair,
              :conflicting_duplicate_item
            ],
       do: {:duplicate_client_search_output, call_id}

  defp search_history_error(
         {:orphan_call_output, _pair_key, _type},
         %{"execution" => "client", "call_id" => call_id},
         ledger
       ) do
    if Enum.any?(ResponseItems.search_pairs(ledger), &is_nil(&1.output)),
      do: {:mismatched_client_search_output, call_id},
      else: {:orphan_client_search_output, call_id}
  end

  defp search_history_error(
         {:orphan_call_output, _pair_key, _type},
         %{"execution" => "server"},
         _ledger
       ),
       do: :orphan_server_search_output

  defp search_history_error(
         {:invalid_tool_search_output, call_id} = reason,
         %{} = item,
         _ledger
       ) do
    cond do
      Map.get(item, "execution") not in ["client", "server"] ->
        {:invalid_search_output_id, call_id}

      Map.get(item, "status") != "completed" ->
        case Map.get(item, "status") do
          nil -> {:incomplete_tool_search_output, call_id}
          status -> {:incomplete_tool_search_output, call_id, status}
        end

      true ->
        reason
    end
  end

  defp search_history_error(reason, _item, _ledger), do: reason

  defp validate_search_history(%ResponseItems.History{} = history) do
    with :ok <- validate_search_entries(history.entries) do
      case Enum.find(ResponseItems.search_pairs(history.ledger), &is_nil(&1.output)) do
        nil ->
          :ok

        %{pair_key: pair_key, call: %{item: item}} ->
          reason =
            case pair_key do
              {:search, :client, call_id} ->
                {:unanswered_client_search_call, call_id}

              {:search, :server, _ordinal} ->
                {:unanswered_server_search_call, replay_search_call_id(item, pair_key)}
            end

          {:error, {:invalid_tool_search_history, reason}}
      end
    end
  end

  defp validate_search_entries(entries) do
    Enum.reduce_while(entries, :ok, fn
      %{item: %{"type" => "tool_search_call"} = item}, :ok ->
        case validate_search_call_for_replay(item) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:invalid_tool_search_history, reason}}}
        end

      %{item: %{"type" => "tool_search_output"} = item}, :ok ->
        case validate_search_output_for_replay(item) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:invalid_tool_search_history, reason}}}
        end

      _entry, :ok ->
        {:cont, :ok}
    end)
  end

  defp validate_search_call_for_replay(item) do
    with :ok <- validate_search_item_caller(item),
         :ok <- ResponseItems.validate_executable_call(item) do
      :ok
    else
      {:error, {:incomplete_call_item, _type, call_id}} ->
        {:error, {:incomplete_tool_search_call, call_id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Input item rewriting (history replay)
  # ─────────────────────────────────────────────────────────────────

  defp rewrite_input_items(%ResponseItems.History{input: input}, _tool_name)
       when not is_list(input),
       do: {:ok, input, [], [], []}

  defp rewrite_input_items(%ResponseItems.History{entries: entries}, tool_name) do
    user_boundary = latest_user_message_index(entries)

    Enum.reduce_while(entries, {:ok, [], [], [], []}, fn entry,
                                                         {:ok, items_rev, loaded_groups_rev,
                                                          current_client_loaded_groups_rev,
                                                          server_loaded_groups_rev} ->
      case rewrite_input_entry(entry, tool_name) do
        {:item, item} ->
          {:cont,
           {:ok, [item | items_rev], loaded_groups_rev, current_client_loaded_groups_rev,
            server_loaded_groups_rev}}

        {:search_output, output, loaded} ->
          current_client_loaded_groups_rev =
            if current_client_search_output?(entry, user_boundary) do
              [loaded | current_client_loaded_groups_rev]
            else
              current_client_loaded_groups_rev
            end

          server_loaded_groups_rev =
            if server_search_output?(entry) do
              [loaded | server_loaded_groups_rev]
            else
              server_loaded_groups_rev
            end

          {:cont,
           {:ok, [output | items_rev], [loaded | loaded_groups_rev],
            current_client_loaded_groups_rev, server_loaded_groups_rev}}

        :omit ->
          {:cont,
           {:ok, items_rev, loaded_groups_rev, current_client_loaded_groups_rev,
            server_loaded_groups_rev}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_tool_search_history, reason}}}
      end
    end)
    |> case do
      {:ok, items_rev, loaded_groups_rev, current_client_loaded_groups_rev,
       server_loaded_groups_rev} ->
        {:ok, Enum.reverse(items_rev), Enum.reverse(loaded_groups_rev),
         Enum.reverse(current_client_loaded_groups_rev), Enum.reverse(server_loaded_groups_rev)}

      {:error, _reason} = error ->
        error
    end
  end

  defp latest_user_message_index(entries) do
    Enum.reduce(entries, -1, fn
      %{item: %{"role" => "user"} = item, index: index}, latest ->
        if Map.get(item, "type") in [nil, "message"], do: index, else: latest

      _entry, latest ->
        latest
    end)
  end

  defp validate_loaded_history(spec_groups, known, reserved_names) do
    Enum.reduce_while(spec_groups, {:ok, []}, fn specs, {:ok, loaded} ->
      case ToolContract.validate_loaded(specs,
             known: known ++ loaded,
             reserved_names: reserved_names
           ) do
        {:ok, batch} -> {:cont, {:ok, merge_contracts(loaded, batch)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp current_client_search_output?(
         %{
           item: %{"type" => "tool_search_output", "execution" => "client"},
           index: index
         },
         user_boundary
       ),
       do: index > user_boundary

  defp current_client_search_output?(_entry, _user_boundary), do: false

  defp server_search_output?(%{
         item: %{"type" => "tool_search_output", "execution" => "server"}
       }),
       do: true

  defp server_search_output?(_entry), do: false

  defp rewrite_input_entry(
         %{item: %{"type" => "tool_search_call"} = item, pair_key: pair_key},
         tool_name
       ) do
    call = %{
      "type" => "function_call",
      "name" => tool_name,
      "call_id" => replay_search_call_id(item, pair_key),
      "arguments" => encode_arguments(Map.get(item, "arguments")),
      "status" => "completed"
    }

    {:item, call}
  end

  defp rewrite_input_entry(
         %{item: %{"type" => "tool_search_output"} = item, pair_key: pair_key},
         _tool_name
       ) do
    with {:ok, flat_loaded} <- flat_public_specs(Map.get(item, "tools")) do
      loaded = Map.get(item, "tools")

      output = %{
        "type" => "function_call_output",
        "call_id" => replay_search_call_id(item, pair_key),
        "output" => render_search_result_text(flat_loaded)
      }

      {:search_output, output, loaded}
    end
  end

  defp rewrite_input_entry(%{item: item}, _tool_name) do
    case PTC.provider_history_item(item) do
      {:handled, %{} = provider_item} -> {:item, provider_item}
      {:handled, nil} -> :omit
      :unhandled -> {:item, rewrite_ordinary_input_item(item)}
    end
  end

  defp rewrite_ordinary_input_item(
         %{"type" => type, "namespace" => namespace, "name" => name} = item
       )
       when type in ["function_call", "custom_tool_call"] and is_binary(namespace) and
              is_binary(name) do
    item
    |> Map.put("name", ToolContract.provider_alias(namespace, name))
    |> Map.delete("namespace")
  end

  defp rewrite_ordinary_input_item(item), do: item

  defp replay_search_call_id(_item, {:search, :client, call_id}), do: call_id

  defp replay_search_call_id(_item, {:search, :server, {:ordinal, ordinal}}),
    do: "#{@server_call_id_prefix}replay_#{ordinal}"

  defp replay_search_call_id(item, _pair_key), do: Map.get(item, "call_id")

  defp validate_search_item_caller(item) do
    case Map.get(item, "caller") do
      nil -> :ok
      caller -> {:error, {:tool_search_caller_unsupported, caller}}
    end
  end

  defp validate_search_output_for_replay(item) do
    with :ok <- validate_search_item_caller(item),
         "completed" <- Map.get(item, "status") do
      :ok
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, {:incomplete_tool_search_output, Map.get(item, "call_id")}}
      status -> {:error, {:incomplete_tool_search_output, Map.get(item, "call_id"), status}}
    end
  end

  defp flat_public_specs(specs) when is_list(specs) do
    specs
    |> Enum.reduce_while({:ok, []}, fn
      %{"type" => "namespace", "name" => namespace, "tools" => children}, {:ok, reversed}
      when is_binary(namespace) and namespace != "" and is_list(children) ->
        if Enum.all?(children, &is_map/1) do
          expanded =
            Enum.map(children, fn child ->
              child
              |> Map.put("__ankole_namespace", namespace)
              |> Map.put("__ankole_public_name", Map.get(child, "name"))
            end)

          {:cont, {:ok, Enum.reverse(expanded, reversed)}}
        else
          {:halt, {:error, :namespace_children_must_be_objects}}
        end

      %{} = spec, {:ok, reversed} ->
        {:cont, {:ok, [spec | reversed]}}

      _invalid, _acc ->
        {:halt, {:error, :loaded_tools_must_be_objects}}
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  defp flat_public_specs(_specs), do: {:error, :loaded_tools_must_be_a_list}

  # ─────────────────────────────────────────────────────────────────
  # Synthesized search tool
  # ─────────────────────────────────────────────────────────────────

  defp synthesized_search_tool(tool_name, declaration, execution, deferred, loaded_tools) do
    %{
      "type" => "function",
      "name" => tool_name,
      "description" => search_tool_description(declaration, deferred, loaded_tools),
      "parameters" => search_parameters(declaration, execution)
    }
  end

  defp search_parameters(%{"parameters" => %{} = parameters}, :client), do: parameters

  # Hosted Tool Search selects one or more declared surfaces by path. The
  # downstream provider only sees a synthesized function, so this schema is
  # the compatibility boundary that teaches it the native OpenAI wire shape.
  defp search_parameters(_declaration, :server) do
    %{
      "type" => "object",
      "properties" => %{
        "paths" => %{
          "type" => "array",
          "description" => "Declared root function or namespace paths to load.",
          "items" => %{
            "type" => "string",
            "minLength" => 1,
            "maxLength" => @max_search_path_bytes
          },
          "minItems" => 1,
          "maxItems" => @max_result_limit,
          "uniqueItems" => true
        }
      },
      "required" => ["paths"],
      "additionalProperties" => false
    }
  end

  # Codex's client-executed default declaration has no custom schema. Preserve
  # its query/limit contract; explicit client schemas pass through above.
  defp search_parameters(_declaration, :client) do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "Search text matched against tool names and descriptions."
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum number of tools to load.",
          "minimum" => 1,
          "maximum" => @max_result_limit
        }
      },
      "required" => ["query"],
      "additionalProperties" => false
    }
  end

  defp search_parameters(declaration, _execution), do: search_parameters(declaration, :client)

  defp search_tool_description(declaration, deferred, loaded_tools) do
    declared = declaration && Map.get(declaration, "description")

    base =
      if is_binary(declared) and declared != "" do
        declared
      else
        "Searches deferred tool metadata and loads matching tools for the " <>
          "next model call. Some tools were not provided upfront; use this " <>
          "tool to discover them before calling them."
      end

    case searchable_listing(deferred, loaded_tools) do
      "" -> base
      listing -> base <> "\n\nSearchable tools:\n" <> listing
    end
  end

  # The official hosted mode keeps deferred names and descriptions visible
  # upfront. A plain-function downstream has no schema-free tool slot, so the
  # listing rides inside the search tool description under a fixed budget.
  defp searchable_listing(deferred, loaded_tools) do
    loaded_names = MapSet.new(Enum.map(loaded_tools, & &1["name"]))

    {lines_rev, omitted, _seen, _bytes} =
      Enum.reduce(deferred, {[], 0, MapSet.new(), 0}, fn tool,
                                                         {lines, omitted, seen, bytes} = acc ->
        identity = listing_identity(tool)

        cond do
          MapSet.member?(loaded_names, tool["name"]) or MapSet.member?(seen, identity) ->
            acc

          true ->
            line = listing_line(tool)
            cost = byte_size(line) + 1
            seen = MapSet.put(seen, identity)

            if bytes + cost > @catalog_listing_budget_bytes,
              do: {lines, omitted + 1, seen, bytes},
              else: {[line | lines], omitted, seen, bytes + cost}
        end
      end)

    lines = Enum.reverse(lines_rev)

    case {lines, omitted} do
      {[], _omitted} -> ""
      {lines, 0} -> Enum.join(lines, "\n")
      {lines, omitted} -> Enum.join(lines, "\n") <> "\n- …#{omitted} more, discover via search"
    end
  end

  defp listing_line(%{"name" => name} = tool) do
    {public_name, description} =
      case Map.get(tool, "__ankole_namespace") do
        namespace when is_binary(namespace) ->
          {namespace, Map.get(tool, "__ankole_namespace_description")}

        _root ->
          {name, Map.get(tool, "description")}
      end

    case description do
      description when is_binary(description) and description != "" ->
        "- #{public_name}: #{truncate(description, 160)}"

      _missing ->
        "- #{public_name}"
    end
  end

  defp listing_identity(tool),
    do: Map.get(tool, "__ankole_namespace") || Map.get(tool, "name")

  defp truncate(text, max_bytes) do
    if byte_size(text) <= max_bytes do
      text
    else
      suffix = "…"
      truncated = take_graphemes(text, max(max_bytes - byte_size(suffix), 0), [], 0)

      truncated <> suffix
    end
  end

  defp take_graphemes(_text, budget, acc, bytes) when bytes >= budget,
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp take_graphemes(text, budget, acc, bytes) do
    case String.next_grapheme(text) do
      nil ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()

      {grapheme, rest} ->
        cost = byte_size(grapheme)

        if bytes + cost > budget,
          do: acc |> Enum.reverse() |> IO.iodata_to_binary(),
          else: take_graphemes(rest, budget, [grapheme | acc], bytes + cost)
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Wire value helpers
  # ─────────────────────────────────────────────────────────────────

  defp public_search_call_id(%Plan{execution: :client}, item) do
    case Map.get(item, "call_id") do
      call_id when is_binary(call_id) and call_id != "" -> call_id
      _missing -> nil
    end
  end

  defp public_search_call_id(%Plan{execution: :server}, _item), do: nil

  defp decode_arguments(arguments) when is_map(arguments), do: arguments

  defp decode_arguments(arguments) when is_binary(arguments) do
    case Ankole.JSON.decode(arguments) do
      {:ok, %{} = decoded} -> decoded
      _invalid -> %{"query" => arguments}
    end
  end

  defp decode_arguments(_arguments), do: %{}

  defp strict_arguments(arguments) when is_map(arguments), do: arguments

  defp strict_arguments(arguments) when is_binary(arguments) do
    case Ankole.JSON.decode(arguments) do
      {:ok, %{} = decoded} -> decoded
      _invalid -> nil
    end
  end

  defp strict_arguments(_arguments), do: nil

  defp encode_arguments(arguments) when is_map(arguments), do: Ankole.JSON.encode!(arguments)
  defp encode_arguments(arguments) when is_binary(arguments), do: arguments
  defp encode_arguments(_arguments), do: "{}"

  @doc false
  @spec parse_search_arguments(Plan.t(), map()) ::
          {:ok, %{paths: [String.t()]}} | {:error, term()}
  def parse_search_arguments(%Plan{execution: :server}, %{} = item) do
    arguments = strict_arguments(Map.get(item, "arguments"))

    case arguments do
      %{"paths" => paths} = arguments when is_list(paths) and map_size(arguments) == 1 ->
        validate_search_paths(paths)

      _invalid ->
        {:error, {:invalid_tool_search_arguments, :invalid_shape}}
    end
  end

  @doc false
  @spec parse_search_arguments(map()) :: %{query: String.t(), limit: pos_integer()}
  def parse_search_arguments(%{} = item) do
    arguments = decode_arguments(Map.get(item, "arguments"))

    %{
      query: string_argument(arguments, "query"),
      limit: normalize_limit(Map.get(arguments, "limit"))
    }
  end

  defp validate_search_paths(paths) do
    cond do
      paths == [] ->
        {:error, {:invalid_tool_search_arguments, :paths_required}}

      length(paths) > @max_result_limit ->
        {:error,
         {:invalid_tool_search_arguments, {:too_many_paths, length(paths), @max_result_limit}}}

      Enum.any?(paths, &(not is_binary(&1) or &1 == "")) ->
        {:error, {:invalid_tool_search_arguments, :invalid_path}}

      Enum.any?(paths, &(byte_size(&1) > @max_search_path_bytes)) ->
        {:error, {:invalid_tool_search_arguments, {:path_too_long, @max_search_path_bytes}}}

      length(Enum.uniq(paths)) != length(paths) ->
        {:error, {:invalid_tool_search_arguments, :duplicate_path}}

      true ->
        {:ok, %{paths: paths}}
    end
  end

  defp unloaded_catalog(%Plan{} = plan) do
    Enum.reject(plan.catalog, &MapSet.member?(plan.loaded_names, Map.get(&1, "name")))
  end

  defp tools_for_path(catalog, path) do
    Enum.filter(catalog, fn tool ->
      namespace = Map.get(tool, "__ankole_namespace")

      cond do
        is_binary(namespace) and path == namespace -> true
        is_binary(namespace) -> false
        true -> path == Map.get(tool, "name")
      end
    end)
  end

  defp resolve_search_path(plan, catalog, path) do
    candidates = tools_for_path(catalog, path)

    if Enum.any?(candidates, &is_binary(Map.get(&1, "__ankole_namespace"))) do
      case Index.search(candidates, plan.search_context, @default_result_limit) do
        [] -> candidates
        ranked -> ranked
      end
    else
      candidates
    end
  end

  defp ensure_known_search_paths(catalog, paths) do
    case Enum.find(paths, &(tools_for_path(catalog, &1) == [])) do
      nil -> :ok
      path -> {:error, {:unknown_tool_search_path, path}}
    end
  end

  defp search_context(input) do
    {selected, _bytes} = collect_search_context(input, {[], 0})
    Enum.join(selected, " ")
  end

  defp collect_search_context(_value, {selected, bytes})
       when bytes >= @search_context_budget_bytes,
       do: {selected, bytes}

  defp collect_search_context(value, {selected, bytes}) when is_binary(value) do
    value = truncate(value, @search_context_budget_bytes - 1)
    cost = byte_size(value) + 1

    if bytes + cost > @search_context_budget_bytes,
      do: {selected, bytes},
      else: {[value | selected], bytes + cost}
  end

  defp collect_search_context(value, acc) when is_list(value) do
    value
    |> Enum.reverse()
    |> Enum.reduce_while(acc, fn item, acc ->
      acc = collect_search_context(item, acc)

      if elem(acc, 1) >= @search_context_budget_bytes,
        do: {:halt, acc},
        else: {:cont, acc}
    end)
  end

  defp collect_search_context(%{} = value, acc) do
    ["result", "output", "arguments", "input", "content", "text"]
    |> Enum.reduce_while(acc, fn key, acc ->
      acc = collect_search_context(Map.get(value, key), acc)

      if elem(acc, 1) >= @search_context_budget_bytes,
        do: {:halt, acc},
        else: {:cont, acc}
    end)
  end

  defp collect_search_context(_value, acc), do: acc

  defp string_argument(arguments, key) do
    case Map.get(arguments, key) do
      value when is_binary(value) -> value
      value when is_number(value) -> to_string(value)
      _invalid -> ""
    end
  end

  defp normalize_limit(limit) when is_integer(limit) and limit >= 1,
    do: min(limit, @max_result_limit)

  defp normalize_limit(_limit), do: @default_result_limit

  defp render_search_result_text([]), do: Ankole.JSON.encode!(%{"tools" => []})

  defp render_search_result_text(loaded_tools) do
    Ankole.JSON.encode!(%{
      "tools" =>
        Enum.map(loaded_tools, fn tool ->
          %{"name" => public_tool_path(tool)}
          |> maybe_put("description", tool["description"])
        end)
    })
  end

  defp public_tool_specs(tools) do
    root_tools =
      tools
      |> Enum.reject(&is_binary(Map.get(&1, "__ankole_namespace")))
      |> Enum.map(&public_child_tool/1)

    namespace_tools =
      tools
      |> Enum.filter(&is_binary(Map.get(&1, "__ankole_namespace")))
      |> Enum.group_by(& &1["__ankole_namespace"])
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {namespace, children} ->
        %{
          "type" => "namespace",
          "name" => namespace,
          "description" =>
            hd(children)["__ankole_namespace_description"] || "Tools from #{namespace}.",
          "tools" => Enum.map(children, &public_child_tool/1)
        }
      end)

    root_tools ++ namespace_tools
  end

  defp public_child_tool(tool) do
    public_name = Map.get(tool, "__ankole_public_name") || Map.get(tool, "name")

    tool
    |> Map.put("name", public_name)
    |> Map.put("defer_loading", true)
    |> Map.drop([
      "__ankole_namespace",
      "__ankole_public_name",
      "__ankole_namespace_description",
      "__ankole_search_text"
    ])
  end

  defp expanded_spec(%Descriptor{} = descriptor) do
    descriptor
    |> ToolContract.provider_spec()
    |> Map.put("allowed_callers", descriptor.allowed_callers)
    |> maybe_put_optional("output_schema", descriptor.output_schema)
    |> maybe_put_boolean("defer_loading", descriptor.deferred?)
    |> maybe_put("__ankole_namespace", descriptor.namespace)
    |> maybe_put("__ankole_public_name", if(descriptor.namespace, do: descriptor.name))
    |> maybe_put_optional("__ankole_namespace_description", descriptor.namespace_description)
    |> maybe_put("__ankole_search_text", descriptor.search_text)
  end

  defp merge_contracts(existing, loaded) do
    {order_rev, by_name} = Enum.reduce(existing, {[], %{}}, &merge_contract/2)
    {order_rev, by_name} = Enum.reduce(loaded, {order_rev, by_name}, &merge_contract/2)

    order_rev
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(by_name, &1))
  end

  defp merge_contract(descriptor, {order_rev, by_name}) do
    name = descriptor.provider_name
    order_rev = if Map.has_key?(by_name, name), do: order_rev, else: [name | order_rev]
    {order_rev, Map.put(by_name, name, descriptor)}
  end

  defp public_tool_path(tool) do
    case Map.get(tool, "__ankole_namespace") do
      namespace when is_binary(namespace) -> "#{namespace}.#{tool["__ankole_public_name"]}"
      _root -> Map.get(tool, "name")
    end
  end

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

  defp maybe_put(map, _key, nil), do: map

  defp maybe_put(map, key, value) when is_binary(value) and value != "",
    do: Map.put(map, key, value)

  defp maybe_put(map, _key, _value), do: map

  defp maybe_put_optional(map, _key, nil), do: map
  defp maybe_put_optional(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_boolean(map, key, true), do: Map.put(map, key, true)
  defp maybe_put_boolean(map, _key, false), do: map

  defp put_input(request, input) when is_list(input), do: Map.put(request, "input", input)
  defp put_input(request, _input), do: request

  defp list_of_maps(value) when is_list(value), do: Enum.filter(value, &is_map/1)
  defp list_of_maps(_value), do: []
end
