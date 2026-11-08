defmodule Ankole.Plugins.DatabaseConnectorsTest do
  use ExUnit.Case, async: true

  alias Ankole.Plugins.DatabaseConnectors

  alias Ankole.Plugins.DatabaseConnectors.{
    Adapter,
    ClickHouse,
    MySQL,
    Network,
    PostgreSQL,
    Profile,
    Values
  }

  test "each engine declares the same six read-only tools in its own toolkit" do
    for {module, toolkit} <- [
          {PostgreSQL, "postgresql"},
          {MySQL, "mysql"},
          {ClickHouse, "clickhouse"}
        ] do
      tools = module.tools()

      assert Enum.map(tools, & &1.name) ==
               ~w(search_catalog describe_table probe_values explain query metric_query)

      assert Enum.all?(tools, &(&1.toolkit == toolkit and &1.annotations["readOnlyHint"] == true))
      assert function_exported?(module, :read_query, 4)
      assert function_exported?(module, :fetch_catalog, 3)
      assert function_exported?(module, :mark_catalog, 2)
    end

    assert [%{id: "postgresql"}, %{id: "mysql"}, %{id: "clickhouse"}] =
             DatabaseConnectors.adapter_declarations()
  end

  test "values keep precision and binary data stays JSON-safe" do
    assert Values.row([Decimal.new("12345678901234567890.01"), 9_007_199_254_740_993, 7]) ==
             ["12345678901234567890.01", "9007199254740993", 7]

    assert Values.value(~D[2026-01-02]) == "2026-01-02"
    assert Values.value(<<0, 255>>) == "\\x00ff"
    assert Values.value(%{a: [1, nil]}) == %{"a" => [1, nil]}

    assert Values.csv_line(["a,b", nil, 1, ~s(say "hi")]) ==
             ~s("a,b",,1,"say ""hi"""\r\n)
  end

  test "sensitive names, types, and exclusions are never sampled" do
    exclusions = Profile.exclusions(%{"sample_exclusions" => ["orders.status", "*.*.note"]})

    table = %{
      "schema" => "public",
      "name" => "orders",
      "columns" => [
        %{"name" => "email", "type" => "text"},
        %{"name" => "身份证号", "type" => "text"},
        %{"name" => "photo", "type" => "bytea"},
        %{"name" => "status", "type" => "text"},
        %{"name" => "note", "type" => "text"},
        %{"name" => "city", "type" => "text"}
      ]
    }

    assert Profile.mark(table, exclusions)["columns"] |> Enum.map(& &1["sensitive"]) ==
             [true, true, true, true, true, false]
  end

  test "profiles summarize samples and compare numeric text by value" do
    table = %{"columns" => [%{"name" => "amount"}, %{"name" => "city"}, %{"name" => "email"}]}
    rows = [["9.50", "Beijing"], ["10.00", "Beijing"], [nil, "Shanghai"]]

    [amount, city, email] = Profile.summarize(table, ["amount", "city"], rows, "now")["columns"]

    assert %{"min" => "9.50", "max" => "10.00", "null_fraction" => 0.3333} = amount["profile"]

    assert %{"sample_values" => ["Beijing", "Shanghai"], "low_cardinality" => true} =
             city["profile"]

    refute Map.has_key?(email, "profile")
  end

  test "cached columns follow the current exclusions and the type heuristics" do
    config = %{public_metadata: %{"sample_exclusions" => ["orders.note"]}}
    profile = %{"sample_values" => ["x"], "min" => "a", "max" => "z", "null_fraction" => 0.5}

    [orders] =
      Adapter.mark_catalog(config, [
        %{
          "schema" => "public",
          "name" => "orders",
          "columns" => [
            %{"name" => "note", "type" => "text", "sensitive" => false, "profile" => profile},
            %{"name" => "payload", "type" => "bytea", "sensitive" => false, "profile" => nil},
            %{"name" => "flagged", "type" => "text", "sensitive" => true, "profile" => nil},
            %{"name" => "city", "type" => "text", "sensitive" => false, "profile" => profile}
          ]
        }
      ])

    assert [note, payload, flagged, city] = orders["columns"]
    assert note["sensitive"] and note["profile"] == %{"null_fraction" => 0.5}
    assert payload["sensitive"] and flagged["sensitive"]
    assert %{"sensitive" => false, "profile" => ^profile} = city
  end

  test "the result consumer stops at the row and byte budgets" do
    chunks = [{["v"], [["a"], ["b"]]}, {["v"], [["c"]]}]

    assert Adapter.take_rows(chunks, 5, 1_000) == {[["a"], ["b"], ["c"]], false}
    assert Adapter.take_rows(chunks, 2, 1_000) == {[["a"], ["b"]], true}

    row_bytes = :erlang.external_size(["a"])
    assert Adapter.take_rows(chunks, 5, row_bytes * 2) == {[["a"], ["b"]], true}

    huge = [{["v"], [[String.duplicate("x", 10_000)], ["small"]]}]
    assert Adapter.take_rows(huge, 5, 1_000) == {[], true}
  end

  test "TLS verification checks the configured host name, not the resolved address" do
    endpoint = %{host: "db.example.com", tls: "verify", ca_certificate: nil}
    options = Network.ssl_options(endpoint)

    assert options[:verify] == :verify_peer
    assert options[:server_name_indication] == ~c"db.example.com"

    # `:disable` would turn off OTP's host name check, so an IP literal stays the reference name.
    assert Network.ssl_options(%{endpoint | host: "10.0.0.5"})[:server_name_indication] ==
             ~c"10.0.0.5"

    assert Network.ssl_options(%{endpoint | tls: "disable"}) == false
    assert Network.ssl_options(%{endpoint | tls: "require"}) == [verify: :verify_none]
    refute Keyword.has_key?(options, :verify_fun)
  end

  test "a rejected certificate check is recorded before the handshake fails" do
    failures = Network.tls_failures()
    endpoint = %{host: "db.example.com", tls: "verify", ca_certificate: nil}
    {verify, ^failures} = Network.ssl_options(endpoint, failures)[:verify_fun]

    assert verify.(:cert, :valid, failures) == {:valid, failures}
    assert verify.(:cert, {:extension, :any}, failures) == {:unknown, failures}
    assert catch_exit(Network.tls_failure(:pool_stopped, failures)) == :pool_stopped

    # The check runs in the TLS connection process, so the session reads the table, not a message.
    Task.await(
      Task.async(fn -> verify.(:cert, {:bad_cert, :hostname_check_failed}, failures) end)
    )

    assert {:error, %{code: "database_unavailable", reason: reason}} =
             Network.tls_failure(:pool_stopped, failures)

    assert reason =~ "hostname_check_failed"
  end

  test "a ClickHouse stream decodes rows split across chunks" do
    chunks = [~s(["x"]\n["UInt8"]\n[1]\n[), ~s(2]\n[3])]
    assert Enum.to_list(ClickHouse.decode_stream(chunks)) == [["x"], ["UInt8"], [1], [2], [3]]
  end

  test "a ClickHouse error report keeps its code and message whatever markers surround it" do
    message =
      "Code: 395. DB::Exception: boom: while executing throwIf. (FUNCTION_THROW_IF_VALUE_IS_NON_ZERO)"

    reports = [
      # ClickHouse 25.8 with http_write_exception_in_output_format=0.
      [~s(["x"]\n["UInt8"]\n[0]\n[0]\n__exception__\r\n), message <> "\n"],
      # A server that wraps the report in an exception tag.
      [
        ~s([0]\n__exception__\r\nq9ZkTw3xLbP0aVcM\r\n),
        message,
        "\r\n93 q9ZkTw3xLbP0aVcM\r\n__exception__\r\n"
      ],
      # A report whose last line has no newline.
      [~s([0]\nCode: 395. DB::Exception: boom)]
    ]

    for chunks <- reports do
      error =
        assert_raise ClickHouse.ServerError, fn ->
          Enum.to_list(ClickHouse.decode_stream(chunks))
        end

      assert error.message =~ ~r/^Code: 395\. DB::Exception: boom/
      refute error.message =~ "__exception__"
    end

    error =
      assert_raise ClickHouse.ServerError, fn ->
        Enum.to_list(ClickHouse.decode_stream([~s([0]\n__exception__\r\n)]))
      end

    assert error.message =~ "no message"
  end

  test "a ClickHouse error report reaches the caller before the connection closes" do
    closed =
      Stream.concat(
        [~s([0]\n__exception__\r\nCode: 159. DB::Exception: Timeout exceeded)],
        Stream.map([:closed], fn _ -> raise Ankole.Files.HTTP.Error, reason: :closed end)
      )

    on_report = &send(self(), {:report, IO.iodata_to_binary(&1)})

    assert_raise Ankole.Files.HTTP.Error, fn ->
      Enum.to_list(ClickHouse.decode_stream(closed, on_report))
    end

    assert_received {:report, report}
    assert report =~ "Code: 159. DB::Exception: Timeout exceeded"
  end

  test "a ClickHouse error report stops reading at 64 KiB" do
    endless =
      Stream.concat(
        ["[0]\nnot a row\n"],
        Stream.repeatedly(fn -> String.duplicate("y", 1_000) <> "\n" end)
      )

    assert_raise ClickHouse.ServerError, fn -> Enum.to_list(ClickHouse.decode_stream(endless)) end
  end

  test "identifiers are quoted for each dialect" do
    assert PostgreSQL.quote(~s(we"ird)) == ~s("we""ird")
    assert MySQL.quote("we`ird") == "`we``ird`"
    assert ClickHouse.quote("we`ird") == "`we\\`ird`"
  end
end
