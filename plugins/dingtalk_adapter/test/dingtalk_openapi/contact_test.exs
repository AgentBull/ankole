defmodule DingTalkOpenAPI.ContactTest do
  # async: false — seeds a shared-ETS app token.
  use ExUnit.Case, async: false

  alias DingTalkOpenAPI.{Client, Contact}

  setup do
    client =
      Client.new(
        client_id: "ding-contact",
        client_secret: "secret",
        oapi_base_url: "https://oapi.dingtalk.test",
        req_options: [plug: {Req.Test, __MODULE__}]
      )

    key = {:app, Client.cache_namespace(client)}

    :ets.insert(
      DingTalkOpenAPI.TokenStore.table(),
      {key, "atok", System.monotonic_time(:millisecond) + :timer.hours(1)}
    )

    on_exit(fn -> :ets.delete(DingTalkOpenAPI.TokenStore.table(), key) end)

    %{client: client}
  end

  test "list_sub_departments posts the dept_id and unwraps the department list", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/topapi/v2/department/listsub"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Torque.decode!(body) == %{"dept_id" => 1}
      Req.Test.json(conn, %{"errcode" => 0, "result" => [%{"dept_id" => 2}, %{"dept_id" => 3}]})
    end)

    assert {:ok, [%{"dept_id" => 2}, %{"dept_id" => 3}]} = Contact.list_sub_departments(client)
  end

  test "get_user unwraps the result profile", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/topapi/v2/user/get"
      Req.Test.json(conn, %{"errcode" => 0, "result" => %{"userid" => "u1", "name" => "Ada"}})
    end)

    assert {:ok, %{"userid" => "u1", "name" => "Ada"}} = Contact.get_user(client, "u1")
  end

  test "stream_department_users follows the cursor across pages", %{client: client} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      page = Agent.get_and_update(counter, &{&1, &1 + 1})
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Torque.decode!(body)
      assert decoded["dept_id"] == 5

      case page do
        0 ->
          assert decoded["cursor"] == 0
          assert decoded["size"] == 100

          Req.Test.json(conn, %{
            "errcode" => 0,
            "result" => %{
              "list" => [%{"userid" => "u1"}],
              "has_more" => true,
              "next_cursor" => 100
            }
          })

        1 ->
          assert decoded["cursor"] == 100

          Req.Test.json(conn, %{
            "errcode" => 0,
            "result" => %{"list" => [%{"userid" => "u2"}], "has_more" => false}
          })
      end
    end)

    assert [{:ok, %{"userid" => "u1"}}, {:ok, %{"userid" => "u2"}}] =
             client |> Contact.stream_department_users(5) |> Enum.to_list()
  end

  test "an incomplete directory page cannot report successful completion", %{client: client} do
    for result <- [
          %{"list" => [], "has_more" => true},
          %{"list" => [], "has_more" => true, "next_cursor" => 0},
          %{"list" => [], "has_more" => true, "next_cursor" => "100"},
          %{"list" => [], "has_more" => "false"},
          %{"has_more" => false}
        ] do
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{"errcode" => 0, "result" => result}))

      assert [{:error, %DingTalkOpenAPI.Error{reason: :unexpected_shape}}] =
               client |> Contact.stream_department_users(5) |> Enum.to_list()
    end
  end

  test "a cursor cycle returns an error after the last valid page", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      cursor = Torque.decode!(body)["cursor"]

      Req.Test.json(conn, %{
        "errcode" => 0,
        "result" => %{
          "list" => [%{"userid" => to_string(cursor)}],
          "has_more" => true,
          "next_cursor" => if(cursor == 0, do: 100, else: 0)
        }
      })
    end)

    assert [
             {:ok, %{"userid" => "0"}},
             {:error, %DingTalkOpenAPI.Error{reason: :unexpected_shape}}
           ] =
             client |> Contact.stream_department_users(5) |> Enum.to_list()
  end
end
