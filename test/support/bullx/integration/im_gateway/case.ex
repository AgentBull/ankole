defmodule BullX.Integration.IMGateway.Case do
  @moduledoc """
  ExUnit case template for IM-gateway mock integration scenarios.

  Wires the mock channel adapter + mock LLM into the *real* inbound/mailbox/agent
  pipeline and exposes a small driver:

    * `settle/1` — synchronously drain the mailbox (`process_ready(async?: false)`
      handles both control entries and coalesced message sessions) and wait for
      any wake-spawned work to finish. Call it after emitting events to let the
      agent react.
    * `flush_ready/0` / `backdate_pending/1` — manipulate entry timing to force
      same-batch vs cross-batch coalescing deterministically (no real 6s wait).

  Tagged `:im_gateway_integration`, which `test_helper.exs` excludes from the
  default `mix test`.
  Runs `async: false` with a shared Ecto sandbox so the agent loop and any
  wake-spawned worker share the test transaction.
  """

  use ExUnit.CaseTemplate

  alias BullX.AIAgent.ACL
  alias BullX.{AuthZ, Principals, Repo}
  alias BullX.Integration.IMGateway.{MockIM, MockLLM}
  alias BullX.LLM.{Catalog, PluginProviders, Writer}
  alias BullX.MailBox
  alias BullX.MailBox.{DeliveryRule, Entry}
  alias BullX.Plugins.{Discovery, Registry}

  import Ecto.Query

  # Small coalesce window so "same 6s batch" is exercised without a real wait.
  @window_ms 80
  @max_chars 240
  @settle_timeout_ms 5_000

  # App-global supervisor for wake-spawned control-entry workers (commands,
  # edits, recalls). Already running in :test; we wait on its children so async
  # work finishes before assertions and before the sandbox owner stops.
  @worker_sup BullX.MailBox.SessionWorkerSupervisor

  using do
    quote do
      import Ecto
      import Ecto.Changeset
      import Ecto.Query

      import BullX.Integration.IMGateway.Case
      import BullX.Integration.IMGateway.MockIM

      alias BullX.Repo
      alias BullX.Integration.IMGateway.{MockIM, MockLLM}
      alias BullX.AIAgent.{Conversation, Conversations, Message}
      alias BullX.MailBox.Entry

      @moduletag :im_gateway_integration
    end
  end

  setup tags do
    # async: false -> shared sandbox, so the agent loop and any wake-spawned
    # worker share the test transaction (start_owner! + on_exit stop_owner).
    BullX.DataCase.setup_sandbox(tags)

    # Model resolution prerequisites (mirrors the agent unit tests).
    ReqLLM.Providers.initialize()
    PluginProviders.sync_builtin_extensions()
    Catalog.Cache.refresh_all()

    previous = capture_env()

    start_supervised!(MockLLM)
    start_supervised!(BullX.Integration.IMGateway.MockIM.Server)

    {:ok, plugin} =
      Discovery.discover_app(:mock_im_plugin,
        modules: [BullX.Integration.IMGateway.MockIM.Plugin]
      )

    registry = :"mock_im_registry_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Registry, plugins: [plugin], enabled_plugins: ["mock_im_plugin"], name: registry}
    )

    Application.put_env(:bullx, :llm, Keyword.put(env_list(:llm), :client, MockLLM))

    Application.put_env(:bullx, :im_gateway,
      coalesce: [window_ms: @window_ms, max_chars: @max_chars]
    )

    Application.put_env(:bullx, :im_gateway_channel_adapter_registry, registry)

    {:ok, _provider} =
      Writer.put_provider(%{
        provider_id: "openai_proxy",
        req_llm_provider: "openai",
        api_key: "sk-test",
        provider_options: %{"auth_mode" => "api_key"}
      })

    agent = create_agent!("im-gateway-integration-agent")
    delivery_rule!(agent.uid)
    users = provision_users!([:alice, :bob, :carol, :dave], agent.uid)

    # Registered after setup_sandbox -> runs (LIFO) before stop_owner, so no
    # wake-spawned worker is mid-transaction when the sandbox connection closes.
    on_exit(fn -> await_workers(System.monotonic_time(:millisecond) + 2_000) end)
    on_exit(fn -> restore_env(previous) end)

    {:ok, agent: agent, agent_uid: agent.uid, registry: registry, users: users}
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  @doc "Create an AI agent principal. `overrides` deep-merge into the default profile."
  def create_agent!(uid, overrides \\ %{}) do
    profile =
      Map.merge(
        %{
          "main_llm" => %{
            "provider_id" => "openai_proxy",
            "model" => "gpt-test",
            "context_window" => 16_000
          },
          "mission" => "Handle IM gateway integration scenarios.",
          "instructions" => "Answer briefly.",
          # High threshold: auto-compression never fires for the small messages
          # in most tests; compression is driven explicitly (/compress) or by a
          # forced provider context-overflow.
          "context" => %{"max_turns" => 4, "compression_threshold_ratio" => 0.95}
        },
        overrides
      )

    {:ok, %{principal: principal}} =
      Principals.create_agent(%{uid: uid, display_name: uid, profile: %{"ai_agent" => profile}})

    principal
  end

  @doc """
  Provision channel-bound, verified human principals for `refs` and grant each
  `invoke` on `agent_uid` (addressed messages require a verified, authorized
  caller). Returns `%{ref => principal}`.
  """
  def provision_users!(refs, agent_uid) do
    Map.new(refs, fn ref -> {ref, provision_user!(ref, agent_uid)} end)
  end

  def provision_user!(ref, agent_uid, opts \\ []) do
    external_id = external_id(ref)
    source_id = Keyword.get(opts, :source_id, "default")

    {:ok, principal, _identity} =
      Principals.ensure_human_from_channel_actor(%{
        "adapter" => "mock",
        "channel_id" => source_id,
        "external_id" => external_id,
        "trusted_realm_by_default" => true,
        "profile" => %{"display_name" => to_string(ref)},
        "metadata" => %{}
      })

    grant!(principal.uid, agent_uid)
    principal
  end

  def grant!(principal_uid, agent_uid, action \\ "invoke") do
    {:ok, _grant} =
      AuthZ.create_permission_grant(%{
        principal_uid: principal_uid,
        resource_pattern: ACL.resource(agent_uid),
        action: action
      })

    :ok
  end

  @doc "Insert a delivery rule routing every mock-channel event to `agent_uid`."
  def delivery_rule!(agent_uid, opts \\ []) do
    %DeliveryRule{}
    |> DeliveryRule.changeset(%{
      name: Keyword.get(opts, :name, "mock-route-#{agent_uid}"),
      active: true,
      priority: Keyword.get(opts, :priority, 100),
      match_expr:
        Keyword.get(opts, :match_expr, ~s(channel.adapter == "mock" && channel.id == "default")),
      agent_uid: agent_uid,
      metadata: %{}
    })
    |> Repo.insert!()
  end

  # ---------------------------------------------------------------------------
  # Driver
  # ---------------------------------------------------------------------------

  @doc """
  Drain the mailbox to quiescence for deterministic pipeline assertions.

  This helper intentionally skips the real coalesce delay and calls
  `process_ready/2` synchronously. Tests that need to prove async wake timing
  should use `wait_for/2` before calling `settle/1`.
  """
  def settle(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @settle_timeout_ms)
    deadline = System.monotonic_time(:millisecond) + timeout
    drain(deadline)
  end

  defp drain(deadline) do
    flush_ready()
    {:ok, _count} = MailBox.process_ready(200, async?: false)
    await_workers(deadline)

    cond do
      drained?() and no_workers?() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        ExUnit.Assertions.flunk("mailbox did not drain within timeout; remaining=#{remaining()}")

      true ->
        Process.sleep(5)
        drain(deadline)
    end
  end

  @doc "Block until `fun.()` returns truthy (used to observe async control-entry dispatch)."
  def wait_for(fun, opts \\ []) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 2_000)
    do_wait_for(fun, deadline)
  end

  defp do_wait_for(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        ExUnit.Assertions.flunk("wait_for condition was not met within timeout")

      true ->
        Process.sleep(5)
        do_wait_for(fun, deadline)
    end
  end

  defp await_workers(deadline) do
    cond do
      no_workers?() -> :ok
      System.monotonic_time(:millisecond) > deadline -> :ok
      true -> Process.sleep(2) && await_workers(deadline)
    end
  end

  defp no_workers? do
    case Process.whereis(@worker_sup) do
      nil -> true
      _pid -> Task.Supervisor.children(@worker_sup) == []
    end
  end

  @doc "Force every pending entry's `available_at` to now (skip the coalesce window)."
  def flush_ready do
    Repo.update_all(from(e in Entry, where: e.status == :pending),
      set: [available_at: DateTime.utc_now(:microsecond)]
    )

    :ok
  end

  @doc """
  Shift currently-pending entries `ms` into the past so a subsequently-emitted
  message falls outside their coalesce window (deterministic cross-batch by time).
  """
  def backdate_pending(ms) when is_integer(ms) do
    for entry <- Repo.all(from(e in Entry, where: e.status == :pending)) do
      shifted = DateTime.add(entry.inserted_at, -ms, :millisecond)

      Repo.update_all(from(e in Entry, where: e.id == ^entry.id),
        set: [inserted_at: shifted, available_at: shifted]
      )
    end

    :ok
  end

  @doc "Coalesce window (ms) configured for this suite."
  def window_ms, do: @window_ms
  @doc "Coalesce char limit configured for this suite."
  def max_chars, do: @max_chars

  defp drained?, do: remaining() == 0

  defp remaining,
    do: Repo.aggregate(from(e in Entry, where: e.status in [:pending, :leased]), :count)

  # ---------------------------------------------------------------------------
  # Env capture/restore
  # ---------------------------------------------------------------------------

  defp capture_env do
    Map.new(
      [:llm, :im_gateway, :im_gateway_channel_adapter_registry, :ai_agent],
      &{&1, Application.get_env(:bullx, &1)}
    )
  end

  defp restore_env(previous) do
    Enum.each(previous, fn
      {key, nil} -> Application.delete_env(:bullx, key)
      {key, value} -> Application.put_env(:bullx, key, value)
    end)
  end

  defp env_list(key), do: Application.get_env(:bullx, key, [])

  defp external_id(ref) when is_atom(ref), do: "ou_" <> Atom.to_string(ref)
  defp external_id(ref) when is_binary(ref), do: "ou_" <> ref
end
