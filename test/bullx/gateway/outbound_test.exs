defmodule BullX.Gateway.OutboundTest.Adapter do
  @behaviour BullX.Gateway.Adapter

  @impl true
  def config_schema, do: %{}

  @impl true
  def normalize_config(config), do: {:ok, config}

  @impl true
  def public_config(config), do: config

  @impl true
  def capabilities do
    %{
      inbound_modes: [],
      outbound_ops: [:send, :edit, :stream],
      content_kinds: [:text, :card],
      stream_strategy: stream_strategy()
    }
  end

  @impl true
  def connectivity_check(_source), do: {:ok, %{}}

  @impl true
  def source_child_spec(_source), do: :ignore

  @impl true
  def normalize_inbound(_payload, _source, _metadata), do: {:error, %{"kind" => "unsupported"}}

  @impl true
  def deliver(delivery, _source) do
    send(test_pid(), {:delivered, delivery})

    case mode() do
      :sent ->
        {:ok,
         %{
           "delivery_id" => delivery.id,
           "status" => "sent",
           "external_message_ids" => ["external_1"],
           "primary_external_id" => "external_1",
           "warnings" => []
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def stream(delivery, enumerable, _source) do
    chunks = Enum.to_list(enumerable)
    send(test_pid(), {:streamed, delivery.id, chunks})

    {:ok,
     %{
       "delivery_id" => delivery.id,
       "status" => "sent",
       "external_message_ids" => ["stream_external_1"],
       "primary_external_id" => "stream_external_1",
       "warnings" => []
     }}
  end

  def put_test_pid(pid), do: :persistent_term.put({__MODULE__, :test_pid}, pid)
  def put_mode(mode), do: :persistent_term.put({__MODULE__, :mode}, mode)

  def put_stream_strategy(strategy),
    do: :persistent_term.put({__MODULE__, :stream_strategy}, strategy)

  defp test_pid, do: :persistent_term.get({__MODULE__, :test_pid})
  defp mode, do: :persistent_term.get({__MODULE__, :mode}, :sent)
  defp stream_strategy, do: :persistent_term.get({__MODULE__, :stream_strategy}, :native)
end

defmodule BullX.Gateway.OutboundTest.Security do
  @behaviour BullX.Gateway.Security

  @impl true
  def check_inbound(_source, _input), do: :allow

  @impl true
  def sanitize_outbound(delivery, _source) do
    case mode() do
      :rewrite ->
        {:ok,
         %{
           delivery
           | content: [%{"kind" => "text", "body" => %{"text" => "sanitized"}}]
         }}

      :deny ->
        {:error, :denied_by_test}

      :passthrough ->
        {:ok, delivery}
    end
  end

  def put_mode(mode), do: :persistent_term.put({__MODULE__, :mode}, mode)
  defp mode, do: :persistent_term.get({__MODULE__, :mode}, :passthrough)
end

defmodule BullX.Gateway.OutboundTest.Router do
  @behaviour BullX.Gateway.Router

  @impl true
  def resolve(_signal), do: {:ok, []}
end

defmodule BullX.Gateway.OutboundTest do
  use BullX.DataCase, async: false

  alias BullX.Gateway.OutboundTest.Adapter
  alias BullX.Gateway.OutboundTest.Security
  alias BullX.Gateway.SourceConfig
  alias BullX.Plugins.{Extension, Registry, Spec}

  setup do
    cache_pid = GenServer.whereis(BullX.Config.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), cache_pid)

    previous_gateway = Application.get_env(:bullx, :gateway)
    previous_registry = :sys.get_state(Registry)

    Application.put_env(
      :bullx,
      :gateway,
      previous_gateway
      |> Keyword.put(:router, BullX.Gateway.OutboundTest.Router)
      |> Keyword.put(:security, Security)
      |> Keyword.put(:outbound_dispatch_poll_ms, 50)
    )

    configure_registry!()
    configure_source!()
    Adapter.put_test_pid(self())
    Adapter.put_mode(:sent)
    Adapter.put_stream_strategy(:native)
    Security.put_mode(:passthrough)

    on_exit(fn ->
      Application.put_env(:bullx, :gateway, previous_gateway)
      :sys.replace_state(Registry, fn _state -> previous_registry end)
      BullX.Config.delete("bullx.gateway.sources")
    end)

    :ok
  end

  test "deliver/1 accepts send delivery, calls adapter, and writes a succeeded receipt" do
    delivery = delivery()
    id = delivery["id"]

    assert {:ok, :accepted, ^id} = BullX.Gateway.deliver(delivery)
    assert_receive {:delivered, %{id: id, generation: 0, op: :send}}, 1_000

    assert eventually(fn -> receipt_status(id, 0) end) == "succeeded"
    assert dispatch_count(id, 0) == 0
  end

  test "terminal send failure writes a replayable dead letter and replay submits a new generation" do
    Adapter.put_mode(
      {:error, %{"kind" => "payload", "message" => "bad payload", "details" => %{}}}
    )

    delivery = delivery()
    id = delivery["id"]

    assert {:ok, :accepted, ^id} = BullX.Gateway.deliver(delivery)
    assert_receive {:delivered, %{id: ^id, generation: 0}}, 1_000

    dead_letter = eventually(fn -> dead_letter_for(id) end)
    assert dead_letter["replayable"] == true
    assert dead_letter["delivery"]["id"] == id
    assert receipt_status(id, 0) == "dead_lettered"

    Adapter.put_mode(:sent)

    assert {:ok, :accepted, ^id} = BullX.Gateway.replay_dead_letter(dead_letter["id"])
    assert_receive {:delivered, %{id: ^id, generation: 1}}, 1_000
    assert eventually(fn -> receipt_status(id, 1) end) == "succeeded"
  end

  test "deliver/1 applies outbound security sanitization before adapter dispatch" do
    Security.put_mode(:rewrite)

    delivery = delivery()
    id = delivery["id"]

    assert {:ok, :accepted, ^id} = BullX.Gateway.deliver(delivery)

    assert_receive {:delivered, %{id: ^id, content: sanitized_content}}, 1_000
    assert sanitized_content == [%{"kind" => "text", "body" => %{"text" => "sanitized"}}]
  end

  test "deliver/1 rejects outbound security denials before persistence" do
    Security.put_mode(:deny)

    delivery = delivery()
    id = delivery["id"]

    assert {:error, %{class: :security_denied}} = BullX.Gateway.deliver(delivery)
    assert dispatch_count(id, 0) == 0
  end

  test "stream delivery starts supervised execution, records chunks, and finalizes success" do
    delivery =
      delivery(%{
        "op" => "stream",
        "content" => ["hello", " world\n"]
      })

    assert {:ok, :accepted, id} = BullX.Gateway.deliver(delivery)
    assert_receive {:streamed, ^id, [%{"kind" => "text", "text" => "hello world\n"}]}, 1_000

    assert eventually(fn -> receipt_status(id, 0) end) == "succeeded"

    assert {:ok, chunks} = BullX.Gateway.stream_batches(id, 0)
    assert Enum.map(chunks, & &1["chunk"]["kind"]) == ["text"]
  end

  test "buffered stream strategy records stream batches and sends one final message" do
    Adapter.put_stream_strategy(:buffered)

    delivery =
      delivery(%{
        "op" => "stream",
        "content" => ["hello", " world\n"]
      })

    assert {:ok, :accepted, id} = BullX.Gateway.deliver(delivery)

    assert_receive {:delivered,
                    %{
                      id: ^id,
                      op: :send,
                      content: [%{"kind" => "text", "body" => %{"text" => "hello world\n"}}]
                    }},
                   1_000

    refute_receive {:streamed, ^id, _chunks}, 50
    assert eventually(fn -> receipt_status(id, 0) end) == "succeeded"
  end

  defp configure_registry! do
    extension = %Extension{
      plugin_id: "test_gateway",
      point: :"bullx.gateway.adapter",
      id: "test_gateway",
      module: Adapter
    }

    spec = %Spec{
      app: :test_gateway,
      id: "test_gateway",
      module: __MODULE__,
      api_version: 1,
      extensions: [extension]
    }

    state = %Registry{
      plugins: [spec],
      plugins_by_id: %{"test_gateway" => spec},
      enabled_ids: MapSet.new(["test_gateway"]),
      extensions: [extension]
    }

    :sys.replace_state(Registry, fn _state -> state end)
  end

  defp configure_source! do
    source = %{
      "adapter" => "test_gateway",
      "channel_id" => "main",
      "enabled" => true,
      "config" => %{},
      "outbound_retry" => %{"max_attempts" => 1}
    }

    {:ok, normalized} = SourceConfig.normalize(source)

    source =
      Map.put(source, "connectivity", %{
        "status" => "ok",
        "fingerprint" => SourceConfig.fingerprint(normalized),
        "checked_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    BullX.Config.put("bullx.gateway.sources", Jason.encode!([source]))
  end

  defp delivery(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => BullX.Ext.gen_uuid_v7(),
        "generation" => 0,
        "op" => "send",
        "channel" => %{"adapter" => "test_gateway", "channel_id" => "main"},
        "scope_id" => "scope_1",
        "content" => [%{"kind" => "text", "body" => %{"text" => "hello"}}],
        "extensions" => %{}
      },
      attrs
    )
  end

  defp receipt_status(delivery_id, generation) do
    """
    SELECT terminal_status::text
    FROM gateway_delivery_receipts
    WHERE delivery_id = $1 AND generation = $2
    """
    |> query!([delivery_id, generation])
    |> case do
      %{rows: [[status]]} -> status
      %{rows: []} -> nil
    end
  end

  defp dispatch_count(delivery_id, generation) do
    "SELECT count(*) FROM gateway_outbound_dispatches WHERE delivery_id = $1 AND generation = $2"
    |> query!([delivery_id, generation])
    |> then(fn %{rows: [[count]]} -> count end)
  end

  defp dead_letter_for(delivery_id) do
    """
    SELECT id, delivery_id, delivery, replayable, replay_count
    FROM gateway_dead_letters
    WHERE delivery_id = $1
    ORDER BY inserted_at DESC
    LIMIT 1
    """
    |> query!([delivery_id])
    |> rows()
    |> List.first()
  end

  defp eventually(fun), do: eventually(fun, 40)

  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(25)
        eventually(fun, attempts - 1)

      value ->
        value
    end
  end

  defp query!(query, params) do
    Ecto.Adapters.SQL.query!(BullX.Repo, query, Enum.map(params, &db_param/1))
  end

  defp db_param(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} ->
        case Ecto.UUID.dump(uuid) do
          {:ok, dumped} -> dumped
          :error -> value
        end

      :error ->
        value
    end
  end

  defp db_param(value), do: value

  defp rows(%{columns: columns, rows: rows}) do
    Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)
  end
end
