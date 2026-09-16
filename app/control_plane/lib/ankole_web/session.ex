defmodule AnkoleWeb.Session do
  @moduledoc """
  Browser-session references and isolated setup state under the sealed cookie.
  """
  import Plug.Conn
  alias Ankole.BrowserSessions
  alias Ankole.Principals.HumanAccess

  @browser_key :browser_session
  @setup_ttl 24 * 60 * 60
  @state_ttl 10 * 60
  @legacy_keys [
    :admin_session,
    :oauth_session,
    :admin_oidc_state,
    :oauth_oidc_state,
    :oauth_authorization,
    :local_password_change
  ]

  def browser_reference(conn), do: get_session(conn, @browser_key)

  def ensure_browser(conn) do
    case BrowserSessions.get(browser_reference(conn)) do
      {:ok, _} ->
        conn

      {:error, :browser_session_expired} ->
        {:ok, browser} = BrowserSessions.create()

        conn
        |> clear_legacy_auth()
        |> put_session(@browser_key, BrowserSessions.reference(browser))
    end
  end

  def begin_login(conn, purpose, request) do
    conn = ensure_browser(conn)

    with {:ok, transaction} <-
           BrowserSessions.begin_login(browser_reference(conn), purpose, request) do
      {:ok, conn, transaction}
    end
  end

  def login_transaction(conn, id), do: BrowserSessions.login(browser_reference(conn), id)

  def complete_login(conn, id, auth, before_commit \\ fn -> :ok end) do
    with {:ok, %{browser: browser, transaction: transaction}} <-
           BrowserSessions.complete_login(browser_reference(conn), id, auth, before_commit) do
      Plug.CSRFProtection.delete_csrf_token()

      conn =
        conn
        |> configure_session(renew: true)
        |> clear_legacy_auth()
        |> put_session(@browser_key, BrowserSessions.reference(browser))

      {:ok, conn, transaction}
    end
  end

  @doc """
  Opens the Console context after the isolated setup flow verifies its first administrator.
  Normal logins must complete the transaction that started before credential verification.
  """
  def put_admin_session(conn, attrs) do
    attrs = stringify_keys(attrs)

    with {:ok, version} <- HumanAccess.current_version(attrs["principal_uid"]),
         {:ok, conn, transaction} <- begin_login(conn, :console, %{}),
         {:ok, _} <-
           BrowserSessions.bind_provider(
             browser_reference(conn),
             transaction.id,
             attrs["provider_id"]
           ),
         {:ok, conn, _} <-
           complete_login(conn, transaction.id, Map.put(attrs, "access_version", version)) do
      conn
    else
      {:error, reason} -> raise "Cannot establish setup authentication: #{inspect(reason)}"
    end
  end

  def admin_session(conn), do: BrowserSessions.authentication(browser_reference(conn), :console)
  def oauth_session(conn), do: BrowserSessions.authentication(browser_reference(conn), :oauth)

  def logout(conn) do
    case BrowserSessions.logout(browser_reference(conn)) do
      {:ok, _} -> {:ok, drop_browser(conn)}
      {:error, :browser_session_expired} -> {:error, :browser_session_expired}
      error -> error
    end
  end

  def clear_admin_session(conn) do
    case logout(conn) do
      {:ok, conn} -> conn
      {:error, :browser_session_expired} -> drop_browser(conn)
    end
  end

  defp drop_browser(conn) do
    Plug.CSRFProtection.delete_csrf_token()
    conn |> configure_session(renew: true) |> delete_session(@browser_key) |> clear_legacy_auth()
  end

  defp clear_legacy_auth(conn), do: Enum.reduce(@legacy_keys, conn, &delete_session(&2, &1))

  def put_setup_session(conn), do: put_expiring_session(conn, :setup_session, %{}, @setup_ttl)

  def setup_session_active?(conn),
    do: not is_nil(active_payload(get_session(conn, :setup_session)))

  def clear_setup_session(conn) do
    conn
    |> delete_session(:setup_session)
    |> delete_session(:setup_oidc_state)
    |> delete_session(:setup_brain_packs)
  end

  def put_setup_brain_packs(conn, packs) when is_list(packs),
    do: put_expiring_session(conn, :setup_brain_packs, %{packs: packs}, @setup_ttl)

  def setup_brain_packs(conn) do
    case active_payload(get_session(conn, :setup_brain_packs)) do
      %{"packs" => packs} when is_list(packs) -> packs
      _ -> []
    end
  end

  def put_setup_oidc_state(conn, attrs),
    do: put_expiring_session(conn, :setup_oidc_state, attrs, @state_ttl)

  def setup_oidc_state(conn), do: active_payload(get_session(conn, :setup_oidc_state))
  def clear_setup_oidc_state(conn), do: delete_session(conn, :setup_oidc_state)

  def opaque_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  def safe_return_to(value) when is_binary(value) do
    if String.starts_with?(value, "/") and not String.starts_with?(value, ["//", "/\\"]),
      do: value,
      else: "/console"
  end

  def safe_return_to(_), do: "/console"

  defp put_expiring_session(conn, key, attrs, ttl) do
    now = System.system_time(:second)

    put_session(
      conn,
      key,
      attrs |> stringify_keys() |> Map.merge(%{"issued_at" => now, "expires_at" => now + ttl})
    )
  end

  defp active_payload(%{"expires_at" => expiry} = payload) when is_integer(expiry) do
    if expiry > System.system_time(:second), do: payload
  end

  defp active_payload(_), do: nil
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
