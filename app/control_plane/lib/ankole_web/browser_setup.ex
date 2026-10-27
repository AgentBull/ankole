defmodule AnkoleWeb.BrowserSetup do
  @moduledoc "Typed setup actions for the first administrator and installation configuration."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: AnkoleWeb.BrowserAPI,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:public)
    allow(:state, check: :public)
    allow(:create_session, check: :public)
    allow(:delete_session, check: :public)
    allow(:create_activation_code_log_entry, check: :public)
    allow(:plugins, check: :public)
    allow(:update_plugins, check: :public)
    allow(:identity_provider_adapters, check: :public)
    allow(:put_identity_provider, check: :public)
    allow(:oidc_authorization, check: :public)
    allow(:brain_packs, check: :public)
    allow(:put_brain_packs, check: :public)
    allow(:request_email_setup, check: :public)
    allow(:verify_email_setup, check: :public)
  end

  alias Ankole.Ash.Types.JSONMap
  alias AnkoleWeb.BrowserAPI

  resource do
    require_primary_key?(false)
  end

  @text [type: Ankole.Ash.Types.StringMap]
  @strings [type: {:array, :string}, allow_nil?: false]
  @provider [
    provider_id: [type: :string, allow_nil?: false],
    adapter_id: [type: :string, allow_nil?: false],
    plugin_id: [type: :string],
    config_key: [type: :string, allow_nil?: false],
    enabled: [type: :boolean, allow_nil?: false],
    config: [type: JSONMap, allow_nil?: false],
    stored_secret_paths: @strings
  ]
  json_api do
    type("browser_setup")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :state, :map do
      constraints(
        fields: [
          completed: [type: :boolean, allow_nil?: false],
          authenticated: [type: :boolean, allow_nil?: false],
          currentLocale: [type: :string, allow_nil?: false],
          availableLocales: @strings,
          publicBaseURL: [type: :string, allow_nil?: false]
        ]
      )

      run(fn input, _context ->
        perform_state(input.context.conn, Ankole.JSON.plain(input.arguments))
      end)
    end

    action :create_session, :map do
      constraints(fields: [ok: [type: :boolean, allow_nil?: false]])
      argument(:activation_code, :string, allow_nil?: false)
      argument(:locale, :string)

      run(fn input, _context ->
        perform_create_session(input.context.conn, Ankole.JSON.plain(input.arguments))
      end)
    end

    action :delete_session, :map do
      constraints(fields: [ok: [type: :boolean, allow_nil?: false]])

      run(fn input, _context ->
        perform_delete_session(input.context.conn, Ankole.JSON.plain(input.arguments))
      end)
    end

    action :create_activation_code_log_entry, :map do
      constraints(fields: [ok: [type: :boolean, allow_nil?: false]])

      run(fn input, _context ->
        perform_create_activation_code_log_entry(
          input.context.conn,
          Ankole.JSON.plain(input.arguments)
        )
      end)
    end

    action :plugins, :map do
      constraints(
        fields: [
          plugins: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  id: [type: :string, allow_nil?: false],
                  activation: [
                    type: :atom,
                    constraints: [one_of: [:optional, :always]],
                    allow_nil?: false
                  ],
                  displayName: @text,
                  description: @text
                ]
              ]
            ]
          ],
          enabledPluginIDs: @strings
        ]
      )

      run(fn input, _context ->
        perform_plugins(input.context.conn, Ankole.JSON.plain(input.arguments))
      end)
    end

    action :update_plugins, :map do
      constraints(fields: [enabledPluginIDs: @strings])
      argument(:pluginIDs, {:array, :string}, allow_nil?: false)

      run(fn input, _context ->
        perform_update_plugins(input.context.conn, Ankole.JSON.plain(input.arguments))
      end)
    end

    action :identity_provider_adapters, :map do
      constraints(
        fields: [
          adapters: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  adapterID: [type: :string, allow_nil?: false],
                  pluginID: [type: :string, allow_nil?: false],
                  displayName: @text,
                  fields: [type: {:array, Ankole.Plugins.ConfigField}, allow_nil?: false],
                  defaultProviderID: [type: :string, allow_nil?: false]
                ]
              ]
            ]
          ]
        ]
      )

      run(fn input, _context ->
        perform_identity_provider_adapters(input.context.conn, Ankole.JSON.plain(input.arguments))
      end)
    end

    action :put_identity_provider, :map do
      constraints(fields: @provider)
      argument(:provider_id, :string, allow_nil?: false)
      argument(:adapterID, :string, allow_nil?: false)
      argument(:config, JSONMap, default: %{}, allow_nil?: false)
      argument(:enabled, :boolean, default: true, allow_nil?: false)

      run(fn input, _context ->
        perform_put_identity_provider(input.context.conn, Ankole.JSON.plain(input.arguments))
      end)
    end

    action :oidc_authorization, :map do
      constraints(fields: [authorizationURL: [type: :string, allow_nil?: false]])
      argument(:provider_id, :string, allow_nil?: false)

      run(fn input, _context ->
        perform_oidc_authorization(input.context.conn, Ankole.JSON.plain(input.arguments))
      end)
    end

    action :brain_packs, :map do
      constraints(
        fields: [
          packs: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  name: [type: :string, allow_nil?: false],
                  description: [type: :string],
                  version: [type: :string],
                  required: [type: :boolean, allow_nil?: false]
                ]
              ]
            ]
          ],
          selected: @strings,
          displayName: [type: :string, allow_nil?: false],
          slug: [type: :string, allow_nil?: false]
        ]
      )

      run(fn input, _context ->
        perform_brain_packs(input.context.conn, Ankole.JSON.plain(input.arguments))
      end)
    end

    action :put_brain_packs, :map do
      constraints(
        fields: [
          packs: @strings,
          displayName: [type: :string, allow_nil?: false],
          slug: [type: :string, allow_nil?: false]
        ]
      )

      argument(:packs, {:array, :string}, allow_nil?: false)
      argument(:displayName, :string, allow_nil?: false)
      argument(:slug, :string, allow_nil?: false)

      run(fn input, _context ->
        perform_put_brain_packs(input.context.conn, Ankole.JSON.plain(input.arguments))
      end)
    end

    action :request_email_setup, :map do
      constraints(
        fields: [
          challengeID: [type: Ankole.Ash.Types.UUIDv7, allow_nil?: false]
        ]
      )

      argument(:email, :string, allow_nil?: false)
      argument(:mail, JSONMap, allow_nil?: false, sensitive?: true)
      argument(:display_name, :string, constraints: [max_length: 120])
      transaction?(false)

      run(fn input, _context ->
        perform_request_email_setup(input.context.conn, Ankole.JSON.plain(input.arguments))
      end)
    end

    action :verify_email_setup, :map do
      constraints(fields: [returnTo: [type: :string, allow_nil?: false]])
      argument(:challengeID, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
      argument(:code, :string, allow_nil?: false, sensitive?: true, constraints: [trim?: false])
      transaction?(false)

      run(fn input, _context ->
        perform_verify_email_setup(input.context.conn, Ankole.JSON.plain(input.arguments))
      end)
    end
  end

  alias Ankole.I18n
  alias Ankole.Principals
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Setup.Bootstrap
  alias Ankole.Plugins
  alias Ankole.Setup.Completion, as: SetupCompletion
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Session, as: WebSession
  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.Login

  defp perform_state(conn, _params) do
    with {:ok, completed?} <- SetupConfig.completed?(),
         {:ok, current_locale} <- I18n.configured_default_locale() do
      # `authenticated` is meaningful only while setup is incomplete: once setup is
      # done there is no setup session to hold, so it collapses to false and the
      # SPA stops offering setup steps.
      #
      # `publicBaseURL` is the origin this request arrived on, the same value the
      # OIDC redirect URI is built from. The SPA shows the resulting callback URL
      # so an operator registers it at the provider before the first login jump.
      BrowserAPI.ok(conn, %{
        completed: completed?,
        authenticated: not completed? and WebSession.setup_session_active?(conn),
        currentLocale: current_locale,
        availableLocales: I18n.available_locales(),
        publicBaseURL: AnkoleWeb.Plugs.RequestHost.origin(conn)
      })
    else
      {:error, reason} -> error(conn, 500, reason)
    end
  end

  defp perform_create_session(conn, params) do
    with {:ok, false} <- SetupConfig.completed?(),
         {:ok, expected_code} <- SetupConfig.bootstrap_activation_code(),
         submitted_code <-
           normalize_activation_code(params["activation_code"]),
         true <- Plug.Crypto.secure_compare(submitted_code, expected_code),
         # The locale write comes after code verification so an unauthenticated
         # caller cannot change installation state.
         :ok <- maybe_put_locale(params["locale"]) do
      conn
      |> WebSession.put_setup_session()
      |> BrowserAPI.ok(%{ok: true})
    else
      {:ok, true} ->
        error(conn, 409, "setup already completed")

      :error ->
        error(conn, 503, "setup bootstrap activation code is not available")

      {:error, {:unsupported_locale, _locale} = reason} ->
        error(conn, 422, reason)

      {:error, reason} ->
        error(conn, 500, reason)

      false ->
        conn
        |> WebSession.clear_setup_session()
        |> error(401, "invalid bootstrap activation code")
    end
  end

  defp perform_delete_session(conn, _params) do
    conn
    |> WebSession.clear_setup_session()
    |> BrowserAPI.ok(%{ok: true})
  end

  defp perform_create_activation_code_log_entry(conn, _params) do
    case Bootstrap.log_current_activation_code() do
      :ok -> BrowserAPI.ok(conn, %{ok: true})
      {:error, :setup_completed} -> error(conn, 409, "setup already completed")
      :error -> error(conn, 503, "setup bootstrap activation code is not available")
      {:error, reason} -> error(conn, 500, reason)
    end
  end

  defp perform_plugins(conn, _params) do
    with :ok <- require_setup_session(conn),
         {:ok, plugins} <- Ankole.ControlPlanePlugins.list() do
      BrowserAPI.ok(conn, %{
        plugins: Enum.map(plugins, &plugin_json/1),
        enabledPluginIDs: selected_plugin_ids(plugins)
      })
    else
      {:error, status, reason} -> error(conn, status, reason)
      {:error, reason} -> error(conn, 500, reason)
    end
  end

  defp perform_update_plugins(conn, %{"pluginIDs" => plugin_ids}) when is_list(plugin_ids) do
    with :ok <- require_setup_session(conn),
         {:ok, _enabled_ids} <- persist_enabled_plugin_ids(plugin_ids),
         {:ok, plugins} <- Ankole.ControlPlanePlugins.list() do
      BrowserAPI.ok(conn, %{enabledPluginIDs: selected_plugin_ids(plugins)})
    else
      {:error, status, reason} -> error(conn, status, reason)
      {:error, reason} -> error(conn, 400, reason)
    end
  end

  defp perform_identity_provider_adapters(conn, _params) do
    with :ok <- require_setup_session(conn) do
      BrowserAPI.ok(conn, %{
        adapters: Enum.map(IdentityProviders.list_active_adapters(), &adapter_json/1)
      })
    else
      {:error, status, reason} -> error(conn, status, reason)
    end
  end

  defp perform_put_identity_provider(conn, %{"provider_id" => provider_id} = params) do
    adapter_id = params["adapterID"]
    config = params["config"] || %{}
    enabled = Map.get(params, "enabled", true)

    with :ok <- require_setup_session(conn),
         {:ok, provider} <-
           IdentityProviders.save_provider(provider_id, adapter_id, config, enabled) do
      BrowserAPI.ok(conn, provider)
    else
      {:error, status, reason} -> error(conn, status, reason)
      {:error, reason} -> error(conn, 400, reason)
    end
  end

  defp perform_oidc_authorization(conn, %{"provider_id" => provider_id}) do
    with :ok <- require_setup_session(conn),
         {:ok, provider_id} <- IdentityProviders.normalize_provider_id(provider_id),
         {:ok, _checked} <- IdentityProviders.check_credentials(provider_id),
         state <- WebSession.opaque_token(),
         redirect_uri <-
           Login.oidc_redirect_uri(AnkoleWeb.Plugs.RequestHost.origin(conn), provider_id),
         {:ok, authorization_url} <-
           Ankole.Authn.Info.run(
             Ankole.Principals.ExternalIdentity,
             :enterprise,
             :authorize,
             %{provider_id: provider_id},
             redirect_uri: redirect_uri,
             nonce: state,
             state: state
           ) do
      conn
      |> WebSession.put_setup_oidc_state(%{
        provider_id: provider_id,
        state: state,
        redirect_uri: redirect_uri,
        return_to: AnkoleWeb.SiteAdminConsole.path()
      })
      |> BrowserAPI.ok(%{authorizationURL: authorization_url})
    else
      {:error, status, reason} -> error(conn, status, reason)
      {:error, reason} -> error(conn, 400, reason)
    end
  end

  defp perform_brain_packs(conn, _params) do
    with :ok <- require_setup_session(conn),
         {:ok, tenant} <- Ankole.Tenants.privileged() do
      packs =
        [SchemaPacks.base_pack() | SchemaPacks.industry_packs()]
        |> Enum.map(fn name ->
          required = name == SchemaPacks.base_pack()

          case SchemaPacks.load_seed(name) do
            {:ok, %{manifest: manifest}} ->
              %{
                name: name,
                description: manifest["description"],
                version: manifest["version"],
                required: required
              }

            {:error, _reason} ->
              %{name: name, description: nil, version: nil, required: required}
          end
        end)

      BrowserAPI.ok(conn, %{
        packs: packs,
        selected: WebSession.setup_brain_packs(conn),
        displayName: tenant.display_name,
        slug: tenant.slug
      })
    else
      {:error, status, reason} -> error(conn, status, reason)
      {:error, reason} -> error(conn, 400, reason)
    end
  end

  defp perform_put_brain_packs(conn, params) do
    with :ok <- require_setup_session(conn),
         {:ok, packs} <- validate_brain_packs(params["packs"]),
         {:ok, tenant} <- Ankole.Tenants.privileged(),
         {:ok, tenant} <-
           Ankole.Tenants.update(tenant, %{
             display_name: params["displayName"],
             slug: params["slug"]
           }) do
      conn
      |> WebSession.put_setup_brain_packs(packs)
      |> BrowserAPI.ok(%{packs: packs, displayName: tenant.display_name, slug: tenant.slug})
    else
      {:error, status, reason} -> error(conn, status, reason)
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  defp validate_brain_packs(packs) when is_list(packs) do
    with :ok <- ensure_pack_names(packs) do
      industry = SchemaPacks.industry_packs()
      packs = packs -- [SchemaPacks.base_pack()]

      case Enum.reject(packs, &(&1 in industry)) do
        [] -> {:ok, Enum.uniq(packs)}
        unknown -> {:error, "unknown brain packs: #{Enum.join(unknown, ", ")}"}
      end
    end
  end

  defp validate_brain_packs(_packs), do: {:error, "packs must be a list of pack names"}

  defp ensure_pack_names(packs) do
    if Enum.all?(packs, &is_binary/1),
      do: :ok,
      else: {:error, "packs must be a list of pack names"}
  end

  defp perform_request_email_setup(conn, params) do
    with :ok <- require_setup_session(conn),
         conn = WebSession.ensure_browser(conn),
         browser = WebSession.browser_reference(conn),
         {:ok, cipher} <-
           Ankole.SecretKeyBase.seal(Ankole.JSON.encode!(params["mail"]), "authn.setup", [
             browser["id"]
           ]),
         {:ok, sent} <-
           Ankole.Authn.Info.run(
             Ankole.Principals.SiteCredential,
             :email_otp,
             :request,
             %{
               browser: browser,
               email: params["email"],
               source: to_string(:inet.ntoa(conn.remote_ip))
             },
             purpose: "setup",
             mail: params["mail"],
             locale: I18n.negotiate_locale(Plug.Conn.get_req_header(conn, "accept-language")),
             ceremony_context: %{"mail" => cipher, "display_name" => params["display_name"]}
           ) do
      BrowserAPI.ok(conn, %{challengeID: sent.challenge_id})
    else
      {:error, status, reason} -> error(conn, status, reason)
      {:error, reason} -> AnkoleWeb.BrowserAPI.Error.login(reason)
    end
  end

  defp perform_verify_email_setup(conn, params) do
    browser = WebSession.browser_reference(conn)

    with :ok <- require_setup_session(conn),
         {:ok, completed} <-
           Ankole.Authn.Info.run(
             Ankole.Principals.SiteCredential,
             :email_otp,
             :verify,
             %{
               browser: browser,
               challenge_id: params["challengeID"],
               code: params["code"],
               source: to_string(:inet.ntoa(conn.remote_ip))
             },
             complete: fn challenge -> complete_email_setup_in_tx(conn, challenge) end
           ),
         {:ok, _} <- Ankole.AppConfigure.cache_committed_write(completed.mail_write),
         {:ok, _} <- Ankole.AppConfigure.cache_committed_write(completed.completed_write),
         :ok <- SetupConfig.delete_bootstrap_activation_code() do
      conn
      |> WebSession.clear_setup_session()
      |> WebSession.put_site_admin_session(completed.browser, completed.authentication)
      |> BrowserAPI.ok(%{returnTo: AnkoleWeb.SiteAdminConsole.path()})
    else
      {:error, status, reason} -> error(conn, status, reason)
      {:error, reason} -> AnkoleWeb.BrowserAPI.Error.login(reason)
    end
  end

  defp complete_email_setup_in_tx(conn, %{purpose: "setup"} = challenge) do
    browser = WebSession.browser_reference(conn)
    proof = Ankole.Authn.Strategies.Otp.Actions.proof(challenge)

    with {:ok, settings_json} <-
           Ankole.SecretKeyBase.unseal(challenge.ceremony_context["mail"], "authn.setup", [
             browser["id"]
           ]),
         {:ok, settings} <- Ankole.JSON.decode(settings_json),
         {:ok, %{principal: principal}} <-
           Principals.create_human_in_tx(%{
             email: challenge.target,
             display_name: challenge.ceremony_context["display_name"]
           }),
         {:ok, _} <- Principals.bind_site_credential_in_tx(principal.uid, proof),
         {:ok, {_root, completed_write}} <-
           SetupCompletion.complete_in_tx(
             principal.uid,
             WebSession.setup_brain_packs(conn)
           ),
         {:ok, mail_write} <-
           Ankole.AppConfigure.put_global_by_key_in_tx("authn.email.mail", settings),
         {:ok, completed} <-
           Ankole.BrowserSessions.authenticate_site_in_tx(
             browser,
             :console,
             "email_otp",
             %{
               challenge_id: challenge.id,
               browser_id: browser["id"]
             }
           ) do
      {:ok, Map.merge(completed, %{mail_write: mail_write, completed_write: completed_write})}
    end
  end

  defp complete_email_setup_in_tx(_conn, _challenge), do: {:error, :invalid_code}

  # Shared gate for every setup-mutating endpoint. Two conditions, both required:
  # setup must not already be complete (409 if it is — bootstrap can't run twice),
  # and the caller must hold an active setup session (401 otherwise). Returns a
  # `{:error, status, reason}` triple the actions render directly.
  defp require_setup_session(conn) do
    with {:ok, false} <- SetupConfig.completed?() do
      case WebSession.setup_session_active?(conn) do
        true -> :ok
        false -> {:error, 401, "setup session required"}
      end
    else
      {:ok, true} -> {:error, 409, "setup already completed"}
      {:error, reason} -> {:error, 500, reason}
    end
  end

  defp maybe_put_locale(nil), do: :ok
  defp maybe_put_locale(""), do: :ok

  defp maybe_put_locale(locale) when is_binary(locale) do
    case I18n.put_default_locale(locale) do
      {:ok, _locale} -> :ok
      {:error, _reason} -> {:error, {:unsupported_locale, locale}}
    end
  end

  defp maybe_put_locale(_locale), do: {:error, {:unsupported_locale, nil}}

  defp normalize_activation_code(code) when is_binary(code) do
    code
    |> String.trim()
    |> String.upcase()
  end

  defp normalize_activation_code(_code), do: ""

  defp persist_enabled_plugin_ids(plugin_ids) do
    selected = MapSet.new(plugin_ids)
    plugins = Plugins.list_discovered()
    known = MapSet.new(Enum.map(plugins, & &1.id))

    unknown =
      selected
      |> MapSet.difference(known)
      |> MapSet.to_list()

    case unknown do
      [] ->
        enabled_ids =
          plugins
          |> Enum.filter(&(&1.activation == :optional and MapSet.member?(selected, &1.id)))
          |> Enum.map(& &1.id)

        with {:ok, enabled_ids} <- Plugins.put_enabled_ids(enabled_ids) do
          {:ok, enabled_ids}
        end

      ids ->
        {:error, {:unknown_plugin_ids, ids}}
    end
  end

  defp plugin_json(plugin) do
    %{
      id: plugin["id"],
      activation: plugin["activation"],
      displayName: plugin["display_name"],
      description: plugin["description"]
    }
  end

  defp selected_plugin_ids(plugins),
    do: for(plugin <- plugins, plugin["configured_enabled"], do: plugin["id"])

  defp adapter_json(adapter) do
    %{
      adapterID: adapter.adapter_id,
      pluginID: adapter.plugin_id,
      displayName: adapter.display_name,
      fields: adapter.fields,
      defaultProviderID: adapter.default_provider_id
    }
  end

  defp error(_conn, status, reason), do: BrowserAPI.error(status, reason)
end
