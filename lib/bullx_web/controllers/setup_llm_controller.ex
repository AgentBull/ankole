defmodule BullXWeb.SetupLLMController do
  use BullXWeb, :controller

  alias BullXAIAgent.LLM.SetupContext
  alias BullXAIAgent.Turn

  @session_key :bootstrap_activation_code_hash

  def show(conn, _params) do
    with {:ok, conn} <- require_setup_session(conn, :html) do
      conn
      |> assign(:page_title, "Setup")
      |> assign_prop(:app_name, "BullX")
      |> assign_prop(:provider_id_catalog, SetupContext.provider_id_catalog())
      |> assign_prop(:providers, SetupContext.public_providers())
      |> assign_prop(:alias_bindings, SetupContext.effective_alias_bindings())
      |> assign_prop(:check_path, ~p"/setup/llm/providers/check")
      |> assign_prop(:save_path, ~p"/setup/llm/providers")
      |> render_inertia("setup/llm/App")
    else
      {:error, %Plug.Conn{} = conn} -> conn
    end
  end

  def providers_check(conn, %{"provider" => provider}) when is_map(provider) do
    with {:ok, conn} <- require_setup_session(conn, :json),
         {:ok, attrs} <- SetupContext.normalize_provider_attrs(provider, "provider"),
         {:ok, resolved} <- SetupContext.transient_resolved_provider(attrs),
         {:ok, response} <- SetupContext.safe_generate_text("ping", model: resolved, max_tokens: 16) do
      json(conn, %{ok: true, result: %{text: Turn.extract_text(response)}})
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, [%{"kind" => _, "message" => _} | _] = errors} ->
        validation_error(conn, errors)

      {:error, %{"kind" => _, "message" => _} = error} ->
        validation_error(conn, [error])

      {:error, reason} ->
        validation_error(conn, [SetupContext.generic_error(reason)])
    end
  end

  def providers_check(conn, _params) do
    with {:ok, conn} <- require_setup_session(conn, :json) do
      validation_error(conn, [
        SetupContext.error("payload", "provider object is required", "provider")
      ])
    else
      {:error, %Plug.Conn{} = conn} -> conn
    end
  end

  def providers_save(conn, %{"providers" => providers, "alias_bindings" => bindings}) do
    with {:ok, conn} <- require_setup_session(conn, :json),
         {:ok, provider_attrs} <- SetupContext.normalize_providers(providers),
         {:ok, alias_bindings} <- SetupContext.normalize_alias_bindings(bindings, provider_attrs),
         {:ok, provider_attrs} <- SetupContext.resolve_inherited_api_keys(provider_attrs),
         {:ok, _providers} <- SetupContext.write_providers(provider_attrs),
         :ok <- SetupContext.write_alias_bindings(alias_bindings),
         :ok <- SetupContext.delete_absent_providers(provider_attrs) do
      json(conn, %{ok: true, redirect_to: "/setup/gateway"})
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, [%{"kind" => _, "message" => _} | _] = errors} ->
        validation_error(conn, errors)

      {:error, %{"kind" => _, "message" => _} = error} ->
        validation_error(conn, [error])

      {:error, reason} ->
        validation_error(conn, [SetupContext.generic_error(reason)])
    end
  end

  def providers_save(conn, _params) do
    with {:ok, conn} <- require_setup_session(conn, :json) do
      validation_error(conn, [
        SetupContext.error("payload", "providers list and alias_bindings are required", "providers")
      ])
    else
      {:error, %Plug.Conn{} = conn} -> conn
    end
  end

  defp require_setup_session(conn, response_type) do
    cond do
      not BullXAccounts.setup_required?() ->
        {:error, redirect_response(conn, response_type, ~p"/", :conflict)}

      BullXAccounts.bootstrap_activation_code_valid_for_hash?(get_session(conn, @session_key)) ->
        {:ok, conn}

      true ->
        conn =
          conn
          |> delete_session(@session_key)
          |> redirect_response(response_type, ~p"/setup/sessions/new", :unauthorized)

        {:error, conn}
    end
  end

  defp redirect_response(conn, :html, path, _status), do: redirect(conn, to: path)

  defp redirect_response(conn, :json, path, status) do
    conn
    |> put_status(status)
    |> json(%{ok: false, redirect_to: path})
  end

  defp validation_error(conn, errors) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{ok: false, errors: errors})
  end
end
