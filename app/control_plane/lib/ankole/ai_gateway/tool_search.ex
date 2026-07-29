defmodule Ankole.AIGateway.ToolSearch do
  @moduledoc """
  Self-implemented OpenAI tool search, deferred loading, and PTC planning.

  AIGateway implements the official `tool_search` tool type, the
  `defer_loading` tool marker, and the Programmatic Tool Calling surface
  (`allowed_callers`, `program` / `program_output` items) for every downstream
  provider. Upstream providers only see plain function tools and plain
  function call items. The semantic anchors are the official guides
  (developers.openai.com tools-tool-search and
  tools-programmatic-tool-calling, 2026-07) plus the codex
  rust-v0.146.0 wire samples for client-mode search.

  Two search execution modes exist and one request declares one of them:

  - `"client"`: the caller owns the searchable catalog. The model call becomes a
    public `tool_search_call` item with a string `call_id`, the caller answers
    with a `tool_search_output` item on the next request.
  - `"server"`: the request declares the catalog as `defer_loading: true` tools.
    AIGateway hides them from the provider, searches them itself, and loads the
    matching subset inside the same response (`call_id: null`).

  PTC follows the official composition rules: `tool_search` never runs inside a
  program, and deferred tools join program bindings only after loading. Nested
  program calls carry `caller.caller_id` and stay out of the downstream
  conversation; the program transcript reaches the model as the rewritten
  `program` call and its `program_output` result.
  """

  alias Ankole.AIGateway.ToolSearch.Index

  @default_tool_name "tool_search"
  @program_tool_name "program"
  @default_result_limit 8
  @max_result_limit 50
  @catalog_listing_budget_bytes 8_192
  @server_call_id_prefix "ts_srv_"

  defmodule Plan do
    @moduledoc false

    defstruct execution: nil,
              tool_name: nil,
              synthesized_tool: nil,
              catalog: [],
              loaded_names: MapSet.new(),
              provider_tool_paths: %{},
              server_round: 0,
              programmatic?: false,
              program: nil,
              pre_round: nil

    @type program :: %{
            tool_name: String.t(),
            bindings: [String.t()],
            synthesized_tool: map()
          }

    @type pre_round :: %{
            call_id: String.t(),
            code: String.t(),
            fingerprint: String.t(),
            memo: [map()]
          }

    @type t :: %__MODULE__{
            execution: :server | :client | nil,
            tool_name: String.t() | nil,
            synthesized_tool: map() | nil,
            catalog: [map()],
            loaded_names: MapSet.t(String.t()),
            provider_tool_paths: %{String.t() => map()},
            server_round: non_neg_integer(),
            programmatic?: boolean(),
            program: program() | nil,
            pre_round: pre_round() | nil
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
         {:ok, programmatic?, plain_tools} <- split_programmatic_declaration(plain_tools),
         {:ok, expanded_tools} <- expand_namespaces(plain_tools),
         {:ok, deferred, remaining_tools} <- split_deferred_tools(expanded_tools) do
      if is_nil(declaration) and deferred == [] and not programmatic? and
           Enum.all?(remaining_tools, &(allowed_callers(&1) == [])) do
        {:ok, request, nil}
      else
        build_plan(request, declaration, deferred, remaining_tools, programmatic?)
      end
    end
  end

  @doc """
  Executes one server-mode search over the plan catalog.

  Returns the loaded tool specs with their `defer_loading` marker restored, the
  way official `tool_search_output.tools` carries them.
  """
  @spec search(Plan.t(), String.t(), pos_integer() | nil) :: [map()]
  def search(%Plan{} = plan, query, limit) when is_binary(query) do
    limit = normalize_limit(limit)

    plan.catalog
    |> Index.search(query, limit)
    |> Enum.map(&Map.put(&1, "defer_loading", true))
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
    call = %{
      "type" => "tool_search_call",
      "id" => public_item_id(item, "ts_call"),
      "call_id" => public_search_call_id(plan, item),
      "status" => "completed",
      "execution" => Atom.to_string(plan.execution),
      "arguments" => decode_arguments(Map.get(item, "arguments"))
    }

    # Server-mode calls carry a null official call_id; the provider pairing key
    # rides along so a stateless replay reconnects the call with its output.
    case {plan.execution, Map.get(item, "call_id")} do
      {:server, provider_call_id} when is_binary(provider_call_id) ->
        Map.put(call, "provider_call_id", provider_call_id)

      _client_or_missing ->
        call
    end
  end

  @doc """
  Builds the public `tool_search_output` item for one executed server search.
  """
  @spec public_search_output(Plan.t(), map(), [map()]) :: map()
  def public_search_output(%Plan{execution: :server}, %{} = call_item, loaded_tools) do
    %{
      "type" => "tool_search_output",
      "id" => public_item_id(call_item, "ts_out"),
      "call_id" => nil,
      "status" => "completed",
      "execution" => "server",
      "tools" => public_tool_specs(loaded_tools),
      "provider_call_id" => Map.get(call_item, "call_id")
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
  @spec load_tools(Plan.t(), [map()], [map()]) :: {Plan.t(), [map()]}
  def load_tools(%Plan{} = plan, downstream_tools, loaded_tools) do
    loaded =
      loaded_tools
      |> Enum.reject(&loaded?(plan, &1))

    {direct, program_bindings} = partition_program_tools(loaded, plan.programmatic?)
    program = merge_program(plan.program, program_bindings)

    plan = %{
      plan
      | loaded_names: Enum.into(Enum.map(loaded, & &1["name"]), plan.loaded_names),
        provider_tool_paths: Map.merge(plan.provider_tool_paths, provider_tool_paths(loaded)),
        server_round: plan.server_round + 1
    }

    plan = %{plan | program: program}

    downstream_tools =
      downstream_tools
      |> Enum.reject(&(Map.get(&1, "name") == @program_tool_name))
      |> Kernel.++(Enum.map(direct, &provider_safe_tool/1))
      |> maybe_append_program_tool(program)

    {plan, downstream_tools}
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

  defp build_plan(request, declaration, deferred, remaining_tools, programmatic?) do
    execution = execution_mode(declaration, deferred)
    tool_name = declared_tool_name(declaration)

    with :ok <- ensure_unique_provider_names(deferred ++ remaining_tools),
         {:ok, input_items, loaded_tools, pre_round} <-
           rewrite_input_items(Map.get(request, "input"), tool_name) do
      {direct_tools, program_bindings} =
        partition_program_tools(remaining_tools ++ loaded_tools, programmatic?)

      program = merge_program(nil, program_bindings)

      with :ok <- ensure_no_tool_name_collision(direct_tools, tool_name),
           :ok <- ensure_no_program_collision(direct_tools, program),
           {:ok, pre_round} <- resolve_pre_round(pre_round, program) do
        search_declared? = not is_nil(declaration) or deferred != []
        synthesized = synthesized_search_tool(tool_name, declaration, deferred, loaded_tools)

        plan = %Plan{
          execution: if(search_declared?, do: execution),
          tool_name: if(search_declared?, do: tool_name),
          synthesized_tool: if(search_declared?, do: synthesized),
          catalog: deferred,
          loaded_names: MapSet.new(Enum.map(loaded_tools, & &1["name"])),
          provider_tool_paths: provider_tool_paths(remaining_tools ++ deferred ++ loaded_tools),
          programmatic?: programmatic?,
          program: program,
          pre_round: pre_round
        }

        provider_tools =
          Enum.map(direct_tools, &provider_safe_tool/1) ++
            if(search_declared?, do: [synthesized], else: []) ++
            if(program, do: [program.synthesized_tool], else: [])

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

  # ─────────────────────────────────────────────────────────────────
  # PTC surface
  # ─────────────────────────────────────────────────────────────────

  defp split_programmatic_declaration(tools) do
    case Enum.split_with(tools, &(Map.get(&1, "type") == "programmatic_tool_calling")) do
      {[], plain} -> {:ok, false, plain}
      {[_declaration], plain} -> {:ok, true, plain}
      {_multiple, _plain} -> {:error, {:invalid_program, :duplicate_declaration}}
    end
  end

  # `allowed_callers` partitions tools per the official semantics. A
  # programmatic-only tool remains unavailable until the request declares the
  # `programmatic_tool_calling` surface.
  defp partition_program_tools(tools, programmatic?) do
    Enum.reduce(tools, {[], []}, fn tool, {direct, bindings} ->
      callers = allowed_callers(tool)
      direct? = callers == [] or "direct" in callers
      programmatic_tool? = programmatic? and "programmatic" in callers

      {
        if(direct?, do: direct ++ [tool], else: direct),
        if(programmatic_tool?, do: bindings ++ [tool["name"]], else: bindings)
      }
    end)
  end

  defp merge_program(program, []), do: program

  defp merge_program(program, bindings) do
    bindings =
      ((program && program.bindings) || [])
      |> Kernel.++(bindings)
      |> Enum.uniq()

    %{
      tool_name: @program_tool_name,
      bindings: bindings,
      synthesized_tool: synthesized_program_tool(bindings)
    }
  end

  defp maybe_append_program_tool(tools, nil), do: tools
  defp maybe_append_program_tool(tools, program), do: tools ++ [program.synthesized_tool]

  defp provider_tool_paths(tools) do
    tools
    |> Enum.filter(&is_binary(Map.get(&1, "__ankole_namespace")))
    |> Map.new(fn tool ->
      {tool["name"],
       %{
         "namespace" => tool["__ankole_namespace"],
         "name" => tool["__ankole_public_name"]
       }}
    end)
  end

  defp allowed_callers(%{"allowed_callers" => callers}) when is_list(callers),
    do: Enum.filter(callers, &is_binary/1)

  defp allowed_callers(_tool), do: []

  defp ensure_no_program_collision(_base_tools, nil), do: :ok

  defp ensure_no_program_collision(base_tools, %{tool_name: tool_name}) do
    case Enum.any?(base_tools, &(Map.get(&1, "name") == tool_name)) do
      false -> :ok
      true -> {:error, {:invalid_program, {:tool_name_collision, tool_name}}}
    end
  end

  defp synthesized_program_tool(bindings) do
    %{
      "type" => "function",
      "name" => @program_tool_name,
      "description" =>
        "Runs JavaScript that orchestrates tool calls: loops, conditionals, " <>
          "parallel calls with Promise.all, and intermediate processing. " <>
          "The code runs in an isolated runtime without Node, network, " <>
          "filesystem, or timers. Call tools with `await tools.<name>(args)`; " <>
          "available bindings: #{Enum.join(bindings, ", ")}. Emit results " <>
          "with `text(value)` or `image(url)`. tool_search is not callable " <>
          "from code; load deferred tools before starting a program.",
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
  end

  @doc false
  @spec program_fingerprint(String.t(), [String.t()]) :: String.t()
  def program_fingerprint(code, bindings) do
    :crypto.hash(:sha256, [code, 0, Enum.join(Enum.sort(bindings), ",")])
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  @doc false
  @spec program_call_item?(Plan.t() | nil, map()) :: boolean()
  def program_call_item?(
        %Plan{program: %{tool_name: tool_name}},
        %{"type" => "function_call", "name" => name}
      ),
      do: name == tool_name

  def program_call_item?(_plan, _item), do: false

  @doc false
  @spec parse_program_arguments(map()) :: %{code: String.t()}
  def parse_program_arguments(%{} = item) do
    arguments = decode_arguments(Map.get(item, "arguments"))

    %{code: string_argument(arguments, "code")}
  end

  @doc """
  Builds the public `program` item for one model-issued program call.
  """
  @spec public_program_item(Plan.t(), map()) :: map()
  def public_program_item(%Plan{program: %{bindings: bindings}}, %{} = call_item) do
    %{code: code} = parse_program_arguments(call_item)

    %{
      "type" => "program",
      "id" => public_item_id(call_item, "prog"),
      "call_id" => Map.get(call_item, "call_id"),
      "code" => code,
      "fingerprint" => program_fingerprint(code, bindings)
    }
  end

  @doc """
  Builds the public `program_output` item for one settled program run.
  """
  @spec public_program_output(String.t(), map()) :: map()
  def public_program_output(call_id, outcome) do
    %{
      "type" => "program_output",
      "id" => public_item_id(%{"call_id" => call_id}, "prog_out"),
      "call_id" => call_id,
      "status" => if(outcome[:status] == :completed, do: "completed", else: "incomplete"),
      "result" => program_result(outcome)
    }
  end

  @doc """
  Builds one nested `function_call` item issued by a paused program.
  """
  @spec nested_program_call(String.t(), non_neg_integer(), map()) :: map()
  def nested_program_call(program_call_id, index, %{name: name, arguments: arguments}) do
    %{
      "type" => "function_call",
      "id" => "#{program_call_id}_fc#{index}",
      "call_id" => "#{program_call_id}_c#{index}",
      "name" => name,
      "arguments" => Ankole.JSON.encode!(arguments),
      "status" => "completed",
      "caller" => %{"type" => "program", "caller_id" => program_call_id}
    }
  end

  @doc """
  Builds the downstream `function_call_output` answering one program call.
  """
  @spec downstream_program_output(String.t(), map()) :: map()
  def downstream_program_output(call_id, %{} = outcome) do
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

  defp program_result(outcome) do
    parts =
      outcome
      |> Map.get(:output, [])
      |> Enum.map(fn part -> %{"kind" => part[:kind], "value" => part[:value]} end)

    case {parts, outcome[:error]} do
      {[%{"kind" => :text, "value" => value}], nil} when is_binary(value) -> value
      {[%{"kind" => "text", "value" => value}], nil} when is_binary(value) -> value
      {parts, nil} -> Ankole.JSON.encode!(parts)
      {parts, error} -> Ankole.JSON.encode!(%{"error" => error, "output" => parts})
    end
  end

  defp split_tool_search_declaration(tools) do
    case Enum.split_with(tools, &(Map.get(&1, "type") == "tool_search")) do
      {[], plain} -> {:ok, nil, plain}
      {[declaration], plain} -> {:ok, declaration, plain}
      {_multiple, _plain} -> {:error, {:invalid_tool_search, :duplicate_declaration}}
    end
  end

  defp expand_namespaces(tools) do
    Enum.reduce_while(tools, {:ok, []}, fn
      %{"type" => "namespace"} = namespace, {:ok, expanded} ->
        case expand_namespace(namespace) do
          {:ok, children} -> {:cont, {:ok, expanded ++ children}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      tool, {:ok, expanded} ->
        {:cont, {:ok, expanded ++ [tool]}}
    end)
  end

  defp expand_namespace(%{"name" => namespace_name, "tools" => tools} = namespace)
       when is_binary(namespace_name) and namespace_name != "" and is_list(tools) do
    description = Map.get(namespace, "description")

    children =
      Enum.map(tools, fn child ->
        public_name = Map.get(child, "name")

        child
        |> Map.put("name", provider_tool_name(namespace_name, public_name))
        |> Map.put("__ankole_namespace", namespace_name)
        |> Map.put("__ankole_public_name", public_name)
        |> Map.put("__ankole_namespace_description", description)
      end)

    case Enum.find(children, &(not deferrable_tool?(&1))) do
      nil ->
        {:ok, children}

      child ->
        {:error, {:invalid_tool_search, {:invalid_namespace_child, Map.get(child, "type")}}}
    end
  end

  defp expand_namespace(namespace),
    do: {:error, {:invalid_tool_search, {:invalid_namespace, Map.get(namespace, "name")}}}

  defp split_deferred_tools(tools) do
    {deferred, base} = Enum.split_with(tools, &(Map.get(&1, "defer_loading") == true))

    case Enum.find(deferred, &(not deferrable_tool?(&1))) do
      nil ->
        deferred = Enum.map(deferred, &Map.delete(&1, "defer_loading"))
        {:ok, deferred, base}

      tool ->
        {:error, {:invalid_tool_search, {:undeferrable_tool, Map.get(tool, "type")}}}
    end
  end

  defp deferrable_tool?(%{"type" => type, "name" => name})
       when type in ["function", "custom"] and is_binary(name) and name != "",
       do: true

  defp deferrable_tool?(_tool), do: false

  defp ensure_unique_provider_names(tools) do
    duplicate =
      tools
      |> Enum.map(&Map.get(&1, "name"))
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.find(fn {_name, count} -> count > 1 end)

    case duplicate do
      nil -> :ok
      {name, _count} -> {:error, {:invalid_tool_search, {:provider_name_collision, name}}}
    end
  end

  defp provider_tool_name(namespace, name) when is_binary(namespace) and is_binary(name) do
    combined = "#{namespace}__#{name}"

    if byte_size(combined) <= 64 and Regex.match?(~r/^[A-Za-z0-9_-]+$/, combined) do
      combined
    else
      digest =
        :crypto.hash(:sha256, combined)
        |> Base.encode16(case: :lower)
        |> binary_part(0, 12)

      readable =
        combined
        |> String.replace(~r/[^A-Za-z0-9_-]/, "_")
        |> truncate_identifier(48)

      "#{readable}_#{digest}"
    end
  end

  defp provider_tool_name(_namespace, _name), do: ""

  defp truncate_identifier(value, max_bytes) do
    value
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn grapheme, {result, bytes} ->
      size = byte_size(grapheme)

      if bytes + size > max_bytes,
        do: {:halt, {result, bytes}},
        else: {:cont, {result <> grapheme, bytes + size}}
    end)
    |> elem(0)
  end

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

  defp ensure_no_tool_name_collision(base_tools, tool_name) do
    case Enum.any?(base_tools, &(Map.get(&1, "name") == tool_name)) do
      false -> :ok
      true -> {:error, {:invalid_tool_search, {:tool_name_collision, tool_name}}}
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Input item rewriting (history replay)
  # ─────────────────────────────────────────────────────────────────

  defp rewrite_input_items(input, tool_name) when is_list(input) do
    initial = %{items: [], loaded: [], programs: %{}, order: []}

    state =
      Enum.reduce(input, initial, fn item, state ->
        rewrite_input_item(item, tool_name, state)
      end)

    {:ok, state.items, dedupe_loaded(state.loaded), state}
  end

  defp rewrite_input_items(input, _tool_name), do: {:ok, input, [], nil}

  defp rewrite_input_item(%{"type" => "tool_search_call"} = item, tool_name, state) do
    call = %{
      "type" => "function_call",
      "name" => tool_name,
      "call_id" => replay_call_id(item),
      "arguments" => encode_arguments(Map.get(item, "arguments"))
    }

    %{state | items: state.items ++ [call]}
  end

  defp rewrite_input_item(%{"type" => "tool_search_output"} = item, _tool_name, state) do
    loaded =
      item
      |> Map.get("tools")
      |> list_of_maps()
      |> normalize_loaded_tools()

    output = %{
      "type" => "function_call_output",
      "call_id" => replay_call_id(item),
      "output" => render_search_result_text(loaded)
    }

    %{state | items: state.items ++ [output], loaded: state.loaded ++ loaded}
  end

  defp rewrite_input_item(%{"type" => "program"} = item, _tool_name, state) do
    call_id = Map.get(item, "call_id")
    code = Map.get(item, "code") || ""

    call = %{
      "type" => "function_call",
      "name" => @program_tool_name,
      "call_id" => call_id,
      "arguments" => Ankole.JSON.encode!(%{"code" => code}),
      "status" => "completed"
    }

    group = %{code: code, fingerprint: Map.get(item, "fingerprint"), calls: [], settled?: false}

    %{
      state
      | items: state.items ++ [call],
        programs: Map.put(state.programs, call_id, group),
        order: state.order ++ [call_id]
    }
  end

  defp rewrite_input_item(%{"type" => "program_output"} = item, _tool_name, state) do
    call_id = Map.get(item, "call_id")

    output = %{
      "type" => "function_call_output",
      "call_id" => call_id,
      "output" => Ankole.JSON.encode!(Map.take(item, ["status", "result"]))
    }

    %{
      state
      | items: state.items ++ [output],
        programs: mark_program_settled(state.programs, call_id)
    }
  end

  # Nested program calls and their outputs never reach the provider; they feed
  # the replay memo instead. The program transcript reaches the model as the
  # rewritten `program` call and its `program_output` result.
  defp rewrite_input_item(
         %{"type" => "function_call", "caller" => %{"caller_id" => caller_id}} = item,
         _tool_name,
         state
       )
       when is_binary(caller_id) do
    call = %{
      call_id: Map.get(item, "call_id"),
      name: replay_tool_name(item),
      arguments: decode_arguments(Map.get(item, "arguments")),
      output: :missing
    }

    %{state | programs: append_program_call(state.programs, caller_id, call)}
  end

  defp rewrite_input_item(%{"type" => "function_call_output"} = item, _tool_name, state) do
    call_id = Map.get(item, "call_id")

    case answer_program_call(state.programs, call_id, Map.get(item, "output")) do
      {:answered, programs} -> %{state | programs: programs}
      :not_a_program_call -> %{state | items: state.items ++ [item]}
    end
  end

  defp rewrite_input_item(
         %{"type" => "function_call", "namespace" => namespace, "name" => name} = item,
         _tool_name,
         state
       )
       when is_binary(namespace) and is_binary(name) do
    provider_item =
      item
      |> Map.put("name", provider_tool_name(namespace, name))
      |> Map.delete("namespace")

    %{state | items: state.items ++ [provider_item]}
  end

  defp rewrite_input_item(item, _tool_name, state), do: %{state | items: state.items ++ [item]}

  defp replay_tool_name(%{"namespace" => namespace, "name" => name})
       when is_binary(namespace) and is_binary(name),
       do: provider_tool_name(namespace, name)

  defp replay_tool_name(item), do: Map.get(item, "name")

  defp normalize_loaded_tools(tools) do
    case expand_namespaces(tools) do
      {:ok, expanded} ->
        expanded
        |> Enum.filter(&deferrable_tool?/1)
        |> Enum.map(&Map.delete(&1, "defer_loading"))

      {:error, _reason} ->
        []
    end
  end

  defp mark_program_settled(programs, call_id) do
    case Map.get(programs, call_id) do
      nil -> programs
      group -> Map.put(programs, call_id, %{group | settled?: true})
    end
  end

  defp append_program_call(programs, caller_id, call) do
    case Map.get(programs, caller_id) do
      nil -> programs
      group -> Map.put(programs, caller_id, %{group | calls: group.calls ++ [call]})
    end
  end

  defp answer_program_call(programs, call_id, output) do
    match =
      Enum.find_value(programs, fn {program_id, group} ->
        index = Enum.find_index(group.calls, &(&1.call_id == call_id and &1.output == :missing))
        if index, do: {program_id, group, index}
      end)

    case match do
      nil ->
        :not_a_program_call

      {program_id, group, index} ->
        decoded = decode_program_output(output)
        calls = List.update_at(group.calls, index, &%{&1 | output: decoded})
        {:answered, Map.put(programs, program_id, %{group | calls: calls})}
    end
  end

  defp decode_program_output(output) when is_binary(output) do
    case Ankole.JSON.decode(output) do
      {:ok, decoded} -> decoded
      _invalid -> output
    end
  end

  defp decode_program_output(output), do: output

  defp resolve_pre_round(state, program) when is_map(state) do
    unsettled =
      state.order
      |> Enum.map(&{&1, Map.fetch!(state.programs, &1)})
      |> Enum.reject(fn {_call_id, group} -> group.settled? end)

    case unsettled do
      [] ->
        {:ok, nil}

      [{call_id, group}] ->
        cond do
          is_nil(program) ->
            {:error, {:invalid_program, :bindings_missing_for_resume}}

          Enum.any?(group.calls, &(&1.output == :missing)) ->
            {:error, {:invalid_program, {:program_calls_unanswered, call_id}}}

          true ->
            {:ok,
             %{
               call_id: call_id,
               code: group.code,
               fingerprint: group.fingerprint,
               memo:
                 Enum.map(group.calls, fn call ->
                   %{
                     "name" => call.name,
                     "arguments" => call.arguments,
                     "output" => call.output
                   }
                 end)
             }}
        end

      unsettled ->
        {:error,
         {:invalid_program, {:multiple_unsettled_programs, Enum.map(unsettled, &elem(&1, 0))}}}
    end
  end

  defp resolve_pre_round(nil, _program), do: {:ok, nil}

  # Server-mode history items carry call_id null. The provider still needs a
  # stable pairing key, so replay derives one from the item position-free
  # provider_call_id recorded at execution time.
  defp replay_call_id(%{"call_id" => call_id}) when is_binary(call_id) and call_id != "",
    do: call_id

  defp replay_call_id(%{"provider_call_id" => call_id}) when is_binary(call_id) and call_id != "",
    do: call_id

  defp replay_call_id(_item), do: "#{@server_call_id_prefix}replay"

  defp dedupe_loaded(loaded), do: Enum.uniq_by(loaded, & &1["name"])

  # ─────────────────────────────────────────────────────────────────
  # Synthesized search tool
  # ─────────────────────────────────────────────────────────────────

  defp synthesized_search_tool(tool_name, declaration, deferred, loaded_tools) do
    %{
      "type" => "function",
      "name" => tool_name,
      "description" => search_tool_description(declaration, deferred, loaded_tools),
      "parameters" => %{
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
    }
  end

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

    {lines, omitted} =
      deferred
      |> Enum.reject(&MapSet.member?(loaded_names, &1["name"]))
      |> Enum.uniq_by(&listing_identity/1)
      |> Enum.map(&listing_line/1)
      |> take_within_budget(@catalog_listing_budget_bytes)

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

  defp take_within_budget(lines, budget) do
    {kept, _bytes} =
      Enum.reduce(lines, {[], 0}, fn line, {kept, bytes} ->
        cost = byte_size(line) + 1

        if bytes + cost > budget do
          {kept, bytes}
        else
          {kept ++ [line], bytes + cost}
        end
      end)

    {kept, length(lines) - length(kept)}
  end

  defp truncate(text, max_bytes) do
    if byte_size(text) <= max_bytes do
      text
    else
      truncated =
        text
        |> String.graphemes()
        |> Enum.reduce_while({[], 0}, fn grapheme, {acc, bytes} ->
          cost = byte_size(grapheme)

          if bytes + cost > max_bytes,
            do: {:halt, {acc, bytes}},
            else: {:cont, {[grapheme | acc], bytes + cost}}
        end)
        |> elem(0)
        |> Enum.reverse()
        |> Enum.join()

      truncated <> "…"
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

  defp encode_arguments(arguments) when is_map(arguments), do: Ankole.JSON.encode!(arguments)
  defp encode_arguments(arguments) when is_binary(arguments), do: arguments
  defp encode_arguments(_arguments), do: "{}"

  @doc false
  @spec parse_search_arguments(map()) :: %{query: String.t(), limit: pos_integer()}
  def parse_search_arguments(%{} = item) do
    arguments = decode_arguments(Map.get(item, "arguments"))

    %{
      query: string_argument(arguments, "query"),
      limit: normalize_limit(Map.get(arguments, "limit"))
    }
  end

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

  defp provider_safe_tool(%{} = tool) do
    description =
      case Map.get(tool, "__ankole_namespace") do
        namespace when is_binary(namespace) ->
          path = "#{namespace}.#{tool["__ankole_public_name"]}"

          [Map.get(tool, "description"), "Namespace path: #{path}."]
          |> Enum.filter(&(is_binary(&1) and &1 != ""))
          |> Enum.join("\n")

        _root ->
          Map.get(tool, "description")
      end

    tool
    |> Map.delete("defer_loading")
    |> Map.delete("allowed_callers")
    |> Map.drop([
      "__ankole_namespace",
      "__ankole_public_name",
      "__ankole_namespace_description",
      "__ankole_search_text"
    ])
    |> maybe_put("description", description)
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

  defp loaded?(%Plan{loaded_names: loaded_names}, %{"name" => name}),
    do: MapSet.member?(loaded_names, name)

  defp maybe_put(map, _key, nil), do: map

  defp maybe_put(map, key, value) when is_binary(value) and value != "",
    do: Map.put(map, key, value)

  defp maybe_put(map, _key, _value), do: map

  defp put_input(request, input) when is_list(input), do: Map.put(request, "input", input)
  defp put_input(request, _input), do: request

  defp list_of_maps(value) when is_list(value), do: Enum.filter(value, &is_map/1)
  defp list_of_maps(_value), do: []
end
