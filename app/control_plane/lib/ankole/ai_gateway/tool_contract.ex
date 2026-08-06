defmodule Ankole.AIGateway.ToolContract do
  @moduledoc """
  Normalizes executable tools before Tool Search or program execution.

  A descriptor keeps the public tool identity separate from the provider alias.
  This prevents namespace flattening, deferred loading, and program execution
  from changing the tool contract between model rounds.
  """

  alias Ankole.AIGateway.CodexCodeMode

  @reserved_provider_names ["program", "tool_search"]
  @supported_callers ["direct", "programmatic"]
  @provider_name_pattern ~r/^[A-Za-z0-9_-]+$/

  defmodule Descriptor do
    @moduledoc """
    The immutable executable contract for one public tool.
    """

    @enforce_keys [
      :type,
      :name,
      :provider_name,
      :allowed_callers,
      :deferred?,
      :codec
    ]
    defstruct [
      :type,
      :name,
      :namespace,
      :namespace_description,
      :provider_name,
      :description,
      :parameters,
      :format,
      :output_schema,
      :strict,
      :search_text,
      :allowed_callers,
      :deferred?,
      :codec
    ]

    @type codec :: :json | :text

    @type t :: %__MODULE__{
            type: String.t(),
            name: String.t(),
            namespace: String.t() | nil,
            namespace_description: String.t() | nil,
            provider_name: String.t(),
            description: String.t() | nil,
            parameters: map() | nil,
            format: map() | nil,
            output_schema: map() | nil,
            strict: boolean() | nil,
            search_text: String.t() | nil,
            allowed_callers: [String.t()],
            deferred?: boolean(),
            codec: codec()
          }
  end

  @type error ::
          {:invalid_tool_contract, term()}
          | {:unsupported_tool_type, term()}

  @doc """
  Normalizes root tools, namespace containers, or already expanded tools.

  The returned list keeps the input order. Namespace children stay in their
  declared order. Use `executable_snapshot/1` when order-independent identity
  is required.
  """
  @spec normalize([map()], keyword()) :: {:ok, [Descriptor.t()]} | {:error, error()}
  def normalize(specs, opts \\ [])

  def normalize(specs, opts) when is_list(specs) and is_list(opts) do
    with {:ok, reserved_names} <- reserved_names(opts),
         {:ok, descriptors} <- normalize_specs(specs),
         :ok <- validate_descriptor_set(descriptors, reserved_names) do
      {:ok, descriptors}
    end
  end

  def normalize(_specs, _opts),
    do: {:error, {:invalid_tool_contract, :tools_must_be_a_list}}

  @doc """
  Validates one complete loaded-tool list.

  `:known` can contain the frozen request catalog and the tools that are already
  executable. A loaded tool can repeat a known public identity only when its
  public contract is equal. Private search text can be absent from the public
  replay item; in that case this function restores it from the frozen contract.
  One invalid item rejects the complete list.
  """
  @spec validate_loaded([map()], keyword()) ::
          {:ok, [Descriptor.t()]} | {:error, error()}
  def validate_loaded(specs, opts \\ [])

  def validate_loaded(specs, opts) when is_list(specs) and is_list(opts) do
    known = Keyword.get(opts, :known, [])

    with :ok <- validate_known(known),
         {:ok, loaded} <- normalize(specs, opts),
         {:ok, reserved_names} <- reserved_names(opts),
         :ok <- validate_descriptor_set(known, reserved_names),
         {:ok, reconciled} <- reconcile_loaded_against_known(loaded, known) do
      {:ok, reconciled}
    end
  end

  def validate_loaded(_specs, _opts),
    do: {:error, {:invalid_tool_contract, :loaded_tools_must_be_a_list}}

  @doc """
  Returns the deterministic provider name for one public tool path.
  """
  @spec provider_alias(String.t() | nil, String.t()) :: String.t()
  def provider_alias(namespace, name)
      when (is_nil(namespace) or is_binary(namespace)) and is_binary(name) and name != "" do
    combined = if namespace, do: "#{namespace}__#{name}", else: name

    if byte_size(combined) <= 64 and Regex.match?(@provider_name_pattern, combined) do
      combined
    else
      digest =
        :crypto.hash(:sha256, combined)
        |> Base.encode16(case: :lower)
        |> binary_part(0, 12)

      readable =
        sanitize_identifier_prefix(combined, 48, [])

      "#{readable}_#{digest}"
    end
  end

  @doc """
  Builds the plain provider tool represented by a descriptor.
  """
  @spec provider_spec(Descriptor.t()) :: map()
  def provider_spec(%Descriptor{} = descriptor) do
    %{"type" => descriptor.type, "name" => descriptor.provider_name}
    |> maybe_put("description", descriptor.description)
    |> maybe_put("parameters", descriptor.parameters)
    |> maybe_put("format", descriptor.format)
    |> maybe_put_provider_output_schema(descriptor)
    |> maybe_put("strict", descriptor.strict)
  end

  @doc """
  Builds the public leaf tool represented by a descriptor.

  Namespace identity remains in the `namespace` field. A caller that needs a
  namespace container can group these leaves without parsing provider names.
  """
  @spec public_spec(Descriptor.t()) :: map()
  def public_spec(%Descriptor{} = descriptor) do
    %{
      "type" => descriptor.type,
      "name" => descriptor.name,
      "allowed_callers" => descriptor.allowed_callers
    }
    |> maybe_put("namespace", descriptor.namespace)
    |> maybe_put("namespace_description", descriptor.namespace_description)
    |> maybe_put("description", descriptor.description)
    |> maybe_put("parameters", descriptor.parameters)
    |> maybe_put("format", descriptor.format)
    |> maybe_put("output_schema", descriptor.output_schema)
    |> maybe_put("strict", descriptor.strict)
    |> maybe_put("__ankole_search_text", descriptor.search_text)
    |> maybe_put_true("defer_loading", descriptor.deferred?)
  end

  @doc """
  Returns an order-independent snapshot of executable tool semantics.
  """
  @spec executable_snapshot([Descriptor.t()]) :: [map()]
  def executable_snapshot(descriptors) when is_list(descriptors) do
    descriptors
    |> Enum.map(&descriptor_snapshot/1)
    |> Enum.sort_by(fn snapshot ->
      {
        snapshot["provider_name"],
        snapshot["type"],
        snapshot["public"]["namespace"] || "",
        snapshot["public"]["name"]
      }
    end)
  end

  @doc """
  Returns a canonical SHA-256 fingerprint of executable tool semantics.
  """
  @spec fingerprint([Descriptor.t()]) :: String.t()
  def fingerprint(descriptors) when is_list(descriptors) do
    descriptors
    |> executable_snapshot()
    |> canonical_term()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Decodes one tool result for program replay.

  Undeclared outputs remain byte-for-byte text. A declared `output_schema`
  opts into JSON decoding. The schema remains an opaque upstream contract:
  MCP or another tool owner validates it, while replay only needs the decoded
  JSON value and the frozen schema fingerprint.
  """
  @spec decode_output(Descriptor.t(), term()) :: {:ok, term()} | {:error, term()}
  def decode_output(%Descriptor{output_schema: nil}, output), do: {:ok, output}

  def decode_output(%Descriptor{output_schema: %{}, provider_name: name}, output),
    do: decode_declared_json(output, name)

  defp normalize_specs(specs) do
    specs
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, reversed} ->
      case normalize_spec(spec) do
        {:ok, normalized} -> {:cont, {:ok, Enum.reverse(normalized, reversed)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_normalized()
  end

  defp normalize_spec(%{"type" => "namespace"} = namespace) do
    with {:ok, name} <- required_name(namespace, :namespace),
         {:ok, tools} <- required_tool_list(namespace, name),
         {:ok, description} <- optional_binary(namespace, "description", name),
         {:ok, deferred?} <- deferred(namespace, false, name) do
      normalize_namespace_children(tools, name, description, deferred?)
    end
  end

  defp normalize_spec(%{} = spec) do
    case {Map.get(spec, "__ankole_namespace"), Map.get(spec, "__ankole_public_name")} do
      {nil, nil} ->
        with {:ok, descriptor} <- normalize_leaf(spec, nil, nil, false, false) do
          {:ok, [descriptor]}
        end

      {namespace, public_name}
      when is_binary(namespace) and namespace != "" and is_binary(public_name) and
             public_name != "" ->
        with {:ok, descriptor} <-
               normalize_leaf(spec, namespace, nil, false, true, public_name) do
          {:ok, [descriptor]}
        end

      _incomplete_expanded_identity ->
        {:error, {:invalid_tool_contract, :invalid_expanded_identity}}
    end
  end

  defp normalize_spec(other),
    do: {:error, {:invalid_tool_contract, {:tool_must_be_an_object, other}}}

  defp normalize_namespace_children(tools, namespace, description, inherited_deferred?) do
    tools
    |> Enum.reduce_while({:ok, []}, fn
      %{"type" => "namespace"}, _acc ->
        {:halt, {:error, {:invalid_tool_contract, {:nested_namespace_unsupported, namespace}}}}

      %{} = child, {:ok, reversed} ->
        case normalize_leaf(
               child,
               namespace,
               description,
               inherited_deferred?,
               false
             ) do
          {:ok, descriptor} -> {:cont, {:ok, [descriptor | reversed]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      child, _acc ->
        {:halt,
         {:error,
          {:invalid_tool_contract, {:namespace_child_must_be_an_object, namespace, child}}}}
    end)
    |> reverse_normalized()
  end

  defp reverse_normalized({:ok, reversed}), do: {:ok, Enum.reverse(reversed)}
  defp reverse_normalized({:error, _reason} = error), do: error

  defp normalize_leaf(
         spec,
         namespace,
         namespace_description,
         inherited_deferred?,
         expanded?,
         public_name \\ nil
       ) do
    with {:ok, type} <- supported_type(spec),
         {:ok, name} <- public_name(spec, public_name),
         {:ok, description} <- tool_description(spec, public_path(namespace, name)),
         {:ok, parameters} <- input_parameters(spec, type, namespace, name),
         {:ok, format} <- input_format(spec, type, namespace, name),
         {:ok, output_schema} <-
           output_schema(spec, public_path(namespace, name)),
         {:ok, strict} <- optional_boolean(spec, "strict", public_path(namespace, name)),
         {:ok, search_text} <-
           optional_binary(spec, "__ankole_search_text", public_path(namespace, name)),
         {:ok, callers} <- allowed_callers(spec, namespace, name),
         {:ok, deferred?} <-
           deferred(spec, inherited_deferred?, public_path(namespace, name)),
         provider_name = provider_alias(namespace, name),
         :ok <- validate_expanded_alias(spec, expanded?, provider_name, namespace, name) do
      {:ok,
       %Descriptor{
         type: type,
         name: name,
         namespace: namespace,
         namespace_description:
           namespace_description || Map.get(spec, "__ankole_namespace_description"),
         provider_name: provider_name,
         description: description,
         parameters: parameters,
         format: format,
         output_schema: output_schema,
         strict: strict,
         search_text: search_text,
         allowed_callers: callers,
         deferred?: deferred?,
         codec: codec(type)
       }}
    end
  end

  defp supported_type(%{"type" => type}) when type in ["function", "custom"], do: {:ok, type}

  defp supported_type(%{"type" => type}) when is_binary(type),
    do: {:error, {:unsupported_tool_type, type}}

  defp supported_type(_spec),
    do: {:error, {:invalid_tool_contract, :missing_tool_type}}

  defp required_name(%{"name" => name}, _kind) when is_binary(name) and name != "",
    do: {:ok, name}

  defp required_name(spec, kind),
    do: {:error, {:invalid_tool_contract, {:invalid_name, kind, Map.get(spec, "name")}}}

  defp public_name(_spec, name) when is_binary(name) and name != "", do: {:ok, name}
  defp public_name(spec, nil), do: required_name(spec, :tool)

  defp required_tool_list(%{"tools" => tools}, _name) when is_list(tools), do: {:ok, tools}

  defp required_tool_list(namespace, name),
    do:
      {:error,
       {:invalid_tool_contract,
        {:namespace_tools_must_be_a_list, name, Map.get(namespace, "tools")}}}

  defp input_parameters(spec, "function", namespace, name) do
    case Map.get(spec, "format") do
      nil ->
        optional_map(spec, "parameters", public_path(namespace, name))

      value ->
        {:error,
         {:invalid_tool_contract,
          {:function_format_unsupported, public_path(namespace, name), value}}}
    end
  end

  defp input_parameters(spec, "custom", namespace, name) do
    case Map.get(spec, "parameters") do
      nil ->
        {:ok, nil}

      value ->
        {:error,
         {:invalid_tool_contract,
          {:custom_parameters_unsupported, public_path(namespace, name), value}}}
    end
  end

  defp input_format(_spec, "function", _namespace, _name), do: {:ok, nil}

  defp input_format(spec, "custom", namespace, name),
    do: optional_map(spec, "format", public_path(namespace, name))

  defp allowed_callers(spec, namespace, name) do
    case Map.fetch(spec, "allowed_callers") do
      :error ->
        {:ok, ["direct"]}

      {:ok, nil} ->
        {:ok, ["direct"]}

      {:ok, callers} when is_list(callers) ->
        cond do
          callers == [] ->
            invalid_callers(namespace, name, callers)

          Enum.any?(callers, &(not is_binary(&1) or &1 not in @supported_callers)) ->
            invalid_callers(namespace, name, callers)

          length(Enum.uniq(callers)) != length(callers) ->
            invalid_callers(namespace, name, callers)

          true ->
            {:ok,
             Enum.sort_by(
               callers,
               &Enum.find_index(@supported_callers, fn value -> value == &1 end)
             )}
        end

      {:ok, callers} ->
        invalid_callers(namespace, name, callers)
    end
  end

  defp invalid_callers(namespace, name, callers) do
    {:error,
     {:invalid_tool_contract, {:invalid_allowed_callers, public_path(namespace, name), callers}}}
  end

  defp deferred(spec, inherited, identity) do
    case Map.fetch(spec, "defer_loading") do
      :error ->
        {:ok, inherited}

      {:ok, value} when is_boolean(value) ->
        {:ok, value}

      {:ok, value} ->
        {:error, {:invalid_tool_contract, {:invalid_defer_loading, identity, value}}}
    end
  end

  defp optional_map(spec, key, identity) do
    case Map.get(spec, key) do
      nil -> {:ok, nil}
      value when is_map(value) -> {:ok, value}
      value -> {:error, {:invalid_tool_contract, {:invalid_map_field, identity, key, value}}}
    end
  end

  defp output_schema(spec, identity),
    do: optional_map(spec, "output_schema", identity)

  # A client that loads its own deferred tools sends their descriptions back in
  # the Tool Search output. They carry the Codex code-mode block that the request
  # declaration no longer has, so both sides need the same rule before a loaded
  # tool can match its known contract.
  defp tool_description(spec, identity) do
    with {:ok, description} <- optional_binary(spec, "description", identity) do
      {:ok, CodexCodeMode.plain_description(description)}
    end
  end

  defp optional_binary(spec, key, identity) do
    case Map.get(spec, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      value -> {:error, {:invalid_tool_contract, {:invalid_string_field, identity, key, value}}}
    end
  end

  defp optional_boolean(spec, key, identity) do
    case Map.get(spec, key) do
      nil -> {:ok, nil}
      value when is_boolean(value) -> {:ok, value}
      value -> {:error, {:invalid_tool_contract, {:invalid_boolean_field, identity, key, value}}}
    end
  end

  defp validate_expanded_alias(_spec, false, _provider_name, _namespace, _name), do: :ok

  defp validate_expanded_alias(spec, true, provider_name, namespace, name) do
    case Map.get(spec, "name") do
      ^provider_name ->
        :ok

      supplied ->
        {:error,
         {:invalid_tool_contract,
          {:expanded_provider_alias_mismatch, public_path(namespace, name), supplied,
           provider_name}}}
    end
  end

  defp validate_descriptor_set(descriptors, reserved_names) do
    with :ok <- ensure_unique_public_identity(descriptors),
         :ok <- ensure_unique_provider_alias(descriptors),
         :ok <- ensure_not_reserved(descriptors, reserved_names) do
      :ok
    end
  end

  defp ensure_unique_public_identity(descriptors) do
    case duplicate_group(descriptors, &public_key/1) do
      nil -> :ok
      {key, _descriptors} -> {:error, {:invalid_tool_contract, {:duplicate_public_tool, key}}}
    end
  end

  defp ensure_unique_provider_alias(descriptors) do
    case duplicate_group(descriptors, & &1.provider_name) do
      nil ->
        :ok

      {provider_name, colliding} ->
        identities = Enum.map(colliding, &public_key/1)

        {:error, {:invalid_tool_contract, {:provider_alias_collision, provider_name, identities}}}
    end
  end

  defp ensure_not_reserved(descriptors, reserved_names) do
    case Enum.find(descriptors, &(&1.provider_name in reserved_names)) do
      nil ->
        :ok

      descriptor ->
        {:error,
         {:invalid_tool_contract,
          {:reserved_provider_name, descriptor.provider_name, public_key(descriptor)}}}
    end
  end

  defp duplicate_group(descriptors, key_fun) do
    descriptors
    |> Enum.group_by(key_fun)
    |> Enum.find(fn {_key, values} -> length(values) > 1 end)
  end

  defp validate_known(known) when is_list(known) do
    if Enum.all?(known, &match?(%Descriptor{}, &1)) do
      :ok
    else
      {:error, {:invalid_tool_contract, :known_tools_must_be_descriptors}}
    end
  end

  defp validate_known(_known),
    do: {:error, {:invalid_tool_contract, :known_tools_must_be_descriptors}}

  defp reconcile_loaded_against_known(loaded, known) do
    known_by_public = Map.new(known, &{public_key(&1), &1})
    known_by_provider = Map.new(known, &{&1.provider_name, &1})

    loaded
    |> Enum.reduce_while({:ok, []}, fn descriptor, {:ok, reversed} ->
      public_match = Map.get(known_by_public, public_key(descriptor))
      provider_match = Map.get(known_by_provider, descriptor.provider_name)

      cond do
        public_match && not compatible_loaded_projection?(descriptor, public_match) ->
          {:halt,
           {:error, {:invalid_tool_contract, {:loaded_tool_mismatch, public_key(descriptor)}}}}

        provider_match && public_key(provider_match) != public_key(descriptor) ->
          {:halt,
           {:error,
            {:invalid_tool_contract,
             {:provider_alias_collision, descriptor.provider_name,
              [public_key(provider_match), public_key(descriptor)]}}}}

        public_match ->
          {:cont, {:ok, [public_match | reversed]}}

        true ->
          {:cont, {:ok, [descriptor | reversed]}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  defp compatible_loaded_projection?(descriptor, known) do
    descriptor == known or
      (is_nil(descriptor.search_text) and
         projection_snapshot(descriptor) == projection_snapshot(known))
  end

  defp projection_snapshot(descriptor) do
    descriptor
    |> descriptor_snapshot()
    |> Map.delete("search_text")
  end

  defp reserved_names(opts) do
    names = Keyword.get(opts, :reserved_names, @reserved_provider_names)

    if is_list(names) and Enum.all?(names, &(is_binary(&1) and &1 != "")) do
      {:ok, Enum.uniq(names)}
    else
      {:error, {:invalid_tool_contract, {:invalid_reserved_names, names}}}
    end
  end

  defp descriptor_snapshot(%Descriptor{} = descriptor) do
    %{
      "type" => descriptor.type,
      "public" => %{
        "namespace" => descriptor.namespace,
        "name" => descriptor.name
      },
      "provider_name" => descriptor.provider_name,
      "namespace_description" => descriptor.namespace_description,
      "description" => descriptor.description,
      "parameters" => descriptor.parameters,
      "format" => descriptor.format,
      "output_schema" => descriptor.output_schema,
      "strict" => descriptor.strict,
      "search_text" => descriptor.search_text,
      "allowed_callers" => descriptor.allowed_callers,
      "defer_loading" => descriptor.deferred?,
      "codec" => Atom.to_string(descriptor.codec)
    }
  end

  defp public_key(%Descriptor{namespace: nil, name: name}), do: name
  defp public_key(%Descriptor{namespace: namespace, name: name}), do: "#{namespace}.#{name}"

  defp public_path(nil, name), do: name
  defp public_path(namespace, name), do: "#{namespace}.#{name}"

  defp codec("function"), do: :json
  defp codec("custom"), do: :text

  defp canonical_term(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {canonical_term(key), canonical_term(value)} end)
    |> Enum.sort_by(fn {key, _value} -> :erlang.term_to_binary(key) end)
  end

  defp canonical_term(list) when is_list(list), do: Enum.map(list, &canonical_term/1)
  defp canonical_term(value), do: value

  defp decode_declared_json(output, _name) when not is_binary(output), do: {:ok, output}

  defp decode_declared_json(output, name) do
    case Ankole.JSON.decode(output) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_tool_output_json, name, reason}}
    end
  end

  defp sanitize_identifier_prefix(_value, 0, acc),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp sanitize_identifier_prefix(<<>>, _remaining, acc),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp sanitize_identifier_prefix(<<byte, rest::binary>>, remaining, acc) do
    sanitized =
      if byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in [?_, ?-],
        do: byte,
        else: ?_

    sanitize_identifier_prefix(rest, remaining - 1, [sanitized | acc])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # OpenAI function tools can declare `output_schema` for PTC. Custom tools
  # cannot. Keep the schema in the frozen local descriptor so program replay
  # can decode and validate the result, but do not send it on the provider's
  # custom-tool declaration.
  defp maybe_put_provider_output_schema(map, %Descriptor{type: "function"} = descriptor),
    do: maybe_put(map, "output_schema", descriptor.output_schema)

  defp maybe_put_provider_output_schema(map, %Descriptor{}), do: map

  defp maybe_put_true(map, key, true), do: Map.put(map, key, true)
  defp maybe_put_true(map, _key, false), do: map
end
