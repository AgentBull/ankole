defmodule Ankole.Plugins.WeComAdapter.IdentityProvider do
  @moduledoc """
  WeCom identity-provider adapter functions for Principals.

  Login chain: WWLogin page (`login_type=CorpApp`) → redirect `code` (5
  minutes, single use) → `auth/getuserinfo` with the self-built app's access
  token → enterprise `userid`. The `userid` is the canonical platform subject
  id, shared with chat inbound `from.userid` (when the bot was created by a
  super administrator), so login and chat resolve to one Principal.
  Non-members answer with `openid` and fail closed.

  Directory sync requires the contacts-sync secret (`管理工具 → 通讯录同步`):
  since 2022-06-20 the ordinary app secret returns no names or other sensitive
  member fields. The sync walks the department tree from `department/list` and
  reads members per department; there are no realtime contact events without a
  public XML callback URL, so changes converge through the host's periodic
  full sync (google-workspace precedent).
  """

  alias Ankole.AuthZ
  alias Ankole.IdentityProviders.Directory
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Logging
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.WeComAdapter.Config
  alias WeComOpenAPI.Contact
  alias WeComOpenAPI.Error
  alias WeComOpenAPI.OAuth
  alias WeComOpenAPI.TokenManager

  import MapHelpers, only: [compact_map: 1, optional_text: 2]

  @doc """
  Checks the configured credentials against the token endpoint.

  Both secrets fetch a token: a wrong secret fails as `:auth`, and a missing
  trusted-IP entry fails as `:ip_rejected` (60020) — surfaced with the console
  location to fix, since that is by far the most common setup failure.
  """
  @spec check_credentials(map()) :: :ok | {:error, term()}
  def check_credentials(config) when is_map(config) do
    with :ok <- check_token(Config.app_client(config), :app_secret),
         :ok <- check_contacts_token(config) do
      :ok
    end
  end

  defp check_contacts_token(config) do
    case Config.contacts_client(config) do
      {:ok, client} -> check_token(client, :contacts_secret)
      {:error, :contacts_secret_missing} -> :ok
    end
  end

  defp check_token(client, which) do
    case TokenManager.get_corp_token(client) do
      {:ok, _token} ->
        :ok

      {:error, %Error{reason: :ip_rejected} = error} ->
        {:error,
         {:trusted_ip_rejected, which,
          "WeCom refused this server's egress IP (60020). Add it to the trusted-IP list: " <>
            "self-built app detail page for the app secret; Management tools > Contacts sync " <>
            "for the contacts-sync secret. Changes take about one minute to apply. " <>
            to_string(Error.message(error))}}

      {:error, error} ->
        {:error, {which, error}}
    end
  end

  @doc "Builds the WWLogin page URL for login."
  @spec authorization_url(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def authorization_url(config, opts) when is_map(config) and is_list(opts) do
    with true <- get_in(config, ["oidc", "enabled"]) != false || {:error, :oidc_disabled},
         {:ok, redirect_uri} <- required_opt(opts, :redirect_uri),
         {:ok, state} <- required_opt(opts, :state) do
      {:ok,
       OAuth.authorize_url(
         corp_id: Map.fetch!(config, "corpId"),
         agentid: Map.fetch!(config, "agentId"),
         redirect_uri: redirect_uri,
         state: state
       )}
    end
  end

  @doc "Exchanges a redirect `code` for a hydrated enterprise user."
  @spec exchange_code(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def exchange_code(config, code, _opts \\ [])
      when is_map(config) and is_binary(code) do
    with true <- get_in(config, ["oidc", "enabled"]) != false || {:error, :oidc_disabled},
         {:ok, %{userid: userid}} <- OAuth.get_user_info(Config.app_client(config), code) do
      {:ok, %{user: hydrate_user(config, userid)}}
    end
  end

  # Login itself yields only the userid (the sensitive-field policy keeps the
  # profile out of the app-secret surface); the profile hydrates from the
  # contacts-sync secret when available and otherwise stays a bare userid.
  defp hydrate_user(config, userid) do
    base = %{"userid" => userid}

    with {:ok, client} <- Config.contacts_client(config),
         {:ok, user} <- Contact.get_user(client, userid) do
      Map.merge(base, user)
    else
      {:error, :contacts_secret_missing} ->
        base

      {:error, reason} ->
        Logging.warning(
          "wecom_adapter.identity_provider.contact_hydration_failed",
          "wecom adapter contact hydration failed",
          %{reason: inspect(reason)}
        )

        base
    end
  end

  @doc "Merges one WeCom contact user into the Principal platform-subject model."
  @spec upsert_user(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def upsert_user(provider_id, user, opts \\ []) when is_binary(provider_id) and is_map(user) do
    with {:ok, userid} <- user_id(user) do
      department_ids = department_ids(user)

      Directory.upsert_user(
        provider_id,
        %{
          provider: provider_id,
          external_id: userid,
          uid: userid,
          display_name: display_name(user),
          avatar_url: optional_text(user, "avatar"),
          email: optional_text(user, "biz_mail") || optional_text(user, "email"),
          mobile: normalized_mobile(user),
          job_title: optional_text(user, "position"),
          metadata:
            compact_map(%{
              "alias" => optional_text(user, "alias"),
              "status" => MapHelpers.fetch_value(user, "status"),
              "main_department" => MapHelpers.fetch_value(user, "main_department"),
              "direct_leader" => MapHelpers.fetch_value(user, "direct_leader"),
              "department_ids" => department_ids
            })
        },
        [group_external_ids: department_ids] ++ Keyword.take(opts, [:directory_group_index])
      )
    end
  end

  @doc "Runs a full directory sync, stopping on the first write or provider error."
  @spec sync_directory(String.t(), map(), keyword()) ::
          {:ok, %{users: non_neg_integer(), departments: non_neg_integer()}} | {:error, term()}
  def sync_directory(provider_id, config, _opts \\ [])
      when is_binary(provider_id) and is_map(config) do
    with {:ok, client} <- Config.contacts_client(config),
         {:ok, departments} <- Contact.list_departments(client),
         :ok <- ensure_department_groups(provider_id, departments),
         {:ok, users} <- sync_users(provider_id, client, departments) do
      {:ok, %{users: users, departments: length(departments)}}
    else
      {:error, :contacts_secret_missing} ->
        {:error, :contacts_secret_required}

      {:error, _reason} = error ->
        error
    end
  end

  # --- directory sync -------------------------------------------------------

  defp ensure_department_groups(provider_id, departments) do
    departments
    |> Enum.reject(&root_department?/1)
    |> Enum.reduce_while(:ok, fn department, :ok ->
      case ensure_department_group(provider_id, department) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Members can belong to several departments; the sync visits each department
  # once and de-duplicates by userid so every member upserts exactly once with
  # the union of memberships already carried in the profile's `department`.
  defp sync_users(provider_id, client, departments) do
    with {:ok, directory_group_index} <- AuthZ.external_directory_group_index(provider_id) do
      departments
      |> Enum.map(&raw_department_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce_while({:ok, 0, MapSet.new()}, fn dept_id, {:ok, count, seen} ->
        case Contact.list_department_users(client, dept_id) do
          {:ok, users} ->
            case upsert_unseen_users(provider_id, users, seen, directory_group_index) do
              {:ok, added, seen} -> {:cont, {:ok, count + added, seen}}
              {:error, _reason} = error -> {:halt, error}
            end

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, count, _seen} -> {:ok, count}
        {:error, _reason} = error -> error
      end
    end
  end

  defp upsert_unseen_users(provider_id, users, seen, directory_group_index) do
    Enum.reduce_while(users, {:ok, 0, seen}, fn user, {:ok, count, seen} ->
      userid = optional_text(user, "userid")

      cond do
        is_nil(userid) ->
          {:cont, {:ok, count, seen}}

        MapSet.member?(seen, userid) ->
          {:cont, {:ok, count, seen}}

        true ->
          case upsert_user(provider_id, user, directory_group_index: directory_group_index) do
            {:ok, _observed} -> {:cont, {:ok, count + 1, MapSet.put(seen, userid)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  # --- department groups ----------------------------------------------------

  defp ensure_department_group(provider_id, department) when is_map(department) do
    with {:ok, department_id} <- department_id(department),
         {:ok, _group} <-
           Directory.ensure_group(provider_id, %Directory.Group{
             external_id: department_id,
             kind: "department",
             display_name: department_display_name(department, department_id),
             parent_external_id: department_parent_id(department),
             provider_metadata: %{
               "wecom" =>
                 compact_map(%{
                   "dept_id" => department_id,
                   "parent_id" => department_parent_id(department)
                 })
             }
           }) do
      :ok
    end
  end

  defp department_display_name(department, department_id) do
    optional_text(department, "name") || "WeCom Department #{department_id}"
  end

  defp root_department?(department), do: raw_department_id(department) == 1

  defp raw_department_id(department) do
    case MapHelpers.fetch_value(department, "id") do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value)
      _other -> nil
    end
  end

  # The root department is the seed of the tree, never a real group, so a
  # first-level department's parent pointer to it is dropped.
  defp department_parent_id(department) do
    case MapHelpers.fetch_value(department, "parentid") do
      value when is_integer(value) and value > 1 -> Integer.to_string(value)
      value when is_binary(value) -> if parse_integer(value) > 1, do: value
      _other -> nil
    end
  end

  defp department_id(department) do
    case raw_department_id(department) do
      value when is_integer(value) -> {:ok, Integer.to_string(value)}
      _other -> {:error, :missing_department_id}
    end
  end

  # --- field helpers --------------------------------------------------------

  defp required_opt(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing, key}}
    end
  end

  defp user_id(user) do
    case optional_text(user, "userid") do
      value when is_binary(value) -> {:ok, value}
      nil -> {:error, :missing_user_id}
    end
  end

  defp department_ids(user) do
    user
    |> MapHelpers.fetch_value("department")
    |> case do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _other -> []
    end
  end

  defp display_name(user) do
    optional_text(user, "name") || optional_text(user, "alias") || optional_text(user, "userid")
  end

  defp normalized_mobile(user) do
    user
    |> optional_text("mobile")
    |> phone_candidates()
    |> Enum.find_value(fn candidate ->
      case NativeKernel.phone_normalize_e164(candidate) do
        normalized when is_binary(normalized) -> normalized
        {:error, _reason} -> nil
      end
    end)
  end

  defp phone_candidates(nil), do: []

  defp phone_candidates(phone) when is_binary(phone) do
    trimmed = String.trim(phone)
    digits = String.replace(trimmed, ~r/\D/, "")

    case String.length(digits) == 11 and String.starts_with?(digits, "1") do
      true -> [trimmed, "+86" <> digits]
      false -> [trimmed]
    end
  end

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> nil
    end
  end
end
