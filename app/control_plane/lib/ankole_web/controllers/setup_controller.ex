defmodule AnkoleWeb.SetupController do
  @moduledoc """
  JSON endpoints used by the setup SPA before the first admin exists.

  These endpoints intentionally keep the bootstrap flow separate from normal
  admin authentication. The only long-lived result of setup is the root admin
  and the stored installation configuration.
  """

  use AnkoleWeb, :controller

  alias Ankole.I18n
  alias Ankole.Principals
  alias Ankole.Principals.HumanUser
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Setup.Bootstrap
  alias Ankole.Plugins
  alias Ankole.Setup.Completion, as: SetupCompletion
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Session, as: WebSession
  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.LocalPassword
  alias Ankole.IdentityProviders.Login

  @doc """
  Returns setup state needed before the SPA can decide which step to show.
  """
  def state(conn, _params) do
    with {:ok, completed?} <- SetupConfig.completed?(),
         {:ok, current_locale} <- I18n.configured_default_locale() do
      # `authenticated` is meaningful only while setup is incomplete: once setup is
      # done there is no setup session to hold, so it collapses to false and the
      # SPA stops offering setup steps.
      #
      # `publicBaseURL` is the origin this request arrived on, the same value the
      # OIDC redirect URI is built from. The SPA shows the resulting callback URL
      # so an operator registers it at the provider before the first login jump.
      json(conn, %{
        completed: completed?,
        authenticated: not completed? and WebSession.setup_session_active?(conn),
        currentLocale: current_locale,
        availableLocales: I18n.available_locales(),
        publicBaseURL: public_base_url(conn)
      })
    else
      {:error, reason} -> error(conn, 500, reason)
    end
  end

  @doc """
  Exchanges the bootstrap activation code for a 24-hour setup session.

  The activation code is the only credential that exists before the first admin —
  it gates who may run setup. A successful constant-time match opens a setup
  session; a wrong code also clears any partial setup session so a failed attempt
  can't leave a usable one behind.
  """
  def create_session(conn, params) do
    with {:ok, false} <- SetupConfig.completed?(),
         {:ok, expected_code} <- SetupConfig.bootstrap_activation_code(),
         submitted_code <-
           normalize_activation_code(params["activationCode"] || params["activation_code"]),
         true <- secure_equal?(submitted_code, expected_code),
         # The locale write comes after code verification so an unauthenticated
         # caller cannot change installation state.
         :ok <- maybe_put_locale(params["locale"]) do
      conn
      |> WebSession.put_setup_session()
      |> json(%{ok: true})
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

  @doc """
  Clears the short-lived setup session without touching stored setup state.
  """
  def delete_session(conn, _params) do
    conn
    |> WebSession.clear_setup_session()
    |> json(%{ok: true})
  end

  @doc """
  Reprints the current bootstrap activation code to the server log.
  """
  def create_activation_code_log_entry(conn, _params) do
    case Bootstrap.log_current_activation_code() do
      :ok -> json(conn, %{ok: true})
      {:error, :setup_completed} -> error(conn, 409, "setup already completed")
      :error -> error(conn, 503, "setup bootstrap activation code is not available")
      {:error, reason} -> error(conn, 500, reason)
    end
  end

  @doc """
  Lists discovered plugins and the currently enabled setup selection.
  """
  def plugins(conn, _params) do
    with :ok <- require_setup_session(conn),
         {:ok, enabled_ids} <- Plugins.enabled_ids() do
      enabled = MapSet.new(enabled_ids)
      plugins = Plugins.list_discovered()

      json(conn, %{
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

  @doc """
  Persists which discovered plugins should be enabled for this installation.
  """
  def update_plugins(conn, %{"pluginIDs" => plugin_ids}) when is_list(plugin_ids) do
    with :ok <- require_setup_session(conn),
         {:ok, enabled_ids} <- persist_enabled_plugin_ids(plugin_ids) do
      json(conn, %{enabledPluginIDs: enabled_ids})
    else
      {:error, status, reason} -> error(conn, status, reason)
      {:error, reason} -> error(conn, 400, reason)
    end
  end

  def update_plugins(conn, _params), do: error(conn, 422, "pluginIDs must be an array")

  @doc """
  Lists built-in and plugin identity-provider adapters available to setup.
  """
  def identity_provider_adapters(conn, _params) do
    with :ok <- require_setup_session(conn) do
      json(conn, %{
        adapters: Enum.map(IdentityProviders.list_active_adapters(), &adapter_json/1)
      })
    else
      {:error, status, reason} -> error(conn, status, reason)
    end
  end

  @doc """
  Saves an identity-provider instance during setup.
  """
  def put_identity_provider(conn, %{"provider_id" => provider_id} = params) do
    adapter_id = params["adapterID"]
    config = params["config"] || %{}
    enabled = Map.get(params, "enabled", true)

    with :ok <- require_setup_session(conn),
         true <- is_map(config) || {:error, 422, "config must be an object"},
         true <- is_boolean(enabled) || {:error, 422, "enabled must be a boolean"},
         {:ok, provider} <-
           IdentityProviders.save_provider(provider_id, adapter_id, config, enabled) do
      json(conn, provider)
    else
      {:error, status, reason} -> error(conn, status, reason)
      {:error, reason} -> error(conn, 400, reason)
    end
  end

  @doc """
  Starts setup-time OIDC and stores the state in the setup session.
  """
  def oidc_authorization(conn, %{"provider_id" => provider_id}) do
    with :ok <- require_setup_session(conn),
         {:ok, provider_id} <- IdentityProviders.normalize_provider_id(provider_id),
         {:ok, _checked} <- IdentityProviders.check_credentials(provider_id),
         state <- WebSession.opaque_token(),
         redirect_uri <- Login.oidc_redirect_uri(public_base_url(conn), provider_id),
         {:ok, authorization_url} <-
           Login.authorization_url(provider_id,
             redirect_uri: redirect_uri,
             state: state
           ) do
      conn
      |> WebSession.put_setup_oidc_state(%{
        provider_id: provider_id,
        state: state,
        redirect_uri: redirect_uri,
        return_to: "/console"
      })
      |> json(%{authorizationURL: authorization_url})
    else
      {:error, status, reason} -> error(conn, status, reason)
      {:error, reason} -> error(conn, 400, reason)
    end
  end

  @doc """
  Lists the Brain schema packs a setup can select: the always-installed base
  pack and the selectable industry packs with their seed descriptions.
  """
  def brain_packs(conn, _params) do
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

      json(conn, %{packs: packs, selected: WebSession.setup_brain_packs(conn)})
    else
      {:error, status, reason} -> error(conn, status, reason)
    end
  end

  @doc """
  Stores the industry pack selection in the setup session; completion
  materializes it whichever identity path finishes the wizard.
  """
  def put_brain_packs(conn, params) do
    with :ok <- require_setup_session(conn),
         {:ok, packs} <- validate_brain_packs(params["packs"]) do
      conn
      |> WebSession.put_setup_brain_packs(packs)
      |> json(%{packs: packs})
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

  @doc """
  Creates the local administrator account and completes setup.

  This is the local-password twin of the setup OIDC callback: it creates the
  account, opens the one-time root-admin gate, marks setup complete, and signs
  the browser in. The account upsert makes a retry after a partial failure
  land on the same principal instead of a duplicate-email error.
  """
  def create_local_admin(conn, params) do
    with :ok <- require_setup_session(conn),
         {:ok, email} <- validate_local_admin_email(params["email"]),
         :ok <- validate_local_admin_password(params["password"]),
         # The session is the single owner of the pack selection; both
         # identity paths (this one and the setup OIDC callback) read it.
         brain_packs = WebSession.setup_brain_packs(conn),
         {:ok, provider} <- require_local_provider(),
         {:ok, principal_uid} <- ensure_local_admin_account(email, params["password"]),
         {:ok, _root} <- SetupCompletion.complete_with_root_admin(principal_uid, brain_packs) do
      conn
      |> WebSession.clear_setup_session()
      |> WebSession.put_admin_session(%{
        principal_uid: principal_uid,
        provider_id: provider["provider_id"],
        external_id: email
      })
      |> json(%{returnTo: "/console"})
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
    normalized = email |> String.trim() |> String.downcase()

    case Regex.match?(HumanUser.email_format(), normalized) do
      true -> {:ok, normalized}
      false -> {:error, 422, "email is invalid"}
    end
  end

  defp validate_local_admin_email(_email), do: {:error, 422, "email is invalid"}

  defp validate_local_admin_password(password) when is_binary(password) do
    case String.length(password) >= Principals.local_password_min_length() do
      true -> :ok
      false -> {:error, 422, password_too_short_message()}
    end
  end

  defp validate_local_admin_password(_password), do: {:error, 422, password_too_short_message()}

  defp password_too_short_message,
    do: "password must be at least #{Principals.local_password_min_length()} characters"

  defp require_local_provider do
    case LocalPassword.fetch_enabled_provider() do
      {:ok, provider} -> {:ok, provider}
      {:error, :no_local_provider} -> {:error, 409, "local identity provider is not configured"}
    end
  end

  # The setup administrator picks their own password, so the credential never
  # carries the must-change flag.
  defp ensure_local_admin_account(email, password) do
    case Principals.fetch_local_login(email) do
      {:ok, %{principal: principal}} ->
        put_local_admin_password(principal.uid, password)

      {:error, :not_found} ->
        with {:ok, %{principal: principal}} <-
               Principals.create_human(%{uid: email, email: email}) do
          put_local_admin_password(principal.uid, password)
        end
    end
  end

  defp put_local_admin_password(principal_uid, password) do
    with {:ok, _credential} <- Principals.set_local_password(principal_uid, password, false) do
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

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    # `secure_compare/2` requires equal-length binaries. The explicit byte-size
    # check avoids raising while still keeping the actual comparison constant-time.
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end

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

  # Rebuilds this request's origin so the OIDC redirect URI is absolute (same
  # approach as AuthController; trusts the proxy-normalized scheme/host/port).
  defp public_base_url(conn) do
    uri = %URI{scheme: Atom.to_string(conn.scheme), host: conn.host, port: conn.port}
    URI.to_string(uri)
  end

  defp error(conn, status, reason) do
    conn
    |> put_status(status)
    |> json(%{error: message(reason)})
  end

  defp message(value) when is_binary(value), do: value
  defp message(value), do: inspect(value)
end
