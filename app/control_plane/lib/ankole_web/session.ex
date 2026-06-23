defmodule AnkoleWeb.Session do
  @moduledoc """
  Cookie-session helpers for setup, OIDC state, and admin login.
  """

  import Plug.Conn

  @setup_session_key :setup_session
  @setup_oidc_state_key :setup_oidc_state
  @admin_session_key :admin_session
  @admin_oidc_state_key :admin_oidc_state

  @setup_ttl_seconds 24 * 60 * 60
  @admin_ttl_seconds 24 * 60 * 60
  @oidc_state_ttl_seconds 10 * 60

  @doc """
  Stores a setup session that expires after 24 hours.
  """
  @spec put_setup_session(Plug.Conn.t()) :: Plug.Conn.t()
  def put_setup_session(conn),
    do: put_expiring_session(conn, @setup_session_key, %{}, @setup_ttl_seconds)

  @doc """
  Returns whether the setup session is active.
  """
  @spec setup_session_active?(Plug.Conn.t()) :: boolean()
  def setup_session_active?(conn), do: active_session?(get_session(conn, @setup_session_key))

  @doc """
  Clears setup-scoped session state.
  """
  @spec clear_setup_session(Plug.Conn.t()) :: Plug.Conn.t()
  def clear_setup_session(conn) do
    conn
    |> delete_session(@setup_session_key)
    |> delete_session(@setup_oidc_state_key)
  end

  @doc """
  Stores setup OIDC state.
  """
  @spec put_setup_oidc_state(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def put_setup_oidc_state(conn, attrs),
    do: put_expiring_session(conn, @setup_oidc_state_key, attrs, @oidc_state_ttl_seconds)

  @doc """
  Reads setup OIDC state if it is still active.
  """
  @spec setup_oidc_state(Plug.Conn.t()) :: map() | nil
  def setup_oidc_state(conn), do: active_payload(get_session(conn, @setup_oidc_state_key))

  @doc """
  Clears setup OIDC state.
  """
  @spec clear_setup_oidc_state(Plug.Conn.t()) :: Plug.Conn.t()
  def clear_setup_oidc_state(conn), do: delete_session(conn, @setup_oidc_state_key)

  @doc """
  Stores normal admin-login OIDC state.
  """
  @spec put_admin_oidc_state(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def put_admin_oidc_state(conn, attrs),
    do: put_expiring_session(conn, @admin_oidc_state_key, attrs, @oidc_state_ttl_seconds)

  @doc """
  Reads normal admin-login OIDC state if it is still active.
  """
  @spec admin_oidc_state(Plug.Conn.t()) :: map() | nil
  def admin_oidc_state(conn), do: active_payload(get_session(conn, @admin_oidc_state_key))

  @doc """
  Clears normal admin-login OIDC state.
  """
  @spec clear_admin_oidc_state(Plug.Conn.t()) :: Plug.Conn.t()
  def clear_admin_oidc_state(conn), do: delete_session(conn, @admin_oidc_state_key)

  @doc """
  Stores an admin session and renews the cookie session id.
  """
  @spec put_admin_session(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def put_admin_session(conn, attrs) do
    Plug.CSRFProtection.delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> put_expiring_session(@admin_session_key, attrs, @admin_ttl_seconds)
  end

  @doc """
  Reads the admin session if it is still active.
  """
  @spec admin_session(Plug.Conn.t()) :: map() | nil
  def admin_session(conn), do: active_payload(get_session(conn, @admin_session_key))

  @doc """
  Clears the admin session.
  """
  @spec clear_admin_session(Plug.Conn.t()) :: Plug.Conn.t()
  def clear_admin_session(conn) do
    conn
    |> configure_session(renew: true)
    |> delete_session(@admin_session_key)
    |> delete_session(@admin_oidc_state_key)
  end

  @doc """
  Mints a high-entropy URL-safe token for OIDC state.
  """
  @spec opaque_token() :: String.t()
  def opaque_token do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Keeps post-login redirects inside this installation.
  """
  @spec safe_return_to(term()) :: String.t()
  def safe_return_to(value) when is_binary(value) do
    case String.starts_with?(value, "/") and
           not String.starts_with?(value, ["//", "/\\"]) do
      true -> value
      false -> "/console"
    end
  end

  def safe_return_to(_value), do: "/console"

  defp put_expiring_session(conn, key, attrs, ttl_seconds) do
    now = now_seconds()

    put_session(
      conn,
      key,
      attrs
      |> stringify_keys()
      |> Map.merge(%{"issued_at" => now, "expires_at" => now + ttl_seconds})
    )
  end

  defp active_session?(payload), do: not is_nil(active_payload(payload))

  defp active_payload(%{"expires_at" => expires_at} = payload) when is_integer(expires_at) do
    case expires_at > now_seconds() do
      true -> payload
      false -> nil
    end
  end

  defp active_payload(_payload), do: nil

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp now_seconds, do: System.system_time(:second)
end
