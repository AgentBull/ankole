defmodule BullXWeb.SetupAuth do
  @moduledoc false

  import Phoenix.Controller
  import Plug.Conn

  alias BullX.Setup
  alias BullX.Setup.Projection

  @session_keys [
    :bootstrap_activation_code_hash,
    :bootstrap_activation_code_plaintext,
    :setup_step,
    :setup_agent_principal_id
  ]

  @spec put_no_store(Plug.Conn.t()) :: Plug.Conn.t()
  def put_no_store(conn) do
    put_resp_header(conn, "cache-control", "no-store")
  end

  @spec clear_setup_session(Plug.Conn.t()) :: Plug.Conn.t()
  def clear_setup_session(conn) do
    Enum.reduce(@session_keys, conn, &delete_session(&2, &1))
  end

  @spec put_setup_step(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  def put_setup_step(conn, step), do: put_session(conn, :setup_step, Atom.to_string(step))

  @spec put_setup_agent(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put_setup_agent(conn, principal_id) when is_binary(principal_id) do
    put_session(conn, :setup_agent_principal_id, principal_id)
  end

  @spec session_input(Plug.Conn.t()) :: map()
  def session_input(conn) do
    %{
      bootstrap_activation_code_hash: get_session(conn, :bootstrap_activation_code_hash),
      bootstrap_activation_code_plaintext:
        get_session(conn, :bootstrap_activation_code_plaintext),
      setup_step: get_session(conn, :setup_step),
      agent_principal_id: get_session(conn, :setup_agent_principal_id)
    }
  end

  @spec setup_state(Plug.Conn.t()) ::
          {:missing_session | :pending | :activation_pending | :completed, map()}
  def setup_state(conn), do: session_input(conn) |> Setup.state_for_session()

  @spec require_step(Plug.Conn.t(), atom()) ::
          {:ok, Plug.Conn.t(), map()} | {:halt, Plug.Conn.t()}
  def require_step(conn, step) do
    conn = put_no_store(conn)

    case setup_state(conn) do
      {:pending, projection} ->
        case Projection.reachable_step?(projection, step) do
          true -> {:ok, put_setup_step(conn, step), projection}
          false -> {:halt, redirect(conn, to: projection.current_path)}
        end

      {:activation_pending, projection} when step == :activate_admin ->
        {:ok, put_setup_step(conn, step), projection}

      {:activation_pending, _projection} ->
        {:halt, redirect(conn, to: "/setup/activate-admin")}

      {:completed, _projection} ->
        {:halt, conn |> clear_setup_session() |> redirect(to: "/")}

      {:missing_session, _projection} ->
        {:halt, conn |> clear_setup_session() |> redirect(to: "/setup/sessions/new")}
    end
  end

  @spec require_json_step(Plug.Conn.t(), atom() | :any) ::
          {:ok, Plug.Conn.t(), map()} | {:halt, Plug.Conn.t()}
  def require_json_step(conn, step) do
    conn = put_no_store(conn)

    case setup_state(conn) do
      {:pending, projection} ->
        json_step_result(conn, step, projection)

      {:activation_pending, projection} when step in [:activate_admin, :any] ->
        {:ok, conn, projection}

      {:activation_pending, _projection} ->
        {:halt,
         conn |> put_status(:conflict) |> json(%{ok: false, redirect_to: "/setup/activate-admin"})}

      {:completed, _projection} ->
        {:halt,
         conn
         |> clear_setup_session()
         |> put_status(:conflict)
         |> json(%{ok: false, redirect_to: "/"})}

      {:missing_session, _projection} ->
        {:halt,
         conn
         |> clear_setup_session()
         |> put_status(:unauthorized)
         |> json(%{ok: false, redirect_to: "/setup/sessions/new"})}
    end
  end

  defp json_step_result(conn, :any, projection), do: {:ok, conn, projection}

  defp json_step_result(conn, step, projection) do
    case Projection.reachable_step?(projection, step) do
      true ->
        {:ok, conn, projection}

      false ->
        {:halt,
         conn |> put_status(:conflict) |> json(%{ok: false, redirect_to: projection.current_path})}
    end
  end

  @spec assign_props(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def assign_props(conn, props) when is_map(props) do
    Enum.reduce(props, conn, fn {key, value}, acc ->
      Inertia.Controller.assign_prop(acc, key, value)
    end)
  end
end
