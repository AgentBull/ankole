defmodule Ankole.Plugins.DingTalkAdapter.IdentityProvider do
  @moduledoc """
  DingTalk identity-provider adapter functions for Principals.

  Login chain: authorize page → `authCode` → user access token (+ `corpId`) →
  `contact/users/me` (unionId) → `topapi/user/getbyunionid` (enterprise userid) →
  `topapi/v2/user/get` (hydrate). The enterprise `userid` is the canonical
  platform subject id, shared with chat inbound `senderStaffId`, so login and chat
  resolve to one Principal.

  Directory sync walks the real DingTalk department tree (root id `1`) and pages
  users per department; contact-change events carry only id lists, so each id is
  re-queried before upsert and a missing id falls back to a full sync.
  """

  alias Ankole.AuthZ
  alias Ankole.IdentityProviders.Directory
  alias Ankole.IdentityProviders.DirectorySync
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Logging
  alias Ankole.Plugins.DingTalkAdapter.Config
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Principals
  alias DingTalkOpenAPI.Contact
  alias DingTalkOpenAPI.Event
  alias DingTalkOpenAPI.OAuth
  alias DingTalkOpenAPI.TokenManager

  import MapHelpers, only: [collect_results: 1, compact_map: 1, fetch_list: 2, optional_text: 2]

  @doc "Builds the dispatcher consumer record for one configured identity provider."
  @spec identity_consumer(String.t(), map()) :: map()
  def identity_consumer(provider_id, config)
      when is_binary(provider_id) and is_map(config) do
    %{kind: :identity_provider, provider_id: provider_id, config: config}
  end

  @doc """
  Checks the configured credentials against the DingTalk app-token endpoint.

  DingTalk resolves the app before it looks at anything else in a login request,
  and its authorization page reports an unknown app without naming the field. A
  token fetch separates a wrong Client ID or Client Secret, which fails here,
  from an app that DingTalk knows but refuses to log in through a browser.
  """
  @spec check_credentials(map()) :: :ok | {:error, term()}
  def check_credentials(config) when is_map(config) do
    case TokenManager.get_app_token(Config.client(config)) do
      {:ok, _token} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc "Builds the DingTalk authorization page URL for login."
  @spec authorization_url(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def authorization_url(config, opts) when is_map(config) and is_list(opts) do
    with {:ok, redirect_uri} <- MapHelpers.required_opt(opts, :redirect_uri),
         {:ok, state} <- MapHelpers.required_opt(opts, :state) do
      {:ok,
       OAuth.authorize_url(
         client_id: Map.fetch!(config, "clientId"),
         redirect_uri: redirect_uri,
         state: state,
         scope: get_in(config, ["oidc", "scope"]) || "openid corpid"
       )}
    end
  end

  @doc "Exchanges a redirect `authCode` for a hydrated enterprise user."
  @spec exchange_code(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def exchange_code(config, auth_code, _opts \\ [])
      when is_map(config) and is_binary(auth_code) do
    client = Config.client(config)

    with {:ok, token} <- OAuth.exchange_code(client, auth_code),
         {:ok, me} <- OAuth.me(client, token.access_token),
         {:ok, union_id} <- fetch_union_id(me),
         {:ok, userid} <- OAuth.get_userid_by_unionid(client, union_id),
         {:ok, hydrated} <- hydrate_user(client, userid, me, token) do
      {:ok, %{token: token, user: hydrated}}
    end
  end

  @doc "Merges one DingTalk contact user into the Principal platform-subject model."
  @spec upsert_user(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def upsert_user(provider_id, user, opts \\ []) when is_binary(provider_id) and is_map(user) do
    with {:ok, userid} <- user_id(user) do
      department_ids = department_ids(user)

      Directory.upsert_user(
        provider_id,
        %{
          provider: provider_id,
          external_id: userid,
          display_name: display_name(user),
          avatar_url: optional_text(user, "avatar"),
          email: optional_text(user, "org_email") || optional_text(user, "email"),
          mobile: normalized_mobile(user),
          job_title: optional_text(user, "title"),
          metadata:
            compact_map(%{
              "union_id" => optional_text(user, "unionid"),
              "job_number" => optional_text(user, "job_number"),
              "corp_id" => optional_text(user, "corp_id"),
              "admin" => MapHelpers.fetch_value(user, "admin"),
              "boss" => MapHelpers.fetch_value(user, "boss"),
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
    client = Config.client(config)

    with {:ok, department_ids} <- sync_departments(provider_id, client),
         {:ok, users} <- sync_users(provider_id, config, client, department_ids) do
      {:ok, %{users: users, departments: length(department_ids)}}
    end
  end

  @doc "Applies contact change events to every identity-provider consumer."
  @spec handle_contact_event(String.t(), Event.t(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_contact_event(event_type, %Event{} = event, consumers) do
    consumers
    |> Enum.filter(&match?(%{kind: :identity_provider}, &1))
    |> Enum.map(&handle_contact_event_for_consumer(&1, event_type, event))
    |> collect_results()
  end

  defp handle_contact_event_for_consumer(
         %{provider_id: provider_id, config: config},
         event_type,
         event
       ) do
    data = event.data || %{}

    cond do
      event_type in ["user_add_org", "user_modify_org", "user_active_org"] ->
        requery_users(provider_id, config, user_ids(data))

      event_type == "user_leave_org" ->
        # Departure is authoritative and names the departed userids. A full sync
        # only upserts (the host never sweeps absentees), so the subjects are
        # disabled directly; a guard-refused disable falls back to a full sync
        # instead of looping the event through LATER redelivery.
        disable_left_users(provider_id, user_ids(data))

      String.starts_with?(event_type, "org_dept_") ->
        enqueue_full_sync(provider_id, :department_changed)

      event_type == "org_remove" ->
        enqueue_full_sync(provider_id, :org_removed)

      String.starts_with?(event_type, "org_admin_") ->
        {:ok, %{status: :ignored_admin_change}}

      true ->
        {:ok, %{status: :ignored_unknown_contact_event}}
    end
  end

  # login helpers

  defp fetch_union_id(me) do
    case optional_text(me, "unionId") do
      union_id when is_binary(union_id) -> {:ok, union_id}
      nil -> {:error, :missing_union_id}
    end
  end

  defp hydrate_user(client, userid, me, token) do
    base =
      me
      |> Map.put("userid", userid)
      |> MapHelpers.put_present("corp_id", token.corp_id)

    case Contact.get_user(client, userid) do
      {:ok, user} ->
        {:ok, Map.merge(base, user)}

      {:error, reason} ->
        Logging.warning(
          "dingtalk_adapter.identity_provider.contact_hydration_failed",
          "dingtalk adapter contact hydration failed",
          %{reason: inspect(reason)}
        )

        {:ok, base}
    end
  end

  # directory sync

  defp sync_departments(provider_id, client) do
    walk_departments(provider_id, client, [Contact.root_department_id()], [])
  end

  defp walk_departments(_provider_id, _client, [], acc), do: {:ok, Enum.reverse(acc)}

  # BFS the tree. Each department is discovered exactly once as a child of its
  # parent (the root is the seed and is never a real group), so appending child
  # ids to the accumulator collects every non-root department without dupes.
  # Ids stay in the provider's own shape (integers) for later API calls; the
  # string form exists only at the group-naming edge.
  defp walk_departments(provider_id, client, [dept_id | rest], acc) do
    case Contact.list_sub_departments(client, dept_id) do
      {:ok, children} ->
        with :ok <- ensure_children_groups(provider_id, children) do
          child_ids = children |> Enum.map(&raw_department_id/1) |> Enum.reject(&is_nil/1)

          walk_departments(
            provider_id,
            client,
            rest ++ child_ids,
            prepend_reverse(child_ids, acc)
          )
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp raw_department_id(department) do
    case MapHelpers.fetch_value(department, "dept_id") || MapHelpers.fetch_value(department, "id") do
      value when is_integer(value) or is_binary(value) -> value
      _other -> nil
    end
  end

  defp prepend_reverse(ids, acc), do: Enum.reduce(ids, acc, &[&1 | &2])

  defp ensure_children_groups(provider_id, children) do
    Enum.reduce_while(children, :ok, fn department, :ok ->
      case ensure_department_group(provider_id, department) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp sync_users(provider_id, config, client, department_ids) do
    page_size = get_in(config, ["sync", "pageSize"]) || 50

    with {:ok, directory_group_index} <- AuthZ.external_directory_group_index(provider_id) do
      [Contact.root_department_id() | department_ids]
      |> Enum.uniq()
      |> Enum.reduce_while({:ok, 0}, fn dept_id, {:ok, count} ->
        case page_department_users(provider_id, client, dept_id, page_size, directory_group_index) do
          {:ok, added} -> {:cont, {:ok, count + added}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, count} -> {:ok, count}
        {:error, _reason} = error -> error
      end
    end
  end

  defp page_department_users(provider_id, client, dept_id, page_size, directory_group_index) do
    client
    |> Contact.stream_department_users(dept_id, size: page_size)
    |> Enum.reduce_while({:ok, 0}, fn
      {:ok, user}, {:ok, count} ->
        case upsert_user(provider_id, user, directory_group_index: directory_group_index) do
          {:ok, _observed} -> {:cont, {:ok, count + 1}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {:error, reason}, _acc ->
        {:halt, {:error, reason}}
    end)
  end

  defp disable_left_users(provider_id, []), do: enqueue_full_sync(provider_id, :user_left_org)

  defp disable_left_users(provider_id, user_ids) do
    results =
      Enum.map(user_ids, fn userid ->
        case Principals.resolve_platform_subject_uid(provider_id, userid) do
          {:ok, principal_uid} ->
            case Principals.disable_principal(principal_uid) do
              {:ok, _principal} -> :disabled
              {:error, reason} -> {:skipped, userid, reason}
            end

          # Never imported by this provider — nothing to disable.
          {:error, :not_found} ->
            :unknown_subject

          {:error, reason} ->
            {:skipped, userid, reason}
        end
      end)

    skipped = for {:skipped, userid, reason} <- results, do: {userid, reason}

    if skipped == [] do
      {:ok, %{status: :users_disabled, count: Enum.count(results, &(&1 == :disabled))}}
    else
      Logging.warning(
        "dingtalk_adapter.identity_provider.leave_disable_skipped",
        "dingtalk adapter could not disable departed users; enqueueing full sync",
        %{provider_id: provider_id, skipped: inspect(skipped)}
      )

      enqueue_full_sync(provider_id, :user_leave_disable_failed)
    end
  end

  defp requery_users(_provider_id, _config, []), do: {:ok, %{status: :no_user_ids}}

  defp requery_users(provider_id, config, user_ids) do
    client = Config.client(config)

    user_ids
    |> Enum.reduce_while({:ok, 0}, fn userid, {:ok, count} ->
      case Contact.get_user(client, userid) do
        {:ok, user} ->
          case upsert_user(provider_id, user) do
            {:ok, _observed} -> {:cont, {:ok, count + 1}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, %{reason: :not_found}} ->
          {:halt, {:enqueue_full_sync, :user_requery_missing}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, count} -> {:ok, %{status: :upserted, count: count}}
      {:enqueue_full_sync, reason} -> enqueue_full_sync(provider_id, reason)
      {:error, _reason} = error -> error
    end
  end

  # department groups

  defp ensure_department_group(provider_id, department) when is_map(department) do
    with {:ok, department_id} <- department_id(department),
         {:ok, _group} <-
           Directory.ensure_group(provider_id, %Directory.Group{
             external_id: department_id,
             kind: "department",
             display_name: department_display_name(department, department_id),
             parent_external_id: department_parent_id(department),
             provider_metadata: %{
               "dingtalk" =>
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
    optional_text(department, "name") || "DingTalk Department #{department_id}"
  end

  defp department_parent_id(department) do
    case MapHelpers.fetch_value(department, "parent_id") do
      value when is_integer(value) -> Integer.to_string(value)
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp enqueue_full_sync(provider_id, reason) do
    case DirectorySync.enqueue_sync(provider_id,
           reason: reason,
           source: "dingtalk_contact_event"
         ) do
      {:ok, _job} -> {:ok, %{status: :full_sync_enqueued, reason: reason}}
      {:error, error} -> {:error, {:full_sync_enqueue_failed, reason, error}}
    end
  end

  # field helpers

  defp user_id(user) do
    case optional_text(user, "userid") || optional_text(user, "userId") do
      value when is_binary(value) -> {:ok, value}
      nil -> {:error, :missing_user_id}
    end
  end

  defp user_ids(data) do
    (fetch_list(data, "userId") ++ fetch_list(data, "userid"))
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp department_id(department) do
    case department_id!(department) do
      value when is_binary(value) -> {:ok, value}
      nil -> {:error, :missing_department_id}
    end
  end

  defp department_id!(department) do
    case MapHelpers.fetch_value(department, "dept_id") || MapHelpers.fetch_value(department, "id") do
      value when is_integer(value) -> Integer.to_string(value)
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp department_ids(user) do
    user
    |> MapHelpers.fetch_value("dept_id_list")
    |> case do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _other -> []
    end
  end

  defp display_name(user) do
    optional_text(user, "name") || optional_text(user, "nick") || optional_text(user, "userid")
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
end
