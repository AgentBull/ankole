defmodule Ankole.Credo.PersistenceBoundary do
  @moduledoc """
  Finds persistence boundary crossings in a source file.

  `Ankole.Credo.AshBoundary`, `Ankole.Credo.RawSQLTenant`, and
  `Ankole.PersistenceBoundaryTest` use these occurrences and the same data
  file: `test/ankole/persistence_boundary.exs`. That file lists the registered
  exception modules. A private checkout adds its exceptions in
  `internals/control_plane/test/persistence_boundary.exs`.

  Each occurrence gives its kind, module, function, line, and the module that
  its first argument names (or `nil`). The kinds are:

    * `:bulk_result`, `:error_class`, `:ash_error_match` - bulk-result decoding,
      error-class construction, and a pattern or guard that names an
      `Ash.Error` module outside `Ankole.Ash`, `Ankole.Errors`, and
      `AnkoleWeb.ConsoleErrors`.
    * `:ash_direct`, `:ash_bulk`, `:transaction_hook` - a direct `Ash.*`
      execution or `Ash.bulk_*` call, and an `Ash.Changeset` transaction hook
      outside those owners. `Ankole.Ash` runs actions in the tenant context, and
      top-level operations own transaction effects.
    * `:ecto_write`, `:ecto_lock`, `:repo_transact` - an Ecto write, an Ecto row
      lock, or a `Repo` transaction outside the registered exception modules.
      A `lock:` keyword is an Ecto lock only in an Ecto `from` query; in a
      code interface `query:` keyword it is an Ash lock.
    * `:consumer_ash` - an Ash call in `ankole_web`, a plugin, or the control
      plane application. `Ash.PlugHelpers` only puts request values on a
      connection, so it is not an Ash call.
    * `:raw_sql_tenant` - raw SQL that reads or changes a table without a
      `tenant_id` predicate, in a module without `@raw_sql_scope :site`.
    * `:ecto_source` and `:ash_call` - candidates that the boundary test
      classifies with the compiled resources: `ecto_resource` is an Ecto query
      of an Ash resource, and `cross_domain_ash` is an Ash call on a resource of
      another domain directory.
    * `:persistence` - any database call; only the stale-exception check uses it.
  """

  @data Path.expand("../test/ankole/persistence_boundary.exs", __DIR__)
  # A private checkout keeps the counts of its own files beside its sources.
  @private_data Path.expand(
                  "../../../internals/control_plane/test/persistence_boundary.exs",
                  __DIR__
                )
  @owners ["/lib/ankole/ash.ex", "/lib/ankole/errors.ex", "/lib/ankole_web/console_errors.ex"]
  @owner_dirs ["/lib/ankole/ash/", "/lib/ankole/errors/"]
  @consumer_paths ["/lib/ankole_web/", "../../plugins/", "../../internals/plugins/"]
  @repo_reads [
    :all,
    :one,
    :one!,
    :get,
    :get!,
    :get_by,
    :get_by!,
    :exists?,
    :aggregate,
    :stream,
    :preload,
    :reload,
    :reload!,
    :lock_all
  ]
  @repo_writes [
    :insert,
    :insert!,
    :update,
    :update!,
    :delete,
    :delete!,
    :insert_all,
    :update_all,
    :delete_all,
    :insert_or_update,
    :insert_or_update!
  ]
  @raw_sql [:query, :query!, :query_many, :query_many!]
  @repo_calls @repo_reads ++ @raw_sql
  @sql_modules [Ecto.Adapters.SQL, Postgrex]
  @table_reference ~r/\b(FROM|JOIN|INTO|UPDATE|TABLE|INDEX)\b/i
  @exemptible [:ecto_write, :ecto_lock, :repo_transact, :ecto_source, :consumer_ash, :ash_call]
  @direct_actions [
    :read,
    :read!,
    :read_one,
    :read_one!,
    :count,
    :count!,
    :exists,
    :exists?,
    :first,
    :first!,
    :aggregate,
    :aggregate!,
    :max,
    :max!,
    :min,
    :min!,
    :sum,
    :sum!,
    :create,
    :create!,
    :update,
    :update!,
    :destroy,
    :destroy!,
    :run_action,
    :run_action!,
    :load,
    :load!
  ]
  @bulk_actions [:bulk_create, :bulk_update, :bulk_destroy]
  @transaction_hooks [:before_transaction, :after_transaction, :around_transaction]
  @enforced [
    :bulk_result,
    :error_class,
    :ash_error_match,
    :ash_direct,
    :ash_bulk,
    :transaction_hook,
    :ecto_write,
    :ecto_lock,
    :repo_transact,
    :consumer_ash,
    :raw_sql_tenant
  ]

  @doc "Reads the registered exceptions."
  def data do
    exceptions =
      [@data, @private_data]
      |> Enum.filter(&File.exists?/1)
      |> Enum.map(&(&1 |> Code.eval_file() |> elem(0) |> Map.fetch!(:exceptions)))
      |> Enum.reduce(&Map.merge(&2, &1))

    %{exceptions: exceptions}
  end

  @doc """
  Gives the occurrences of the given kinds in a source file that no registered
  exception covers.

  Credo checks call this function once for each file, so the data stays in a
  persistent term until the data file changes.
  """
  def crossings(ast, filename, kinds) do
    %{exceptions: exceptions} = cached_data()
    path = Path.relative_to(Path.expand(filename), File.cwd!(), force: true)

    ast
    |> occurrences(path)
    |> Enum.filter(&(&1.kind in kinds and not exempt?(&1, exceptions)))
    |> Enum.sort_by(& &1.line)
  end

  defp cached_data do
    version = for path <- [@data, @private_data], File.exists?(path), do: File.stat!(path).mtime

    case :persistent_term.get(__MODULE__, nil) do
      {^version, data} ->
        data

      _stale ->
        data = data()
        :persistent_term.put(__MODULE__, {version, data})
        data
    end
  end

  @doc "Gives the kinds that Credo enforces."
  def enforced_kinds, do: @enforced

  @doc "Gives the report key of an occurrence kind in a file."
  def key(kind, path), do: "#{kind}:#{path}"

  @doc """
  Tells whether a registered exception covers an occurrence.

  An exception covers the Ecto writes, locks, transactions, resource queries,
  and direct Ash calls of its module or functions. Its raw SQL keeps the
  tenant rule, and framework errors stay at their owners.
  """
  def exempt?(%{kind: kind, module: module, function: function}, exceptions) do
    kind in @exemptible and exempt_module?(module, function, exceptions)
  end

  defp exempt_module?(module, function, exceptions) do
    Enum.any?(Map.keys(exceptions), fn
      ^module -> true
      {^module, functions} -> function in functions
      _other -> false
    end)
  end

  @doc "Gives the occurrences in a parsed source file."
  def occurrences(ast, path) do
    context = %{
      path: path,
      line: nil,
      module: nil,
      function: nil,
      aliases: %{},
      site_sql?: false,
      ecto_query?: false,
      owner?: owner?(path),
      consumer?: consumer?(path)
    }

    ast
    |> walk(context, [])
    |> elem(1)
    |> Enum.reverse()
  end

  defp owner?(path),
    do: Enum.any?(@owners, &String.ends_with?(path, &1)) or Enum.any?(@owner_dirs, &(path =~ &1))

  defp consumer?(path),
    do:
      Enum.any?(@consumer_paths, &String.contains?(path, &1)) or
        String.starts_with?(path, "lib/")

  # The walk keeps the lexical module, function, and aliases of each node.
  defp walk({:defmodule, _meta, [name, [do: body]]}, context, acc) do
    module = module_name(name, context)
    aliases = Map.put(context.aliases, last_alias(name), module)

    module_context = %{
      context
      | module: module,
        function: nil,
        aliases: aliases,
        site_sql?: site_sql?(body)
    }

    {_ast, acc} = walk(body, module_context, acc)
    {nil, acc}
  end

  defp walk({definition, _meta, [head | rest]}, context, acc)
       when definition in [:def, :defp, :defmacro, :defmacrop] do
    context = %{context | function: function_name(head)}
    {_ast, acc} = walk(head_patterns(head), context, acc)
    walk(rest, context, acc)
  end

  defp walk({:__block__, _meta, expressions}, context, acc) do
    {_context, acc} =
      Enum.reduce(expressions, {context, acc}, fn expression, {context, acc} ->
        context = put_alias(expression, context)
        {_ast, acc} = walk(expression, context, acc)
        {context, acc}
      end)

    {nil, acc}
  end

  defp walk({:alias, _meta, _args}, _context, acc), do: {nil, acc}

  defp walk({:|>, meta, [left, {call, call_meta, args}]} = node, context, acc)
       when is_list(args) do
    context = at_line(context, meta)
    meta = if Keyword.has_key?(call_meta, :line), do: call_meta, else: meta
    acc = classify({call, meta, [left | args]}, context, acc)
    acc = classify_node(node, context, acc)
    {_ast, acc} = walk(left, context, acc)
    walk(args, context, acc)
  end

  defp walk({form, meta, args} = node, context, acc) when is_list(args) do
    context = at_line(context, meta)
    acc = classify_node(node, context, acc)
    acc = classify({form, meta, args}, context, acc)
    {_ast, acc} = if call_target?(form), do: {nil, acc}, else: walk(form, context, acc)
    walk(args, ecto_query(form, context), acc)
  end

  defp walk({left, right}, context, acc) do
    acc = classify_node({left, right}, context, acc)
    {_ast, acc} = walk(left, context, acc)
    walk(right, context, acc)
  end

  defp walk(list, context, acc) when is_list(list) do
    acc = Enum.reduce(list, acc, &(walk(&1, context, &2) |> elem(1)))
    {nil, acc}
  end

  defp walk(_node, _context, acc), do: {nil, acc}

  # Nodes that are not calls: struct patterns, keyword lock options, and `in` sources.
  defp classify_node({:%, meta, [name, _fields]}, context, acc),
    do:
      add(
        acc,
        :bulk_result,
        meta,
        context,
        nil,
        resolve(name, context) == Ash.BulkResult and not context.owner?
      )

  # A struct pattern or a guard list that names an Ash error module. A call
  # such as `Ash.Error.Changes.InvalidAttribute.exception/1` is not a match.
  defp classify_node({:__aliases__, meta, _parts} = name, context, acc),
    do:
      add(
        acc,
        :ash_error_match,
        meta,
        context,
        nil,
        ash_error?(resolve(name, context)) and not context.owner?
      )

  defp classify_node({:lock, value}, context, acc) when is_binary(value),
    do: add(acc, :ecto_lock, [], context, nil, context.ecto_query? and lock_clause?(value))

  defp classify_node({:in, meta, [_left, right]}, context, acc) do
    case resolve(right, context) do
      module when is_atom(module) and not is_nil(module) ->
        acc
        |> add(:ecto_source, meta, context, module, true)
        |> add(:persistence, meta, context, nil, true)

      _other ->
        acc
    end
  end

  defp classify_node(_node, _context, acc), do: acc

  defp classify({{:., _dot, [target, function]}, meta, args}, context, acc) do
    module = resolve(target, context)
    first = args |> List.first() |> resolve(context)

    cond do
      repo?(target, module) ->
        repo_call(acc, function, args, meta, context, first)

      module in @sql_modules and function in [:query, :query!, :stream] ->
        raw_call(acc, Enum.at(args, 1), meta, context)

      module == Ecto.Query and function == :from ->
        add(acc, :ecto_source, meta, context, first, module?(first))

      module == Ecto.Query and function == :lock ->
        add(acc, :ecto_lock, meta, context, nil, lock_argument?(args))

      true ->
        ash_call(acc, module, function, meta, context, first)
    end
  end

  defp classify({:from, meta, [source | _rest]}, context, acc) do
    case resolve(source, context) do
      module when is_atom(module) and not is_nil(module) ->
        add(acc, :ecto_source, meta, context, module, true)

      _other ->
        acc
    end
  end

  defp classify({:lock, meta, args}, context, acc) when is_list(args),
    do: add(acc, :ecto_lock, meta, context, nil, lock_argument?(args))

  defp classify({function, meta, args}, %{module: Ankole.Repo} = context, acc)
       when is_atom(function) and is_list(args) and function in @repo_calls,
       do: add(acc, :persistence, meta, context, nil, true)

  defp classify(_call, _context, acc), do: acc

  defp repo_call(acc, function, args, meta, context, first) do
    source? = module?(first)

    cond do
      function in @repo_reads ->
        acc
        |> add(:persistence, meta, context, nil, true)
        |> add(:ecto_source, meta, context, first, source?)

      function in @repo_writes ->
        acc
        |> add(:persistence, meta, context, nil, true)
        |> add(:ecto_write, meta, context, nil, true)
        |> add(
          :ecto_source,
          meta,
          context,
          first,
          source? and function in [:update_all, :delete_all, :insert_all]
        )

      function == :transact_top_level ->
        acc
        |> add(:persistence, meta, context, nil, true)
        |> add(:repo_transact, meta, context, nil, context.consumer?)

      function in [:transact, :transaction] ->
        acc
        |> add(:persistence, meta, context, nil, true)
        |> add(:repo_transact, meta, context, nil, true)

      function in @raw_sql ->
        raw_call(acc, List.first(args), meta, context)

      true ->
        acc
    end
  end

  defp raw_call(acc, sql, meta, context) do
    acc
    |> add(:persistence, meta, context, nil, true)
    |> add(:raw_sql_tenant, meta, context, nil, not context.site_sql? and not tenant_sql?(sql))
  end

  defp ash_call(acc, module, function, meta, context, first) do
    if ash_module?(module) do
      acc
      |> add(:consumer_ash, meta, context, nil, context.consumer? and not context.owner?)
      |> add(:error_class, meta, context, nil, function == :to_error_class and not context.owner?)
      |> add(
        :ash_direct,
        meta,
        context,
        nil,
        module == Ash and function in @direct_actions and not context.owner?
      )
      |> add(
        :ash_bulk,
        meta,
        context,
        nil,
        module == Ash and function in @bulk_actions and not context.owner?
      )
      |> add(
        :transaction_hook,
        meta,
        context,
        nil,
        module == Ash.Changeset and function in @transaction_hooks and not context.owner?
      )
      |> add(:ash_call, meta, context, first, not context.consumer? and module?(first))
    else
      acc
    end
  end

  defp at_line(context, meta), do: %{context | line: Keyword.get(meta, :line, context.line)}

  # The arguments of an Ecto `from` query, where a `lock:` keyword is an Ecto lock.
  defp ecto_query(:from, context), do: %{context | ecto_query?: true}

  defp ecto_query({:., _meta, [target, :from]}, context),
    do: %{context | ecto_query?: context.ecto_query? or resolve(target, context) == Ecto.Query}

  defp ecto_query(_form, context), do: context

  defp add(acc, _kind, _meta, _context, _target, false), do: acc

  defp add(acc, kind, meta, context, target, true) do
    [
      %{
        kind: kind,
        module: context.module,
        function: context.function,
        line: Keyword.get(meta, :line, context.line),
        target: target
      }
      | acc
    ]
  end

  defp module?(module), do: is_atom(module) and not is_nil(module)

  # The module of a remote call is not a pattern; a call result as a target is walked.
  defp call_target?({:., _meta, [{:__aliases__, _, _}, function]}) when is_atom(function),
    do: true

  defp call_target?(form), do: not is_tuple(form)

  defp repo?({:repo, _meta, context}, _module) when is_atom(context), do: true
  defp repo?(_target, module), do: module == Ankole.Repo

  defp ash_module?(module) when is_atom(module) and not is_nil(module) do
    case Module.split(module) do
      ["Ash", "PlugHelpers"] -> false
      ["Ash" | _rest] -> true
      ["Ankole", "Ash" | _rest] -> true
      _other -> false
    end
  rescue
    ArgumentError -> false
  end

  defp ash_module?(_module), do: false

  defp ash_error?(module) when is_atom(module) and not is_nil(module),
    do: match?(["Ash", "Error" | _rest], Module.split(module))

  defp ash_error?(_module), do: false

  defp lock_argument?(args), do: Enum.any?(args, &(is_binary(&1) and lock_clause?(&1)))
  defp lock_clause?(value), do: String.starts_with?(String.upcase(value), "FOR ")

  # SQL without a table reference (clock, sequence, advisory lock) needs no tenant.
  defp tenant_sql?(sql) when is_binary(sql),
    do: String.contains?(sql, "tenant_id") or not Regex.match?(@table_reference, sql)

  defp tenant_sql?({:<<>>, _meta, parts}),
    do: parts |> Enum.filter(&is_binary/1) |> Enum.join(" ") |> tenant_sql?()

  defp tenant_sql?(_dynamic), do: false

  defp site_sql?(body) do
    {_ast, found} =
      Macro.prewalk(body, false, fn
        {:@, _, [{:raw_sql_scope, _, [:site]}]} = node, _found -> {node, true}
        node, found -> {node, found}
      end)

    found
  end

  defp put_alias({:alias, _meta, [target]}, context), do: put_aliases(target, nil, context)

  defp put_alias({:alias, _meta, [target, options]}, context),
    do: put_aliases(target, Keyword.get(options, :as), context)

  defp put_alias(_expression, context), do: context

  defp put_aliases({{:., _, [base, :{}]}, _, children}, nil, context) do
    base = resolve(base, context)

    Enum.reduce(children, context, fn {:__aliases__, _, parts}, context ->
      module = Module.concat([base | parts])
      %{context | aliases: Map.put(context.aliases, List.last(parts), module)}
    end)
  end

  defp put_aliases(target, as, context) do
    case resolve(target, context) do
      module when is_atom(module) and not is_nil(module) ->
        name =
          if as,
            do: last_alias(as),
            else: module |> Module.split() |> List.last() |> String.to_atom()

        %{context | aliases: Map.put(context.aliases, name, module)}

      _other ->
        context
    end
  end

  defp resolve({:__aliases__, _meta, [{:__MODULE__, _, _} | rest]}, context),
    do: context.module && Module.concat([context.module | rest])

  defp resolve({:__aliases__, _meta, [first | rest]}, context) when is_atom(first) do
    case Map.fetch(context.aliases, first) do
      {:ok, module} -> Module.concat([module | rest])
      :error -> Module.concat([first | rest])
    end
  end

  defp resolve({:__MODULE__, _meta, _context}, context), do: context.module
  defp resolve(_node, _context), do: nil

  defp module_name(name, %{module: nil} = context), do: resolve(name, context)

  defp module_name({:__aliases__, _meta, parts}, %{module: parent}),
    do: Module.concat([parent | parts])

  defp module_name(name, context), do: resolve(name, context)

  defp last_alias({:__aliases__, _meta, parts}), do: List.last(parts)
  defp last_alias(_name), do: nil

  # The argument patterns and guards of a function head, without the head call.
  defp head_patterns({:when, _meta, [head | guards]}), do: [head_patterns(head) | guards]
  defp head_patterns({_name, _meta, args}) when is_list(args), do: args
  defp head_patterns(_head), do: []

  defp function_name({:when, _, [head | _]}), do: function_name(head)
  defp function_name({name, _, _args}) when is_atom(name), do: name
  defp function_name(_head), do: nil
end
