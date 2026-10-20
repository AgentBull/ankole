defmodule WeComOpenAPI.ContactTest do
  use ExUnit.Case, async: true

  alias WeComOpenAPI.Contact
  alias WeComOpenAPI.Corp.Client

  defp client(responder) do
    plug = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.request_path do
        "/cgi-bin/gettoken" ->
          Req.Test.json(conn, %{"errcode" => 0, "access_token" => "tok", "expires_in" => 7200})

        _other ->
          responder.(conn)
      end
    end

    Client.new(
      corp_id: "corp-#{System.unique_integer([:positive])}",
      secret: "contacts-secret",
      req_options: [plug: plug]
    )
  end

  test "list_departments returns the tree" do
    client =
      client(fn conn ->
        assert conn.request_path == "/cgi-bin/department/list"

        Req.Test.json(conn, %{
          "errcode" => 0,
          "department" => [
            %{"id" => 1, "parentid" => 0, "name" => "ACME"},
            %{"id" => 2, "parentid" => 1, "name" => "Engineering"}
          ]
        })
      end)

    assert {:ok, [%{"id" => 1}, %{"id" => 2}]} = Contact.list_departments(client)
  end

  test "list_department_users queries one department without children" do
    client =
      client(fn conn ->
        assert conn.request_path == "/cgi-bin/user/list"
        assert conn.query_params["department_id"] == "2"
        assert conn.query_params["fetch_child"] == "0"

        Req.Test.json(conn, %{
          "errcode" => 0,
          "userlist" => [%{"userid" => "alice", "name" => "Alice", "department" => [2]}]
        })
      end)

    assert {:ok, [%{"userid" => "alice"}]} = Contact.list_department_users(client, 2)
  end

  test "get_user returns the member profile" do
    client =
      client(fn conn ->
        assert conn.request_path == "/cgi-bin/user/get"
        assert conn.query_params["userid"] == "alice"
        Req.Test.json(conn, %{"errcode" => 0, "userid" => "alice", "name" => "Alice"})
      end)

    assert {:ok, %{"userid" => "alice", "name" => "Alice"}} = Contact.get_user(client, "alice")
  end
end
