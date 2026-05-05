defmodule BullXWeb.SetupGatewayController do
  use BullXWeb, :controller

  alias BullX.Config.Accounts, as: AccountsConfig
  alias BullXGateway.{AdapterConfig, AdapterSupervisor}

  @session_key :bootstrap_activation_code_hash
  @token_salt "setup_gateway_adapter_connectivity"
  @token_max_age_seconds 600
  @accounts_match_rules_key "bullx.accounts.authn_match_rules"
  @managed_external_org_members_rule "setup.gateway.external_org_members"

  def show(conn, _params) do
    with {:ok, conn} <- require_setup_session(conn, :html) do
      conn
      |> assign(:page_title, "Setup")
      |> assign_prop(:app_name, "BullX")
      |> assign_prop(:adapter_catalog, AdapterConfig.catalog(BullXWeb.I18n.HTML.lang()))
      |> assign_prop(:adapters, AdapterConfig.load_public_entries())
      |> assign_prop(:check_path, ~p"/setup/gateway/adapters/check")
      |> assign_prop(:generated_secret_path, ~p"/setup/gateway/adapters/generated-secret")
      |> assign_prop(:save_path, ~p"/setup/gateway/adapters")
      |> assign_prop(:back_path, ~p"/setup/llm")
      |> assign_prop(:web_login_callback_origin, BullXWeb.Sessions.callback_origin())
      |> render_inertia("setup/App")
    else
      {:error, %Plug.Conn{} = conn} -> conn
    end
  end

  def check(conn, params) do
    with {:ok, conn} <- require_setup_session(conn),
         {:ok, entry_params} <- adapter_params(params),
         {:ok, entry} <-
           AdapterConfig.normalize_entry(entry_params,
             existing_entries: AdapterConfig.existing_entries()
           ),
         {:ok, result} <- AdapterConfig.connectivity_check(entry) do
      json(conn, %{
        ok: true,
        adapter: AdapterConfig.public_entry(entry, reveal_generated_secrets?: true),
        result: result,
        connectivity_token: sign_connectivity_token(conn, entry)
      })
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, [%{} | _] = errors} ->
        validation_error(conn, errors)

      {:error, %{} = error} ->
        validation_error(conn, [error])

      {:error, reason} ->
        validation_error(conn, [generic_error(reason)])
    end
  end

  def generated_secret(conn, params) do
    with {:ok, conn} <- require_setup_session(conn),
         {:ok, adapter} <- generated_secret_adapter(params),
         {:ok, path} <- generated_secret_path(params),
         true <- AdapterConfig.generated_secret_field?(adapter, path) do
      json(conn, %{ok: true, value: BullX.Config.GeneratedSecret.generate()})
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      false ->
        validation_error(conn, [
          %{
            "kind" => "config",
            "message" => "generated secret field is not supported",
            "details" => %{"field" => "path"}
          }
        ])

      {:error, %{} = error} ->
        validation_error(conn, [error])
    end
  end

  def save(conn, params) do
    with {:ok, conn} <- require_setup_session(conn),
         {:ok, adapters} <- adapters_params(params),
         existing_entries <- AdapterConfig.existing_entries(),
         {:ok, encoded, entries} <-
           AdapterConfig.encode_for_storage(adapters, existing_entries: existing_entries),
         :ok <- verify_connectivity_tokens(conn, entries, params),
         :ok <- BullX.Config.put(AdapterConfig.config_key(), encoded),
         :ok <- reconcile_gateway_adapters(entries),
         :ok <- sync_authn_match_rules(entries) do
      json(conn, %{ok: true, redirect_to: ~p"/setup/activate-owner"})
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, [%{} | _] = errors} ->
        validation_error(conn, errors)

      {:error, %{} = error} ->
        validation_error(conn, [error])

      {:error, reason} ->
        validation_error(conn, [generic_error(reason)])
    end
  end

  defp require_setup_session(conn), do: require_setup_session(conn, :json)

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

  defp adapter_params(%{"adapter" => adapter}) when is_map(adapter), do: {:ok, adapter}
  defp adapter_params(%{"entry" => adapter}) when is_map(adapter), do: {:ok, adapter}

  defp adapter_params(_params) do
    {:error,
     %{
       "kind" => "payload",
       "message" => "adapter object is required",
       "details" => %{"field" => "adapter"}
     }}
  end

  defp adapters_params(%{"adapters" => adapters}) when is_list(adapters), do: {:ok, adapters}

  defp adapters_params(_params) do
    {:error,
     [
       %{
         "kind" => "payload",
         "message" => "adapters list is required",
         "details" => %{"field" => "adapters"}
       }
     ]}
  end

  defp generated_secret_adapter(%{"adapter" => adapter}) when is_binary(adapter) do
    {:ok, adapter}
  end

  defp generated_secret_adapter(_params) do
    {:error,
     %{
       "kind" => "payload",
       "message" => "adapter is required",
       "details" => %{"field" => "adapter"}
     }}
  end

  defp generated_secret_path(%{"path" => path}) when is_list(path) do
    path =
      path
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))

    case path do
      [_ | _] -> {:ok, path}
      [] -> generated_secret_path(%{})
    end
  end

  defp generated_secret_path(_params) do
    {:error,
     %{
       "kind" => "payload",
       "message" => "path is required",
       "details" => %{"field" => "path"}
     }}
  end

  defp sign_connectivity_token(conn, entry) do
    Phoenix.Token.sign(endpoint(conn), @token_salt, %{
      "adapter" => entry["adapter"],
      "channel_id" => entry["channel_id"],
      "fingerprint" => AdapterConfig.fingerprint(entry)
    })
  end

  defp verify_connectivity_tokens(conn, entries, params) do
    tokens = Map.get(params, "connectivity_tokens", %{})

    entries
    |> Enum.filter(&Map.get(&1, "enabled", true))
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      token = connectivity_token_for(entry, tokens)

      case verify_connectivity_token(conn, entry, token) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, [error]}}
      end
    end)
  end

  defp connectivity_token_for(entry, tokens) when is_map(tokens) do
    Map.get(tokens, entry["id"]) || Map.get(entry, "connectivity_token")
  end

  defp connectivity_token_for(entry, _tokens), do: Map.get(entry, "connectivity_token")

  defp verify_connectivity_token(_conn, entry, token) when not is_binary(token) do
    {:error, stale_connectivity_error(entry)}
  end

  defp verify_connectivity_token(conn, entry, token) do
    case Phoenix.Token.verify(endpoint(conn), @token_salt, token, max_age: @token_max_age_seconds) do
      {:ok, %{"fingerprint" => fingerprint}} ->
        verify_fingerprint(entry, fingerprint)

      _other ->
        {:error, stale_connectivity_error(entry)}
    end
  end

  defp verify_fingerprint(entry, fingerprint) do
    case AdapterConfig.fingerprint(entry) do
      ^fingerprint -> :ok
      _other -> {:error, stale_connectivity_error(entry)}
    end
  end

  defp sync_authn_match_rules(entries) do
    entries
    |> external_tenant_keys()
    |> update_external_org_members_rule()
  end

  defp reconcile_gateway_adapters(entries) do
    with {:ok, specs} <- AdapterConfig.runtime_specs(entries) do
      AdapterSupervisor.reconcile_configured_channels(specs)
    end
  end

  defp external_tenant_keys(entries) do
    entries
    |> Enum.filter(&Map.get(&1, "enabled", true))
    |> Enum.flat_map(&external_tenant_key/1)
    |> Enum.uniq()
  end

  defp external_tenant_key(%{
         "authn" => %{
           "external_org_members" => %{"enabled" => true, "tenant_key" => tenant_key}
         }
       })
       when is_binary(tenant_key) and tenant_key != "",
       do: [tenant_key]

  defp external_tenant_key(_entry), do: []

  defp update_external_org_members_rule(tenant_keys) do
    rules =
      AccountsConfig.accounts_authn_match_rules!()
      |> Enum.reject(&managed_external_org_members_rule?/1)
      |> append_external_org_members_rule(tenant_keys)

    with {:ok, encoded} <- Jason.encode(rules) do
      BullX.Config.put(@accounts_match_rules_key, encoded)
    end
  end

  defp managed_external_org_members_rule?(%{"managed_by" => @managed_external_org_members_rule}),
    do: true

  defp managed_external_org_members_rule?(_rule), do: false

  defp append_external_org_members_rule(rules, []), do: rules

  defp append_external_org_members_rule(rules, tenant_keys) do
    rules ++
      [
        %{
          "result" => "allow_create_user",
          "op" => "equals_any",
          "source_path" => "metadata.tenant_key",
          "values" => tenant_keys,
          "managed_by" => @managed_external_org_members_rule
        }
      ]
  end

  defp stale_connectivity_error(entry) do
    %{
      "kind" => "connectivity",
      "message" =>
        "adapter #{entry["adapter"]}:#{entry["channel_id"]} needs a fresh connectivity check",
      "details" => %{"field" => "adapters"}
    }
  end

  defp validation_error(conn, errors) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{ok: false, errors: errors})
  end

  defp redirect_json(conn, path, status) do
    conn
    |> put_status(status)
    |> json(%{ok: false, redirect_to: path})
  end

  defp redirect_response(conn, :html, path, _status), do: redirect(conn, to: path)
  defp redirect_response(conn, :json, path, status), do: redirect_json(conn, path, status)

  defp generic_error(reason) do
    %{
      "kind" => "unknown",
      "message" => inspect(reason),
      "details" => %{}
    }
  end

  defp endpoint(%Plug.Conn{private: %{phoenix_endpoint: endpoint}}), do: endpoint
  defp endpoint(_conn), do: BullXWeb.Endpoint
end
