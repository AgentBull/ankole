defmodule AnkoleWeb.SetupController do
  @moduledoc """
  JSON endpoints used by the setup SPA before the first admin exists.

  These endpoints intentionally keep the bootstrap flow separate from normal
  admin authentication. The only long-lived result of setup is the root admin
  and the stored installation configuration.
  """

  use AnkoleWeb, :controller

  alias Ankole.I18n
  alias Ankole.Plugins
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Session, as: WebSession
  alias Ankole.IdentityProviders

  @doc """
  Returns setup state needed before the SPA can decide which step to show.
  """
  def state(conn, _params) do
    with {:ok, completed?} <- SetupConfig.completed?(),
         {:ok, current_locale} <- Ankole.I18n.Config.default_locale() do
      # `authenticated` is meaningful only while setup is incomplete: once setup is
      # done there is no setup session to hold, so it collapses to false and the
      # SPA stops offering setup steps.
      json(conn, %{
        completed: completed?,
        authenticated: not completed? and WebSession.setup_session_active?(conn),
        currentLocale: current_locale,
        availableLocales: I18n.available_locales()
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
         :ok <- maybe_put_locale(params["locale"]),
         {:ok, expected_code} <- SetupConfig.bootstrap_activation_code(),
         submitted_code <-
           normalize_activation_code(params["activationCode"] || params["activation_code"]),
         true <- secure_equal?(submitted_code, expected_code) do
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
  Lists discovered plugins and the currently enabled setup selection.
  """
  def plugins(conn, _params) do
    with :ok <- require_setup_session(conn),
         {:ok, disabled_ids} <- Plugins.disabled_ids() do
      disabled = MapSet.new(disabled_ids)
      plugins = Plugins.list_discovered()

      json(conn, %{
        plugins: Enum.map(plugins, &plugin_json/1),
        enabledPluginIds:
          plugins
          |> Enum.map(& &1.id)
          |> Enum.reject(&MapSet.member?(disabled, &1))
      })
    else
      {:error, status, reason} -> error(conn, status, reason)
      {:error, reason} -> error(conn, 500, reason)
    end
  end

  @doc """
  Persists which discovered plugins should be enabled for this installation.
  """
  def update_plugins(conn, %{"pluginIds" => plugin_ids}) when is_list(plugin_ids) do
    with :ok <- require_setup_session(conn),
         {:ok, enabled_ids} <- persist_enabled_plugin_ids(plugin_ids) do
      json(conn, %{enabledPluginIds: enabled_ids})
    else
      {:error, status, reason} -> error(conn, status, reason)
      {:error, reason} -> error(conn, 400, reason)
    end
  end

  def update_plugins(conn, _params), do: error(conn, 422, "pluginIds must be an array")

  @doc """
  Lists identity-provider adapters that plugins expose to setup.
  """
  def identity_provider_adapters(conn, _params) do
    with :ok <- require_setup_session(conn) do
      json(conn, %{
        adapters: Enum.map(IdentityProviders.list_setup_adapters(), &adapter_json/1)
      })
    else
      {:error, status, reason} -> error(conn, status, reason)
    end
  end

  @doc """
  Saves an identity-provider instance during setup.
  """
  def put_identity_provider(conn, %{"provider_id" => provider_id} = params) do
    adapter_id = params["adapter"] || params["adapterId"] || params["adapter_id"]
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
         {:ok, provider_id} <- Ankole.IdentityProviders.Config.normalize_provider_id(provider_id),
         state <- WebSession.opaque_token(),
         redirect_uri <- IdentityProviders.oidc_redirect_uri(public_base_url(conn), provider_id),
         {:ok, authorization_url} <-
           IdentityProviders.authorization_url(provider_id,
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
      |> json(%{authorizationUrl: authorization_url})
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
        # AppConfigure stores disabled plugin ids, not enabled ids. The setup API
        # accepts enabled ids because that is the natural UI model.
        disabled_ids =
          plugins
          |> Enum.map(& &1.id)
          |> Enum.reject(&MapSet.member?(selected, &1))

        with {:ok, _disabled_ids} <- Plugins.put_disabled_ids(disabled_ids) do
          {:ok,
           plugins
           |> Enum.map(& &1.id)
           |> Enum.filter(&MapSet.member?(selected, &1))}
        end

      ids ->
        {:error, {:unknown_plugin_ids, ids}}
    end
  end

  defp plugin_json(plugin) do
    %{
      id: plugin.id,
      displayName: plugin.display_name || plugin.id,
      description: plugin.description,
      setupMetadata: plugin.setup_metadata
    }
  end

  defp adapter_json(adapter) do
    %{
      adapterId: adapter.adapter_id,
      pluginId: adapter.plugin_id,
      displayName: adapter.display_name,
      fields: adapter.fields,
      defaultProviderId: adapter.default_provider_id
    }
  end

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
