defmodule BullXWeb.SessionCookieStoreTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  @cookie_key "_bullx_test_session"
  @session_opts Plug.Session.init(
                  store: BullXWeb.SessionCookieStore,
                  key: @cookie_key,
                  key_context: @cookie_key,
                  log: false
                )

  test "stores session data in an encrypted cookie" do
    conn =
      :get
      |> conn("/")
      |> with_secret_key_base()
      |> Plug.Session.call(@session_opts)
      |> fetch_session()
      |> put_session(:activation_code_plaintext, "setup-secret")
      |> send_resp(200, "ok")

    cookie = conn |> get_resp_header("set-cookie") |> List.first()
    assert is_binary(cookie)
    refute cookie =~ "setup-secret"

    cookie_value = cookie_value(cookie)

    conn =
      :get
      |> conn("/")
      |> with_secret_key_base()
      |> put_req_header("cookie", "#{@cookie_key}=#{cookie_value}")
      |> Plug.Session.call(@session_opts)
      |> fetch_session()

    assert get_session(conn, :activation_code_plaintext) == "setup-secret"
  end

  test "malformed cookies are ignored" do
    conn =
      :get
      |> conn("/")
      |> with_secret_key_base()
      |> put_req_header("cookie", "#{@cookie_key}=not-a-bullx-session")
      |> Plug.Session.call(@session_opts)
      |> fetch_session()

    assert get_session(conn) == %{}
  end

  defp with_secret_key_base(conn) do
    %{conn | secret_key_base: secret_key_base()}
  end

  defp secret_key_base do
    case BullX.Ext.derive_key(String.duplicate("a", 64), "session_cookie_store_test") do
      key when is_binary(key) -> key
      {:error, reason} -> raise "could not derive test secret key base: #{inspect(reason)}"
    end
  end

  defp cookie_value(cookie) do
    [[_, value]] = Regex.scan(~r/#{@cookie_key}=([^;]+)/, cookie)
    value
  end
end
