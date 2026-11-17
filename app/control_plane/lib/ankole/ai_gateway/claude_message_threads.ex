defmodule Ankole.AIGateway.ClaudeMessageThreads do
  @moduledoc """
  Coordinates Anthropic Claude Message Threads (`message-threads-2026-08-12`)
  across streaming and non-streaming AIGateway requests.
  """

  use GenServer

  alias Ankole.AIGateway.ContinuationScope
  alias Ankole.AIGateway.ProviderFailure
  alias Ankole.Attrs

  @beta_flag "message-threads-2026-08-12"
  @anchors_table :ankole_ai_gateway_claude_threads
  @negative_table :ankole_ai_gateway_claude_threads_unsupported
  @anchor_ttl_ms 5 * 60_000
  @negative_ttl_ms 60 * 60_000
  @sweep_interval_ms 60_000
  @private_key :claude_thread_attempt

  @replay_create_error_codes ~w(
    thread_already_continued
    thread_continue_in_flight
    thread_fingerprint_mismatch
  )

  @org_unsupported_reasons ~w(hipaa inference_hooks)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Removes the private attempt metadata before a spec crosses the native boundary.
  """
  @spec pop_attempt(map()) :: {map() | nil, map()}
  def pop_attempt(spec) when is_map(spec), do: Map.pop(spec, @private_key)

  @doc """
  Reads the private attempt metadata attached to `spec`, if any.
  """
  @spec get_attempt(map()) :: map() | nil
  def get_attempt(spec) when is_map(spec), do: Map.get(spec, @private_key)

  @doc """
  Attaches Anthropic Message Threads request directives and beta headers when eligible.
  """
  @spec decorate_spec(map(), map(), map()) :: map()
  def decorate_spec(spec, runtime, provider_request)
      when is_map(spec) and is_map(runtime) and is_map(provider_request) do
    ensure_tables()

    if eligible_spec?(spec, runtime, provider_request) do
      apply_thread_mode(spec, runtime, provider_request)
    else
      spec
    end
  end

  @doc """
  Recovers pre-first-event Anthropic Message Threads rejections by transforming `spec` in place.
  """
  @spec recover_pre_first_event(map() | nil, map(), map(), term()) ::
          {:retry, map(), map()} | :no_recovery
  def recover_pre_first_event(attempt, context, spec, reason)
      when is_map(attempt) and is_map(context) and is_map(spec) do
    ensure_tables()
    tried_modes = Map.get(context, :claude_thread_retried_modes, MapSet.new())

    case classify_thread_rejection(attempt, reason, tried_modes) do
      {:replay_create, fallback_reason} ->
        delete_anchor(attempt.anchor_key)
        next_spec = force_create_spec(spec, attempt, fallback_reason)

        next_context =
          context
          |> Map.put(:claude_thread_retried_modes, MapSet.put(tried_modes, :force_create))
          |> Map.put(:claude_thread_fallback_reason, fallback_reason)

        {:retry, next_context, next_spec}

      {:continue_unthreaded, fallback_reason} ->
        put_unthreaded_session(attempt.anchor_key)
        unthreaded_retry(context, spec, tried_modes, fallback_reason)

      {:unthreaded_negative_cache, fallback_reason, cache_provider?} ->
        delete_anchor(attempt.anchor_key)
        if cache_provider?, do: put_negative_capability(attempt.provider_version_key)
        unthreaded_retry(context, spec, tried_modes, fallback_reason)

      :none ->
        :no_recovery
    end
  end

  def recover_pre_first_event(_attempt, _context, _spec, _reason), do: :no_recovery

  @doc """
  Projects continuation observability attributes for a Claude round.
  """
  @spec telemetry_attrs(map() | nil, String.t() | nil, map() | nil) :: map()
  def telemetry_attrs(%{} = attempt, fallback_reason, resolver_metadata) do
    resolver_thread =
      case resolver_metadata do
        %{"anthropic_thread" => %{} = meta} -> meta
        _other -> %{}
      end

    mode =
      case Map.get(resolver_thread, "effective_mode") do
        "continue" -> "claude_thread_continue"
        "create" -> "claude_thread_create"
        _other -> attempt.continuation_mode
      end

    resolved_fallback =
      fallback_reason ||
        Map.get(attempt, :continuation_fallback_reason) ||
        if(Map.get(resolver_thread, "prefix_mismatch_fallback") == true,
          do: "prefix_mismatch",
          else: nil
        )

    %{
      continuation_mode: mode,
      logical_request_bytes: Map.get(attempt, :logical_request_bytes),
      continuation_fallback_reason: resolved_fallback
    }
  end

  def telemetry_attrs(nil, fallback_reason, _resolver_metadata) do
    %{
      continuation_mode: "stateless_full",
      logical_request_bytes: nil,
      continuation_fallback_reason: fallback_reason
    }
  end

  @doc """
  Stores or evicts the Message Threads anchor from Rust `resolver_metadata`.
  """
  @spec record_completion(map() | nil, map() | nil) :: :ok
  def record_completion(nil, _resolver_metadata), do: :ok
  def record_completion(_attempt, nil), do: :ok

  def record_completion(%{mode: mode} = attempt, %{"anthropic_thread" => %{} = meta})
      when mode in [:create, :continue] do
    ensure_tables()
    status = Map.get(meta, "status")
    fallback_used? = Map.get(meta, "fallback_message_used") == true
    message_id = Attrs.optional_text(Map.get(meta, "upstream_message_id"))
    prefix_count = Map.get(meta, "next_prefix_count")
    prefix_digest = Attrs.optional_text(Map.get(meta, "next_prefix_digest"))

    cond do
      fallback_used? ->
        delete_anchor(attempt.anchor_key)
        :ok

      status == "completed" and is_binary(message_id) and is_integer(prefix_count) and
        prefix_count > 0 and is_binary(prefix_digest) ->
        put_anchor(attempt.anchor_key, %{
          kind: :anchor,
          message_id: message_id,
          prefix_count: prefix_count,
          prefix_digest: prefix_digest,
          structural_fingerprint: attempt.structural_fingerprint,
          after_replay_create?: Map.get(attempt, :replayed_create?, false),
          updated_at_ms: System.monotonic_time(:millisecond)
        })

      true ->
        :ok
    end
  end

  def record_completion(_attempt, _resolver_metadata), do: :ok

  @doc """
  Evicts stored thread anchors when a downstream socket or conversation ends.
  """
  @spec evict_scope(term(), String.t(), ContinuationScope.scope_key()) :: :ok
  def evict_scope(tenant_id, subject_uid, scope_key) do
    ensure_tables()

    pattern = {{tenant_id, subject_uid, scope_key, :_, :_}, :_}
    :ets.match_delete(@anchors_table, pattern)
    :ok
  catch
    :error, :badarg -> :ok
  end

  @doc false
  @spec reset!() :: :ok
  def reset! do
    ensure_tables()
    :ets.delete_all_objects(@anchors_table)
    :ets.delete_all_objects(@negative_table)
    :ok
  catch
    :error, :badarg -> :ok
  end

  @impl GenServer
  def init(opts) do
    ensure_tables()
    sweep_interval_ms = Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms)
    {:ok, %{sweep_interval_ms: sweep_interval_ms, timer: schedule_sweep(sweep_interval_ms)}}
  end

  @impl GenServer
  def handle_info(:sweep_expired, state) do
    sweep_tables(System.monotonic_time(:millisecond))
    {:noreply, %{state | timer: schedule_sweep(state.sweep_interval_ms)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp apply_thread_mode(spec, runtime, provider_request) do
    with {:ok, scope} <- ContinuationScope.resolve(runtime, provider_request),
         true <- ContinuationScope.explicit_session?(scope.scope_key),
         provider_row_id when is_binary(provider_row_id) <-
           ContinuationScope.provider_row_id(runtime) do
      credential_id = Attrs.optional_text(Map.get(runtime, "credential_id")) || "default"

      anchor_key =
        {scope.tenant_id, scope.subject_uid, scope.scope_key, provider_row_id, credential_id}

      provider_version_key = ContinuationScope.provider_version_key(runtime)
      fingerprint = structural_fingerprint(spec, provider_request)

      case lookup_fresh_entry(anchor_key) do
        %{kind: :unthreaded} ->
          spec

        entry ->
          build_threaded_spec(
            spec,
            provider_request,
            anchor_key,
            provider_version_key,
            fingerprint,
            entry
          )
      end
    else
      _ineligible -> spec
    end
  end

  defp build_threaded_spec(
         spec,
         provider_request,
         anchor_key,
         provider_version_key,
         fingerprint,
         entry
       ) do
    if match?(%{kind: :anchor}, entry) and entry.structural_fingerprint == fingerprint do
      directive = %{
        "mode" => "continue",
        "previous_message_id" => entry.message_id,
        "expected_prefix_count" => entry.prefix_count,
        "expected_prefix_digest" => entry.prefix_digest
      }

      attempt = %{
        mode: :continue,
        continuation_mode: "claude_thread_continue",
        continuation_fallback_reason: nil,
        logical_request_bytes: ContinuationScope.encoded_bytes(provider_request),
        anchor_key: anchor_key,
        provider_version_key: provider_version_key,
        structural_fingerprint: fingerprint,
        after_replay_create?: Map.get(entry, :after_replay_create?, false),
        replayed_create?: false
      }

      spec
      |> put_thread_directive(directive)
      |> put_beta_header()
      |> Map.put(@private_key, attempt)
    else
      attempt = %{
        mode: :create,
        continuation_mode: "claude_thread_create",
        continuation_fallback_reason: nil,
        logical_request_bytes: nil,
        anchor_key: anchor_key,
        provider_version_key: provider_version_key,
        structural_fingerprint: fingerprint,
        after_replay_create?: false,
        replayed_create?: false
      }

      spec
      |> put_thread_directive(%{"mode" => "create"})
      |> put_beta_header()
      |> Map.put(@private_key, attempt)
    end
  end

  defp eligible_spec?(spec, runtime, provider_request) do
    resolver = Attrs.get_truthy(spec, "api_resolver")
    hosted? = not is_nil(Attrs.get_truthy(spec, "hosted_tools"))
    provider_version_key = ContinuationScope.provider_version_key(runtime)

    Map.get(runtime, "provider_kind") == "claude" and
      resolver in [:anthropic_messages, "anthropic_messages"] and
      not hosted? and
      setting_enabled?(runtime, spec) and
      not negative_cached?(provider_version_key) and
      pre_flight_compatible?(spec, provider_request)
  end

  defp setting_enabled?(runtime, spec) do
    connection = Map.get(runtime, "connection_options") || %{}

    case Map.get(connection, "message_threads", "auto") do
      "disabled" -> false
      "enabled" -> true
      _auto -> ContinuationScope.upstream_host(spec) == "api.anthropic.com"
    end
  end

  defp pre_flight_compatible?(spec, provider_request) do
    provider_options = response_provider_options(spec)

    has_compaction? =
      not is_nil(Map.get(provider_request, "compaction")) or
        not is_nil(Map.get(provider_options, "compaction"))

    cm =
      Map.get(provider_request, "context_management") ||
        Map.get(provider_options, "context_management")

    not has_compaction? and
      supported_context_management?(cm) and
      not has_message_block_cache_control?(Map.get(provider_request, "input")) and
      total_cache_controls(provider_request, provider_options) <= 4
  end

  defp supported_context_management?(nil), do: true

  defp supported_context_management?(%{"edits" => edits}) when is_list(edits) do
    Enum.all?(edits, fn
      %{"type" => "clear_thinking_20251015"} = edit ->
        keep = Map.get(edit, "keep")
        keep in [nil, "all", %{"type" => "all"}]

      _unsupported ->
        false
    end)
  end

  defp supported_context_management?(%{} = cm) when map_size(cm) == 0, do: true
  defp supported_context_management?(_other), do: false

  defp has_message_block_cache_control?(items) when is_list(items) do
    Enum.any?(items, fn
      %{"cache_control" => cc} when not is_nil(cc) ->
        true

      %{"content" => parts} when is_list(parts) ->
        Enum.any?(parts, fn
          %{"cache_control" => cc} when not is_nil(cc) -> true
          _part -> false
        end)

      _item ->
        false
    end)
  end

  defp has_message_block_cache_control?(_input), do: false

  defp total_cache_controls(request, provider_options) do
    count_cache_controls(request) +
      if(
        Map.has_key?(provider_options, "cache_control") and
          not Map.has_key?(request, "cache_control"),
        do: 1,
        else: 0
      )
  end

  @doc false
  @spec count_cache_controls(term()) :: non_neg_integer()
  def count_cache_controls(%{} = map) do
    own = if not is_nil(Map.get(map, "cache_control")), do: 1, else: 0

    nested =
      Enum.reduce(map, 0, fn
        {"cache_control", _v}, acc -> acc
        {_k, v}, acc -> acc + count_cache_controls(v)
      end)

    own + nested
  end

  def count_cache_controls(list) when is_list(list),
    do: Enum.reduce(list, 0, fn item, acc -> acc + count_cache_controls(item) end)

  def count_cache_controls(_other), do: 0

  @doc false
  @spec structural_fingerprint(map(), map()) :: binary()
  def structural_fingerprint(spec, provider_request) do
    provider_options = response_provider_options(spec)
    headers = upstream_headers(spec)

    payload = %{
      model: response_model(spec),
      system:
        Map.get(provider_request, "instructions") || Map.get(provider_request, "system") ||
          Map.get(provider_options, "system"),
      tools: Map.get(provider_request, "tools") || Map.get(provider_options, "tools"),
      tool_choice:
        Map.get(provider_request, "tool_choice") || Map.get(provider_options, "tool_choice"),
      reasoning: Map.get(provider_request, "reasoning"),
      thinking: Map.get(provider_request, "thinking") || Map.get(provider_options, "thinking"),
      output_config:
        Map.get(provider_request, "output_config") || Map.get(provider_options, "output_config"),
      context_management:
        Map.get(provider_request, "context_management") ||
          Map.get(provider_options, "context_management"),
      mcp_servers:
        sanitize_mcp_servers(
          Map.get(provider_request, "mcp_servers") || Map.get(provider_options, "mcp_servers")
        ),
      container_skills: extract_container_skills(provider_request, provider_options),
      cache_control:
        Map.get(provider_request, "cache_control") || Map.get(provider_options, "cache_control"),
      betas: effective_betas_without_threads(headers),
      anthropic_version: effective_anthropic_version(headers, provider_request, provider_options),
      has_fallbacks:
        Map.has_key?(provider_request, "fallbacks") or Map.has_key?(provider_options, "fallbacks")
    }

    :crypto.hash(:sha256, :erlang.term_to_binary(payload, [:deterministic]))
  end

  defp sanitize_mcp_servers(servers) when is_list(servers) do
    Enum.map(servers, fn
      %{} = server -> Map.delete(server, "authorization_token")
      other -> other
    end)
  end

  defp sanitize_mcp_servers(other), do: other

  defp extract_container_skills(request, provider_options) do
    container = Map.get(request, "container") || Map.get(provider_options, "container")

    case container do
      %{"skills" => skills} -> skills
      _other -> nil
    end
  end

  defp effective_betas_without_threads(headers) do
    headers
    |> header_values("anthropic-beta")
    |> Enum.flat_map(&String.split(&1, ",", trim: true))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 in ["", @beta_flag]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp effective_anthropic_version(headers, request, provider_options) do
    header_values(headers, "anthropic-version")
    |> List.first()
    |> Kernel.||(Map.get(provider_options, "anthropic-version"))
    |> Kernel.||(Map.get(provider_options, "anthropic_version"))
    |> Kernel.||(Map.get(request, "anthropic-version"))
    |> Kernel.||(Map.get(request, "anthropic_version"))
  end

  defp classify_thread_rejection(attempt, reason, tried_modes) do
    {status, body, message} = extract_failure_facts(reason)
    details = get_in(body, ["error", "details"]) || Map.get(body, "details") || %{}
    error_code = if is_map(details), do: Map.get(details, "error_code"), else: nil

    cond do
      status == 404 and error_code == "thread_not_found" and attempt.mode == :continue ->
        classify_not_found(attempt, tried_modes)

      status == 400 and error_code in @replay_create_error_codes and attempt.mode == :continue and
          not MapSet.member?(tried_modes, :force_create) ->
        {:replay_create, error_code}

      status == 400 and error_code == "thread_unsupported_request" and
          not MapSet.member?(tried_modes, :unthreaded) ->
        cache? = org_unsupported?(details, body, message)
        {:unthreaded_negative_cache, "thread_unsupported_request", cache?}

      status == 400 and not MapSet.member?(tried_modes, :unthreaded) and
          proxy_unknown_thread_rejection?(body, message) ->
        {:unthreaded_negative_cache, "thread_unsupported_endpoint", true}

      true ->
        :none
    end
  end

  defp classify_not_found(attempt, tried_modes) do
    cond do
      attempt.after_replay_create? and not MapSet.member?(tried_modes, :unthreaded) ->
        {:continue_unthreaded, "thread_not_found_unthreaded"}

      not MapSet.member?(tried_modes, :force_create) ->
        {:replay_create, "thread_not_found"}

      true ->
        :none
    end
  end

  defp org_unsupported?(details, body, message) when is_map(details) do
    unsupported = List.wrap(Map.get(details, "unsupported"))
    reason = Map.get(details, "reason")
    raw_msg = String.downcase(to_string(get_in(body, ["error", "message"]) || message || ""))

    Enum.any?(unsupported, &(&1 in @org_unsupported_reasons)) or
      reason in @org_unsupported_reasons or
      Enum.any?(@org_unsupported_reasons, &String.contains?(raw_msg, &1))
  end

  defp org_unsupported?(_details, _body, _message), do: false

  defp proxy_unknown_thread_rejection?(body, message) do
    raw_msg =
      get_in(body, ["error", "message"]) ||
        Map.get(body, "message") ||
        message ||
        ""

    downcased = String.downcase(to_string(raw_msg))

    String.contains?(downcased, "thread") and
      (String.contains?(downcased, "extra inputs") or
         String.contains?(downcased, "unknown field") or
         String.contains?(downcased, "unrecognized") or
         String.contains?(downcased, "not permitted") or
         String.contains?(downcased, "unsupported"))
  end

  defp extract_failure_facts(%ProviderFailure{} = failure) do
    {failure.provider_status, failure.provider_body || %{}, failure.message}
  end

  defp extract_failure_facts(%{} = error) do
    status = Map.get(error, "provider_status")

    body =
      case Map.get(error, "provider_body_excerpt") do
        excerpt when is_binary(excerpt) ->
          case Ankole.JSON.decode(excerpt) do
            {:ok, %{} = decoded} -> decoded
            _other -> %{}
          end

        _other ->
          %{}
      end

    {status, body, Map.get(error, "message")}
  end

  defp extract_failure_facts(_other), do: {nil, %{}, nil}

  defp unthreaded_retry(context, spec, tried_modes, fallback_reason) do
    next_spec = strip_thread_from_spec(spec, fallback_reason)

    next_context =
      context
      |> Map.put(:claude_thread_retried_modes, MapSet.put(tried_modes, :unthreaded))
      |> Map.put(:claude_thread_fallback_reason, fallback_reason)
      |> Map.put(:claude_thread_unthreaded?, true)

    {:retry, next_context, next_spec}
  end

  defp force_create_spec(spec, attempt, fallback_reason) do
    next_attempt = %{
      attempt
      | mode: :create,
        continuation_mode: "claude_thread_create",
        continuation_fallback_reason: fallback_reason,
        logical_request_bytes: nil,
        after_replay_create?: false,
        replayed_create?: true
    }

    spec
    |> put_thread_directive(%{"mode" => "create"})
    |> put_beta_header()
    |> Map.put(@private_key, next_attempt)
  end

  defp put_thread_directive(%{response_context: %{} = rc} = spec, directive) do
    request = (Map.get(rc, :request) || %{}) |> Map.put("__ankole_anthropic_thread", directive)
    %{spec | response_context: Map.put(rc, :request, request)}
  end

  defp put_thread_directive(spec, _directive), do: spec

  defp put_beta_header(%{upstream: %{headers: headers} = upstream} = spec)
       when is_list(headers) do
    existing = effective_betas_without_threads(headers)
    combined = Enum.join(existing ++ [@beta_flag], ",")

    updated_headers =
      headers
      |> Enum.reject(fn {name, _val} -> String.downcase(to_string(name)) == "anthropic-beta" end)
      |> Kernel.++([{"anthropic-beta", combined}])

    %{spec | upstream: %{upstream | headers: updated_headers}}
  end

  defp put_beta_header(spec), do: spec

  @doc false
  @spec strip_thread_from_spec(map(), String.t() | nil) :: map()
  def strip_thread_from_spec(spec, fallback_reason) do
    spec =
      case spec do
        %{response_context: %{request: %{} = req} = rc} ->
          %{
            spec
            | response_context: %{rc | request: Map.delete(req, "__ankole_anthropic_thread")}
          }

        other ->
          other
      end

    spec =
      case spec do
        %{upstream: %{headers: headers} = upstream} when is_list(headers) ->
          remaining_betas = effective_betas_without_threads(headers)

          cleaned =
            Enum.reject(headers, fn {name, _val} ->
              String.downcase(to_string(name)) == "anthropic-beta"
            end)

          updated =
            if remaining_betas == [],
              do: cleaned,
              else: cleaned ++ [{"anthropic-beta", Enum.join(remaining_betas, ",")}]

          %{spec | upstream: %{upstream | headers: updated}}

        other ->
          other
      end

    Map.put(spec, @private_key, %{
      mode: :unthreaded,
      continuation_mode: "stateless_full",
      continuation_fallback_reason: fallback_reason,
      logical_request_bytes: nil
    })
  end

  defp response_provider_options(spec) do
    get_in(spec, [:response_context, :provider_options]) ||
      get_in(spec, ["response_context", "provider_options"]) ||
      %{}
  end

  defp response_model(spec) do
    get_in(spec, [:response_context, :model]) ||
      get_in(spec, ["response_context", "model"])
  end

  defp upstream_headers(spec) do
    get_in(spec, [:upstream, :headers]) ||
      get_in(spec, ["upstream", "headers"]) ||
      []
  end

  defp header_values(headers, target) do
    for {name, value} <- headers,
        String.downcase(to_string(name)) == target,
        is_binary(value) do
      value
    end
  end

  defp ensure_tables do
    create_table_if_missing(@anchors_table)
    create_table_if_missing(@negative_table)
  end

  defp create_table_if_missing(name) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :ok
  catch
    :error, :badarg -> :ok
  end

  defp lookup_fresh_entry(anchor_key) do
    now_ms = System.monotonic_time(:millisecond)

    case :ets.lookup(@anchors_table, anchor_key) do
      [{^anchor_key, entry}] ->
        if now_ms - entry.updated_at_ms < @anchor_ttl_ms do
          entry
        else
          :ets.delete(@anchors_table, anchor_key)
          nil
        end

      [] ->
        nil
    end
  catch
    :error, :badarg -> nil
  end

  defp put_anchor(anchor_key, entry) do
    :ets.insert(@anchors_table, {anchor_key, entry})
    :ok
  catch
    :error, :badarg -> :ok
  end

  defp put_unthreaded_session(anchor_key) do
    entry = %{kind: :unthreaded, updated_at_ms: System.monotonic_time(:millisecond)}
    :ets.insert(@anchors_table, {anchor_key, entry})
    :ok
  catch
    :error, :badarg -> :ok
  end

  defp delete_anchor(anchor_key) do
    :ets.delete(@anchors_table, anchor_key)
    :ok
  catch
    :error, :badarg -> :ok
  end

  defp negative_cached?(nil), do: false

  defp negative_cached?(version_key) do
    now_ms = System.monotonic_time(:millisecond)

    case :ets.lookup(@negative_table, version_key) do
      [{^version_key, expires_at_ms}] ->
        if now_ms < expires_at_ms do
          true
        else
          :ets.delete(@negative_table, version_key)
          false
        end

      [] ->
        false
    end
  catch
    :error, :badarg -> false
  end

  defp put_negative_capability(nil), do: :ok

  defp put_negative_capability(version_key) do
    expires_at_ms = System.monotonic_time(:millisecond) + @negative_ttl_ms
    :ets.insert(@negative_table, {version_key, expires_at_ms})
    :ok
  catch
    :error, :badarg -> :ok
  end

  defp sweep_tables(now_ms) do
    sweep_anchors(now_ms)
    sweep_negative(now_ms)
  end

  defp sweep_anchors(now_ms) do
    :ets.foldl(
      fn {key, entry}, :ok ->
        if now_ms - entry.updated_at_ms >= @anchor_ttl_ms do
          :ets.delete(@anchors_table, key)
        end

        :ok
      end,
      :ok,
      @anchors_table
    )
  catch
    :error, :badarg -> :ok
  end

  defp sweep_negative(now_ms) do
    :ets.foldl(
      fn {key, expires_at_ms}, :ok ->
        if now_ms >= expires_at_ms do
          :ets.delete(@negative_table, key)
        end

        :ok
      end,
      :ok,
      @negative_table
    )
  catch
    :error, :badarg -> :ok
  end

  defp schedule_sweep(interval_ms) do
    Process.send_after(self(), :sweep_expired, interval_ms)
  end
end
