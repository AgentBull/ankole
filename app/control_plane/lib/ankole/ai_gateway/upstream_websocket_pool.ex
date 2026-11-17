defmodule Ankole.AIGateway.UpstreamWebSocketPool do
  @moduledoc """
  Node-local pool of single-lane upstream WebSocket sessions and connection-scoped
  `previous_response_id` continuation anchors for OpenAI Responses streams.
  """

  use GenServer

  alias Ankole.AIGateway.CompactionHistory
  alias Ankole.AIGateway.ContinuationScope
  alias Ankole.AIGateway.FailureDiagnostics
  alias Ankole.AIGateway.ProviderFailure
  alias Ankole.AIGateway.ResponseItems
  alias Ankole.Attrs
  alias Ankole.Kernel.UniversalAIClient

  @default_max_reuse_age_ms 15 * 60_000
  @high_reasoning_max_reuse_age_ms 5 * 60_000
  @default_idle_ttl_ms 5 * 60_000
  @sweep_interval_ms 60_000

  @ephemeral_ws_headers ~w(
    traceparent
    x-client-request-id
    x-codex-turn-metadata
    x-codex-turn-state
  )

  @reused_socket_transport_codes ~w(
    provider_stream_closed_without_terminal
    transport_failed
    upstream_read_failed
    upstream_stream_closed_before_terminal_event
    websocket_connect_failed
    websocket_read_failed
    websocket_send_failed
  )

  @type anchor :: %{
          upstream_response_id: String.t(),
          model: String.t(),
          prefix_len: pos_integer(),
          prefix_digest: binary()
        }

  @type stream_attempt :: %{
          spec: map(),
          full_spec: map(),
          ws_session: UniversalAIClient.ws_session() | nil,
          lease_id: reference() | nil,
          reused?: boolean(),
          delta?: boolean(),
          can_anchor?: boolean(),
          continuation_mode: String.t(),
          continuation_fallback_reason: String.t() | nil,
          logical_request_bytes: non_neg_integer() | nil,
          raw_round_items: [map()],
          fallback_used?: boolean()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Prepares an upstream stream attempt, checking out a warm WebSocket session and
  slicing `input` to incremental `delta_items` when a valid anchor matches.
  """
  @spec prepare_stream_attempt(map(), map() | nil, keyword()) :: stream_attempt()
  def prepare_stream_attempt(spec, runtime, opts \\ []) when is_map(spec) do
    owner_pid = Keyword.get(opts, :owner_pid, self())

    if poolable_websocket_spec?(spec, runtime) do
      checkout_and_prepare(spec, runtime, owner_pid, opts)
    else
      unpooled_attempt(spec)
    end
  end

  @doc """
  Records one raw `response.output_item.done` item observed during the active round.
  """
  @spec observe_round_event(stream_attempt() | nil, map()) :: stream_attempt() | nil
  def observe_round_event(nil, _event), do: nil

  def observe_round_event(%{raw_round_items: items} = attempt, %{
        "type" => "response.output_item.done",
        "item" => %{} = item
      }) do
    %{attempt | raw_round_items: [item | items]}
  end

  def observe_round_event(attempt, _event), do: attempt

  @doc """
  Settles a leased WebSocket session when its round reaches a terminal event.
  """
  @spec complete_stream_attempt(stream_attempt() | nil, String.t() | nil, term(), [map()]) :: :ok
  def complete_stream_attempt(nil, _status, _upstream_response_id, _fallback_items), do: :ok
  def complete_stream_attempt(%{lease_id: nil}, _status, _response_id, _items), do: :ok

  def complete_stream_attempt(attempt, "completed", upstream_response_id, fallback_items) do
    anchor =
      if Map.get(attempt, :can_anchor?, false),
        do: build_completion_anchor(attempt, upstream_response_id, fallback_items),
        else: nil

    checkin(attempt.lease_id, anchor)
  end

  def complete_stream_attempt(attempt, "incomplete", _upstream_response_id, _fallback_items) do
    checkin(attempt.lease_id, nil)
  end

  def complete_stream_attempt(attempt, _failed_or_other, _upstream_response_id, _fallback_items) do
    discard(attempt.lease_id)
  end

  @doc """
  Closes and discards any leased WebSocket session immediately.
  """
  @spec abort_stream_attempt(stream_attempt() | nil) :: :ok
  def abort_stream_attempt(nil), do: :ok
  def abort_stream_attempt(%{lease_id: nil}), do: :ok
  def abort_stream_attempt(%{lease_id: lease_id}), do: discard(lease_id)

  @doc """
  Plans a one-shot silent fallback to a fresh WebSocket with full history when a
  reused socket or `previous_response_id` delta fails before emitting any event.
  """
  @spec plan_pre_first_event_fallback(stream_attempt() | nil, map() | nil, keyword(), term()) ::
          {:fallback, stream_attempt(), String.t()} | :no_fallback
  def plan_pre_first_event_fallback(nil, _runtime, _opts, _reason), do: :no_fallback

  def plan_pre_first_event_fallback(%{fallback_used?: true} = attempt, _runtime, _opts, _reason) do
    abort_stream_attempt(attempt)
    :no_fallback
  end

  def plan_pre_first_event_fallback(attempt, runtime, opts, reason) do
    case fallback_reason(attempt, reason) do
      {:ok, reason_tag} ->
        abort_stream_attempt(attempt)

        fresh_opts =
          opts
          |> Keyword.put(:force_fresh_socket?, true)
          |> Keyword.put_new(:owner_pid, self())

        next_attempt =
          attempt.full_spec
          |> prepare_stream_attempt(runtime, fresh_opts)
          |> Map.merge(%{
            fallback_used?: true,
            continuation_fallback_reason: reason_tag
          })

        {:fallback, next_attempt, reason_tag}

      :none ->
        abort_stream_attempt(attempt)
        :no_fallback
    end
  end

  @doc """
  Evicts all pooled sessions belonging to a terminated downstream socket or conversation.
  """
  @spec evict_scope(term(), String.t(), ContinuationScope.scope_key()) :: :ok
  def evict_scope(tenant_id, subject_uid, scope_key) do
    case GenServer.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.cast(pid, {:evict_scope, tenant_id, subject_uid, scope_key})

      nil ->
        :ok
    end
  end

  @doc false
  @spec reset!() :: :ok
  def reset! do
    case GenServer.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, :reset)
      nil -> :ok
    end
  end

  @impl GenServer
  def init(opts) do
    max_reuse_age_ms = Keyword.get(opts, :max_reuse_age_ms, @default_max_reuse_age_ms)
    idle_ttl_ms = Keyword.get(opts, :idle_ttl_ms, @default_idle_ttl_ms)
    sweep_interval_ms = Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms)

    state = %{
      entries: %{},
      leases: %{},
      monitors: %{},
      max_reuse_age_ms: max_reuse_age_ms,
      idle_ttl_ms: idle_ttl_ms,
      sweep_interval_ms: sweep_interval_ms,
      sweep_timer: schedule_sweep(sweep_interval_ms)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:checkout, pool_key, owner_pid, opts}, _from, state) do
    {reply, next_state} = do_checkout(state, pool_key, owner_pid, opts)
    {:reply, reply, next_state}
  end

  def handle_call({:checkin, lease_id, anchor}, _from, state) do
    {:reply, :ok, do_checkin(state, lease_id, anchor)}
  end

  def handle_call({:discard, lease_id}, _from, state) do
    {:reply, :ok, do_discard(state, lease_id)}
  end

  def handle_call(:reset, _from, state) do
    Enum.each(state.entries, fn {_key, entry} -> close_ws_session(entry.ws_session) end)
    {:reply, :ok, %{state | entries: %{}, leases: %{}, monitors: %{}}}
  end

  @impl GenServer
  def handle_cast({:evict_scope, tenant_id, subject_uid, scope_key}, state) do
    {:noreply, do_evict_scope(state, tenant_id, subject_uid, scope_key)}
  end

  @impl GenServer
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.get(state.monitors, monitor_ref) do
      nil -> {:noreply, state}
      lease_id -> {:noreply, do_discard(state, lease_id)}
    end
  end

  def handle_info(:sweep_expired, state) do
    now_ms = System.monotonic_time(:millisecond)

    entries =
      Enum.reduce(state.entries, state.entries, fn {key, entry}, acc ->
        if entry.status == :idle and
             expired_entry?(entry, now_ms, state.max_reuse_age_ms, state.idle_ttl_ms) do
          close_ws_session(entry.ws_session)
          Map.delete(acc, key)
        else
          acc
        end
      end)

    {:noreply, %{state | entries: entries, sweep_timer: schedule_sweep(state.sweep_interval_ms)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp checkout_and_prepare(spec, runtime, owner_pid, opts) do
    request = response_request(spec)

    with {:ok, scope} <- ContinuationScope.resolve(runtime, request),
         provider_row_id when is_binary(provider_row_id) <-
           ContinuationScope.provider_row_id(runtime),
         pool_key = build_pool_key(scope, provider_row_id, runtime, spec),
         {:ok, lease} <- checkout(pool_key, owner_pid, checkout_opts(spec, opts)) do
      build_leased_attempt(spec, runtime, scope.scope_key, lease)
    else
      _unavailable_or_busy ->
        unpooled_attempt(spec)
    end
  end

  defp checkout(pool_key, owner_pid, opts) do
    case GenServer.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(pid, {:checkout, pool_key, owner_pid, opts})

      nil ->
        :unavailable
    end
  catch
    :exit, _reason -> :unavailable
  end

  defp checkin(lease_id, anchor) do
    case GenServer.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, {:checkin, lease_id, anchor})
      nil -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp discard(lease_id) do
    case GenServer.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, {:discard, lease_id})
      nil -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp do_checkout(state, pool_key, owner_pid, opts) do
    now_ms = Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))
    force_fresh? = Keyword.get(opts, :force_fresh_socket?, false)

    max_age_ms =
      effective_max_age_ms(state.max_reuse_age_ms, Keyword.get(opts, :high_reasoning?, false))

    case Map.get(state.entries, pool_key) do
      %{status: :leased} ->
        {:busy, state}

      %{status: :idle} = entry ->
        if force_fresh? or expired_entry?(entry, now_ms, max_age_ms, state.idle_ttl_ms) do
          close_ws_session(entry.ws_session)
          state = %{state | entries: Map.delete(state.entries, pool_key)}
          create_leased_entry(state, pool_key, owner_pid, now_ms)
        else
          lease_existing_entry(state, pool_key, entry, owner_pid)
        end

      nil ->
        create_leased_entry(state, pool_key, owner_pid, now_ms)
    end
  end

  defp create_leased_entry(state, pool_key, owner_pid, now_ms) do
    case UniversalAIClient.new_ws_session() do
      {:ok, ws_session} ->
        lease_id = make_ref()
        monitor_ref = Process.monitor(owner_pid)

        entry = %{
          status: :leased,
          ws_session: ws_session,
          created_at_ms: now_ms,
          last_used_at_ms: now_ms,
          anchor: nil,
          lease_id: lease_id,
          monitor_ref: monitor_ref,
          evict_on_return?: false
        }

        next_state = %{
          state
          | entries: Map.put(state.entries, pool_key, entry),
            leases: Map.put(state.leases, lease_id, pool_key),
            monitors: Map.put(state.monitors, monitor_ref, lease_id)
        }

        {{:ok, %{lease_id: lease_id, ws_session: ws_session, reused?: false, anchor: nil}},
         next_state}

      {:error, _reason} ->
        {:unavailable, state}
    end
  end

  defp lease_existing_entry(state, pool_key, entry, owner_pid) do
    lease_id = make_ref()
    monitor_ref = Process.monitor(owner_pid)

    leased = %{
      entry
      | status: :leased,
        lease_id: lease_id,
        monitor_ref: monitor_ref
    }

    next_state = %{
      state
      | entries: Map.put(state.entries, pool_key, leased),
        leases: Map.put(state.leases, lease_id, pool_key),
        monitors: Map.put(state.monitors, monitor_ref, lease_id)
    }

    reply =
      {:ok,
       %{lease_id: lease_id, ws_session: entry.ws_session, reused?: true, anchor: entry.anchor}}

    {reply, next_state}
  end

  defp do_checkin(state, lease_id, anchor) do
    case Map.pop(state.leases, lease_id) do
      {nil, _leases} ->
        state

      {pool_key, leases} ->
        entry = Map.get(state.entries, pool_key)
        finish_checkin_entry(%{state | leases: leases}, pool_key, entry, lease_id, anchor)
    end
  end

  defp finish_checkin_entry(state, pool_key, %{lease_id: lease_id} = entry, lease_id, anchor) do
    Process.demonitor(entry.monitor_ref, [:flush])
    monitors = Map.delete(state.monitors, entry.monitor_ref)

    if entry.evict_on_return? do
      close_ws_session(entry.ws_session)
      %{state | entries: Map.delete(state.entries, pool_key), monitors: monitors}
    else
      parked = %{
        entry
        | status: :idle,
          last_used_at_ms: System.monotonic_time(:millisecond),
          anchor: anchor,
          lease_id: nil,
          monitor_ref: nil
      }

      %{state | entries: Map.put(state.entries, pool_key, parked), monitors: monitors}
    end
  end

  defp finish_checkin_entry(state, _pool_key, _other_entry, _lease_id, _anchor), do: state

  defp do_discard(state, lease_id) do
    case Map.pop(state.leases, lease_id) do
      {nil, _leases} ->
        state

      {pool_key, leases} ->
        entry = Map.get(state.entries, pool_key)
        finish_discard_entry(%{state | leases: leases}, pool_key, entry, lease_id)
    end
  end

  defp finish_discard_entry(state, pool_key, %{lease_id: lease_id} = entry, lease_id) do
    Process.demonitor(entry.monitor_ref, [:flush])
    close_ws_session(entry.ws_session)

    %{
      state
      | entries: Map.delete(state.entries, pool_key),
        monitors: Map.delete(state.monitors, entry.monitor_ref)
    }
  end

  defp finish_discard_entry(state, _pool_key, _other_entry, _lease_id), do: state

  defp do_evict_scope(state, tenant_id, subject_uid, scope_key) do
    entries =
      Enum.reduce(state.entries, state.entries, fn {pool_key, entry}, acc ->
        if match_scope?(pool_key, tenant_id, subject_uid, scope_key) do
          evict_matching_entry(acc, pool_key, entry)
        else
          acc
        end
      end)

    %{state | entries: entries}
  end

  defp evict_matching_entry(acc, pool_key, %{status: :idle, ws_session: ws_session}) do
    close_ws_session(ws_session)
    Map.delete(acc, pool_key)
  end

  defp evict_matching_entry(acc, pool_key, %{status: :leased} = entry) do
    Map.put(acc, pool_key, %{entry | evict_on_return?: true})
  end

  defp match_scope?(
         {tenant_id, subject_uid, scope_key, _row_id, _cred_id, _fp},
         tenant_id,
         subject_uid,
         scope_key
       ),
       do: true

  defp match_scope?(_pool_key, _tenant_id, _subject_uid, _scope_key), do: false

  defp build_leased_attempt(spec, runtime, scope_key, lease) do
    can_anchor? =
      ContinuationScope.explicit_session?(scope_key) and
        continuation_setting_enabled?(runtime, spec)

    case maybe_slice_delta_spec(spec, can_anchor?, lease) do
      {:delta, delta_spec, logical_bytes} ->
        %{
          spec: delta_spec,
          full_spec: spec,
          ws_session: lease.ws_session,
          lease_id: lease.lease_id,
          reused?: true,
          delta?: true,
          can_anchor?: true,
          continuation_mode: "ws_reused_delta",
          continuation_fallback_reason: nil,
          logical_request_bytes: logical_bytes,
          raw_round_items: [],
          fallback_used?: false
        }

      :full ->
        mode = if(lease.reused?, do: "ws_reused_full", else: "stateless_full")

        %{
          spec: spec,
          full_spec: spec,
          ws_session: lease.ws_session,
          lease_id: lease.lease_id,
          reused?: lease.reused?,
          delta?: false,
          can_anchor?: can_anchor?,
          continuation_mode: mode,
          continuation_fallback_reason: nil,
          logical_request_bytes: nil,
          raw_round_items: [],
          fallback_used?: false
        }
    end
  end

  defp maybe_slice_delta_spec(spec, true, %{reused?: true, anchor: %{} = anchor}) do
    request = response_request(spec)
    model = response_model(spec)

    with true <- model == anchor.model,
         false <- Map.has_key?(request, "__ankole_upstream_previous_response_id"),
         items when is_list(items) <- input_to_item_list(Map.get(request, "input")),
         true <- length(items) > anchor.prefix_len,
         {prefix_items, delta_items} when delta_items != [] <-
           Enum.split(items, anchor.prefix_len),
         true <- canonical_items_digest(prefix_items) == anchor.prefix_digest do
      logical_bytes = ContinuationScope.encoded_bytes(request)

      delta_request =
        request
        |> Map.put("input", delta_items)
        |> Map.put("__ankole_upstream_previous_response_id", anchor.upstream_response_id)

      {:delta, put_response_request(spec, delta_request), logical_bytes}
    else
      _not_matched -> :full
    end
  end

  defp maybe_slice_delta_spec(_spec, _can_anchor?, _lease), do: :full

  defp build_completion_anchor(attempt, upstream_response_id, fallback_items)
       when is_binary(upstream_response_id) and upstream_response_id != "" do
    full_request = response_request(attempt.full_spec)
    model = response_model(attempt.full_spec)
    round_items = resolved_round_items(attempt.raw_round_items, fallback_items)

    case input_to_item_list(Map.get(full_request, "input")) do
      input_items when is_list(input_items) and is_binary(model) and model != "" ->
        combined = input_items ++ round_items

        if combined == [] do
          nil
        else
          %{
            upstream_response_id: upstream_response_id,
            model: model,
            prefix_len: length(combined),
            prefix_digest: canonical_items_digest(combined)
          }
        end

      _other ->
        nil
    end
  end

  defp build_completion_anchor(_attempt, _upstream_response_id, _fallback_items), do: nil

  defp resolved_round_items([], fallback_items) when is_list(fallback_items), do: fallback_items
  defp resolved_round_items(raw_items, _fallback_items), do: Enum.reverse(raw_items)

  @doc false
  @spec continuation_setting_enabled?(map() | nil, map()) :: boolean()
  def continuation_setting_enabled?(%{"provider_kind" => "openai_compatible"} = runtime, _spec) do
    connection = Map.get(runtime, "connection_options") || %{}
    Map.get(connection, "upstream_websocket_continuation") == true
  end

  def continuation_setting_enabled?(%{"provider_kind" => "openai"} = runtime, spec) do
    case explicit_stored_continuation_flag(runtime) do
      flag when is_boolean(flag) -> flag
      nil -> ContinuationScope.upstream_host(spec) == "api.openai.com"
    end
  end

  def continuation_setting_enabled?(_runtime, _spec), do: false

  defp explicit_stored_continuation_flag(runtime) do
    stored =
      case Map.get(runtime, "provider") do
        %{connection_options: %{} = opts} -> opts
        _other -> Map.get(runtime, "connection_options") || %{}
      end

    case Map.get(stored, "upstream_websocket_continuation") do
      flag when is_boolean(flag) -> flag
      _unset -> nil
    end
  end

  defp fallback_reason(attempt, reason) do
    classification = FailureDiagnostics.classify(reason)
    provider_code = Map.get(classification, :provider_error_code)
    error_code = Map.get(classification, :error_code)
    status = Map.get(classification, :provider_status)

    cond do
      provider_code == "previous_response_not_found" ->
        {:ok, "previous_response_not_found"}

      provider_code == "websocket_connection_limit_reached" ->
        {:ok, "websocket_connection_limit_reached"}

      attempt.reused? and error_code in @reused_socket_transport_codes ->
        {:ok, "reused_socket_closed"}

      attempt.delta? and status in [400, 404, 422] and mentions_previous_response?(reason) ->
        {:ok, "previous_response_rejected"}

      true ->
        :none
    end
  end

  defp mentions_previous_response?(%ProviderFailure{provider_body: body, message: message}) do
    param = get_in(body, ["error", "param"]) || Map.get(body, "param")

    param == "previous_response_id" or
      (is_binary(message) and String.contains?(message, "previous_response"))
  end

  defp mentions_previous_response?(%{} = reason) do
    excerpt = Map.get(reason, "provider_body_excerpt") || Map.get(reason, "message")
    is_binary(excerpt) and String.contains?(excerpt, "previous_response")
  end

  defp mentions_previous_response?(_reason), do: false

  defp poolable_websocket_spec?(spec, runtime) when is_map(runtime) do
    upstream = Attrs.get_truthy(spec, "upstream") || %{}
    upstream_kind = Attrs.get_truthy(upstream, "kind")
    resolver = Attrs.get_truthy(spec, "api_resolver")
    hosted? = not is_nil(Attrs.get_truthy(spec, "hosted_tools"))

    upstream_kind in [:websocket_text, "websocket_text"] and
      resolver in [:openai_responses, "openai_responses"] and
      not hosted?
  end

  defp poolable_websocket_spec?(_spec, _runtime), do: false

  defp unpooled_attempt(spec) do
    %{
      spec: spec,
      full_spec: spec,
      ws_session: nil,
      lease_id: nil,
      reused?: false,
      delta?: false,
      can_anchor?: false,
      continuation_mode: "stateless_full",
      continuation_fallback_reason: nil,
      logical_request_bytes: nil,
      raw_round_items: [],
      fallback_used?: false
    }
  end

  defp build_pool_key(scope, provider_row_id, runtime, spec) do
    credential_id = Attrs.optional_text(Map.get(runtime, "credential_id")) || "default"
    fingerprint = connection_fingerprint(spec)

    {scope.tenant_id, scope.subject_uid, scope.scope_key, provider_row_id, credential_id,
     fingerprint}
  end

  defp connection_fingerprint(spec) do
    upstream = Attrs.get_truthy(spec, "upstream") || %{}
    url = Attrs.get_truthy(upstream, "url") || ""
    transport = Attrs.get_truthy(upstream, "transport") || %{}
    headers = Attrs.get_truthy(upstream, "headers") || []

    stable_headers =
      headers
      |> Enum.flat_map(&normalize_header_pair/1)
      |> Enum.reject(fn {name, _val} -> name in @ephemeral_ws_headers end)
      |> Enum.sort()

    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({url, stable_headers, transport}, [:deterministic])
    )
  end

  defp normalize_header_pair({name, value}),
    do: [{String.downcase(to_string(name)), to_string(value)}]

  defp normalize_header_pair([name, value]),
    do: [{String.downcase(to_string(name)), to_string(value)}]

  defp normalize_header_pair(_other), do: []

  defp checkout_opts(spec, opts) do
    opts
    |> Keyword.take([:force_fresh_socket?, :now_ms])
    |> Keyword.put(:high_reasoning?, high_reasoning_effort?(spec))
  end

  defp high_reasoning_effort?(spec) do
    request = response_request(spec)
    provider_options = response_provider_options(spec)

    effort =
      get_in(request, ["reasoning", "effort"]) ||
        get_in(provider_options, ["reasoning", "effort"]) ||
        Map.get(provider_options, "reasoningEffort")

    effort in ["xhigh", "max"]
  end

  defp effective_max_age_ms(configured_max_ms, true),
    do: min(configured_max_ms, @high_reasoning_max_reuse_age_ms)

  defp effective_max_age_ms(configured_max_ms, false), do: configured_max_ms

  defp expired_entry?(entry, now_ms, max_age_ms, idle_ttl_ms) do
    now_ms - entry.created_at_ms >= max_age_ms or
      now_ms - entry.last_used_at_ms >= idle_ttl_ms
  end

  defp schedule_sweep(interval_ms) do
    Process.send_after(self(), :sweep_expired, interval_ms)
  end

  defp close_ws_session(ws_session) when is_reference(ws_session) do
    _ = UniversalAIClient.close_ws_session(ws_session)
    :ok
  end

  defp close_ws_session(_other), do: :ok

  defp response_request(spec) do
    get_in(spec, [:response_context, :request]) ||
      get_in(spec, ["response_context", "request"]) ||
      %{}
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

  defp put_response_request(%{response_context: %{} = rc} = spec, request) do
    %{spec | response_context: Map.put(rc, :request, request)}
  end

  defp put_response_request(%{"response_context" => %{} = rc} = spec, request) do
    Map.put(spec, "response_context", Map.put(rc, "request", request))
  end

  @doc false
  @spec canonical_items_digest([map()]) :: binary()
  def canonical_items_digest(items) when is_list(items) do
    normalized = Enum.map(items, &canonical_item/1)
    :crypto.hash(:sha256, :erlang.term_to_binary(normalized, [:deterministic]))
  end

  defp input_to_item_list(items) when is_list(items), do: items

  defp input_to_item_list(text) when is_binary(text) do
    [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => text}]
      }
    ]
  end

  defp input_to_item_list(_other), do: nil

  defp canonical_item(%{} = raw_item) do
    item =
      raw_item
      |> ResponseItems.drop_ankole_item_id()
      |> CompactionHistory.strip_transient_replay_options()
      |> maybe_drop_non_replay_id()
      |> maybe_drop_completed_status()
      |> normalize_canonical_message()

    item
  end

  defp canonical_item(other), do: other

  defp maybe_drop_non_replay_id(%{"id" => id} = item) when is_binary(id) and id != "" do
    if ResponseItems.provider_replay_id_required?(item) or assistant_message_item?(item),
      do: item,
      else: Map.delete(item, "id")
  end

  defp maybe_drop_non_replay_id(item), do: Map.delete(item, "id")

  defp assistant_message_item?(%{"role" => "assistant"} = item),
    do: Map.get(item, "type", "message") == "message"

  defp assistant_message_item?(_item), do: false

  defp maybe_drop_completed_status(%{"status" => "completed"} = item),
    do: Map.delete(item, "status")

  defp maybe_drop_completed_status(item), do: item

  defp normalize_canonical_message(%{"role" => role, "content" => content} = item)
       when is_binary(role) do
    part_type = if(role == "assistant", do: "output_text", else: "input_text")

    normalized_content =
      case content do
        text when is_binary(text) ->
          [%{"type" => part_type, "text" => text}]

        parts when is_list(parts) ->
          Enum.map(parts, &normalize_canonical_part/1)

        other ->
          other
      end

    item
    |> Map.put_new("type", "message")
    |> Map.put("content", normalized_content)
  end

  defp normalize_canonical_message(item), do: item

  defp normalize_canonical_part(%{"annotations" => []} = part),
    do: Map.delete(part, "annotations")

  defp normalize_canonical_part(part), do: part
end
