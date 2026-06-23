defmodule FeishuOpenAPI.PaginationTest do
  use ExUnit.Case, async: true

  alias FeishuOpenAPI.{Client, Pagination, TokenStore}

  setup do
    if :ets.info(TokenStore.table()) == :undefined do
      :ets.new(TokenStore.table(), [:named_table, :public, :set])
    end

    client =
      FeishuOpenAPI.new("cli_pg", "secret_x",
        req_options: [plug: {Req.Test, FeishuOpenAPI.PaginationTest}]
      )

    put_tenant_token(client)

    on_exit(fn ->
      if :ets.info(TokenStore.table()) != :undefined do
        delete_tenant_token(client)
      end
    end)

    {:ok, client: client}
  end

  test "iterates across pages and stops when has_more is false", %{client: client} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(FeishuOpenAPI.PaginationTest, fn conn ->
      call = Agent.get_and_update(counter, fn c -> {c, c + 1} end)
      params = URI.decode_query(conn.query_string)

      case call do
        0 ->
          assert params == %{"department_id" => "od_a"}

          Req.Test.json(conn, %{
            "code" => 0,
            "data" => %{
              "items" => [%{"user_id" => "u1"}, %{"user_id" => "u2"}],
              "has_more" => true,
              "page_token" => "p2"
            }
          })

        1 ->
          assert params == %{"department_id" => "od_a", "page_token" => "p2"}

          Req.Test.json(conn, %{
            "code" => 0,
            "data" => %{
              "items" => [%{"user_id" => "u3"}],
              "has_more" => false,
              "page_token" => ""
            }
          })
      end
    end)

    ids =
      Pagination.stream(client, "contact/v3/users", query: [department_id: "od_a"])
      |> Enum.map(fn {:ok, item} -> item["user_id"] end)

    assert ids == ["u1", "u2", "u3"]
    assert Agent.get(counter, & &1) == 2
  end

  test "Stream.take/2 short-circuits without fetching subsequent pages", %{client: client} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(FeishuOpenAPI.PaginationTest, fn conn ->
      Agent.update(counter, &(&1 + 1))

      Req.Test.json(conn, %{
        "code" => 0,
        "data" => %{
          "items" => [%{"user_id" => "u1"}, %{"user_id" => "u2"}, %{"user_id" => "u3"}],
          "has_more" => true,
          "page_token" => "p2"
        }
      })
    end)

    ids =
      Pagination.stream(client, "contact/v3/users")
      |> Stream.take(2)
      |> Enum.map(fn {:ok, item} -> item["user_id"] end)

    assert ids == ["u1", "u2"]
    assert Agent.get(counter, & &1) == 1
  end

  test "falls back to next_page_token like the official SDK", %{client: client} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(FeishuOpenAPI.PaginationTest, fn conn ->
      call = Agent.get_and_update(counter, fn c -> {c, c + 1} end)
      params = URI.decode_query(conn.query_string)

      case call do
        0 ->
          assert params == %{}

          Req.Test.json(conn, %{
            "code" => 0,
            "data" => %{
              "items" => [%{"user_id" => "u1"}],
              "has_more" => true,
              "page_token" => "",
              "next_page_token" => "np2"
            }
          })

        1 ->
          assert params == %{"page_token" => "np2"}

          Req.Test.json(conn, %{
            "code" => 0,
            "data" => %{
              "items" => [%{"user_id" => "u2"}],
              "has_more" => false,
              "next_page_token" => ""
            }
          })
      end
    end)

    ids =
      Pagination.stream(client, "contact/v3/users")
      |> Enum.map(fn {:ok, item} -> item["user_id"] end)

    assert ids == ["u1", "u2"]
    assert Agent.get(counter, & &1) == 2
  end

  test "errors are surfaced as a terminating {:error, _} element", %{client: client} do
    Req.Test.stub(FeishuOpenAPI.PaginationTest, fn conn ->
      Req.Test.json(conn, %{"code" => 99_999, "msg" => "nope"})
    end)

    assert [{:error, %FeishuOpenAPI.Error{code: 99_999}}] =
             Pagination.stream(client, "contact/v3/users") |> Enum.to_list()
  end

  test "stream!/3 raises FeishuOpenAPI.Error on a failed page fetch", %{client: client} do
    Req.Test.stub(FeishuOpenAPI.PaginationTest, fn conn ->
      Req.Test.json(conn, %{"code" => 99_999, "msg" => "nope"})
    end)

    assert_raise FeishuOpenAPI.Error, ~r/code=99999/, fn ->
      Pagination.stream!(client, "contact/v3/users") |> Enum.to_list()
    end
  end

  test "stream!/3 yields bare items on the happy path", %{client: client} do
    Req.Test.stub(FeishuOpenAPI.PaginationTest, fn conn ->
      Req.Test.json(conn, %{
        "code" => 0,
        "data" => %{
          "items" => [%{"user_id" => "u1"}, %{"user_id" => "u2"}],
          "has_more" => false,
          "page_token" => ""
        }
      })
    end)

    ids =
      Pagination.stream!(client, "contact/v3/users")
      |> Enum.map(& &1["user_id"])

    assert ids == ["u1", "u2"]
  end

  test "custom path overrides work for non-standard response shapes", %{client: client} do
    Req.Test.stub(FeishuOpenAPI.PaginationTest, fn conn ->
      Req.Test.json(conn, %{
        "code" => 0,
        "data" => %{
          "users" => [%{"id" => 1}, %{"id" => 2}],
          "next" => nil,
          "more" => false
        }
      })
    end)

    items =
      Pagination.stream(client, "custom",
        items: ["data", "users"],
        has_more: ["data", "more"],
        page_token: ["data", "next"]
      )
      |> Enum.to_list()

    assert length(items) == 2
    assert Enum.all?(items, &match?({:ok, _}, &1))
  end

  defp put_tenant_token(client, token \\ "t-token", tenant_key \\ nil) do
    :ets.insert(TokenStore.table(), {tenant_key(client, tenant_key), token, :infinity})
  end

  defp delete_tenant_token(client, tenant_key \\ nil) do
    :ets.delete(TokenStore.table(), tenant_key(client, tenant_key))
  end

  defp tenant_key(%Client{} = client, tenant_key) do
    {:tenant, Client.cache_namespace(client), tenant_key}
  end
end
