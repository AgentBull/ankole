defmodule AnkoleWeb.BrowserSetup do
  @moduledoc "Typed setup actions for the first administrator and installation configuration."
  use Ash.Resource,
    data_layer: Ash.DataLayer.Simple,
    domain: AnkoleWeb.BrowserAPI,
    extensions: [AshJsonApi.Resource]

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
          selected: @strings
        ]
      )

      run(fn input, _context ->
        perform_brain_packs(input.context.conn, Ankole.JSON.plain(input.arguments))
      end)
    end

    action :put_brain_packs, :map do
      constraints(fields: [packs: @strings])
      argument(:packs, {:array, :string}, allow_nil?: false)

      run(fn input, _context ->
        perform_put_brain_packs(input.context.conn, Ankole.JSON.plain(input.arguments))
      end)
    end

    action :create_local_admin, :map do
      constraints(fields: [returnTo: [type: :string, allow_nil?: false]])
      argument(:email, :string, allow_nil?: false)

      argument(:password, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [trim?: false]
      )

      argument(:display_name, :string, constraints: [max_length: 120])

      run(fn input, _context ->
        perform_create_local_admin(input.context.conn, Ankole.JSON.plain(input.arguments))
      end)
    end
  end

  alias Ankole.I18n
  alias Ankole.IdentityProviders.LocalPassword
  alias Ankole.Principals
  alias Ankole.Principals.HumanUser
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
         {:ok, enabled_ids} <- Plugins.enabled_ids() do
      enabled = MapSet.new(enabled_ids)
      plugins = Plugins.list_discovered()

      BrowserAPI.ok(conn, %{
        plugins: Enum.map(plugins, &plugin_json/1),
        enabledPluginIDs:
          plugins
          |> Enum.map(& &1.id)
          |> Enum.filter(&MapSet.member?(enabled, &1))
      })
    else
      {:error, status, reason} -> error(conn, status, reason)
      {:error, reason} -> error(conn, 500, reason)
    end
  end

  defp perform_update_plugins(conn, %{"pluginIDs" => plugin_ids}) when is_list(plugin_ids) do
    with :ok <- require_setup_session(conn),
         {:ok, enabled_ids} <- persist_enabled_plugin_ids(plugin_ids) do
      BrowserAPI.ok(conn, %{enabledPluginIDs: enabled_ids})
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
           Login.authorization_url(provider_id,
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
    with :ok <- require_setup_session(conn) do
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

      BrowserAPI.ok(conn, %{packs: packs, selected: WebSession.setup_brain_packs(conn)})
    else
      {:error, status, reason} -> error(conn, status, reason)
    end
  end

  defp perform_put_brain_packs(conn, params) do
    with :ok <- require_setup_session(conn),
         {:ok, packs} <- validate_brain_packs(params["packs"]) do
      conn
      |> WebSession.put_setup_brain_packs(packs)
      |> BrowserAPI.ok(%{packs: packs})
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

  defp perform_create_local_admin(conn, params) do
    with :ok <- require_setup_session(conn),
         {:ok, email} <- validate_local_admin_email(params["email"]),
         :ok <- validate_local_admin_password(params["password"]),
         # The session is the single owner of the pack selection; both
         # identity paths (this one and the setup OIDC callback) read it.
         brain_packs = WebSession.setup_brain_packs(conn),
         {:ok, provider} <- require_local_provider(),
         {:ok, display_name} <- validate_local_admin_display_name(params["display_name"]),
         {:ok, principal_uid} <-
           ensure_local_admin_account(email, display_name, params["password"]),
         {:ok, _root} <-
           SetupCompletion.complete_with_first_site_admin(principal_uid, brain_packs) do
      conn
      |> WebSession.clear_setup_session()
      |> WebSession.put_admin_session(%{
        principal_uid: principal_uid,
        provider_id: provider["provider_id"],
        external_id: email,
        auth_time: System.system_time(:second)
      })
      |> BrowserAPI.ok(%{returnTo: AnkoleWeb.SiteAdminConsole.path()})
    else
      {:error, status, reason} -> error(conn, status, reason)
      {:error, reason} -> error(conn, 400, reason)
    end
  end

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

  defp validate_local_admin_email(email) when is_binary(email) do
    normalized = Principals.normalize_email(email) || ""

    case Regex.match?(HumanUser.email_format(), normalized) do
      true -> {:ok, normalized}
      false -> {:error, 422, "email is invalid"}
    end
  end

  defp validate_local_admin_email(_email), do: {:error, 422, "email is invalid"}

  defp validate_local_admin_password(password) when is_binary(password) do
    case String.length(password) >= LocalPassword.local_password_min_length() do
      true -> :ok
      false -> {:error, 422, password_too_short_message()}
    end
  end

  defp validate_local_admin_password(_password), do: {:error, 422, password_too_short_message()}

  defp password_too_short_message,
    do: "password must be at least #{LocalPassword.local_password_min_length()} characters"

  defp require_local_provider do
    case LocalPassword.fetch_enabled_provider() do
      {:ok, provider} -> {:ok, provider}
      {:error, :no_local_provider} -> {:error, 409, "local identity provider is not configured"}
    end
  end

  # The setup administrator picks their own password, so the credential never
  # carries the must-change flag.
  defp ensure_local_admin_account(email, display_name, password) do
    case LocalPassword.fetch_local_login(email) do
      {:ok, %{principal: principal}} ->
        put_local_admin_password(principal.uid, password)

      {:error, :not_found} ->
        attrs = %{email: email}
        attrs = if display_name, do: Map.put(attrs, :display_name, display_name), else: attrs

        with {:ok, %{principal: principal}} <- Principals.create_human(attrs) do
          put_local_admin_password(principal.uid, password)
        end
    end
  end

  # The display name is optional; a blank one leaves the profile at its
  # email-derived default, and an over-long one is rejected like any other
  # invalid field.
  defp validate_local_admin_display_name(nil), do: {:ok, nil}

  defp validate_local_admin_display_name(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      name when byte_size(name) <= 120 -> {:ok, name}
      _ -> {:error, 422, "display name is too long"}
    end
  end

  defp validate_local_admin_display_name(_value), do: {:error, 422, "display name is invalid"}

  defp put_local_admin_password(principal_uid, password) do
    with {:ok, _credential} <- LocalPassword.set_local_password(principal_uid, password, false) do
      {:ok, principal_uid}
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
          |> Enum.map(& &1.id)
          |> Enum.filter(&MapSet.member?(selected, &1))

        with {:ok, enabled_ids} <- Plugins.put_enabled_ids(enabled_ids) do
          {:ok, enabled_ids}
        end

      ids ->
        {:error, {:unknown_plugin_ids, ids}}
    end
  end

  defp plugin_json(plugin) do
    %{
      id: plugin.id,
      displayName: plugin.display_name || default_text(plugin.id),
      description: plugin.description
    }
  end

  defp adapter_json(adapter) do
    %{
      adapterID: adapter.adapter_id,
      pluginID: adapter.plugin_id,
      displayName: adapter.display_name,
      fields: adapter.fields,
      defaultProviderID: adapter.default_provider_id
    }
  end

  defp default_text(value), do: %{"default" => value}

  defp error(_conn, status, reason), do: BrowserAPI.error(status, reason)
end
