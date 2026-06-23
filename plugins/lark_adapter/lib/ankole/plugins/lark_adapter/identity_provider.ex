defmodule Ankole.Plugins.LarkAdapter.IdentityProvider do
  @moduledoc """
  Lark / Feishu identity-provider adapter functions for Principals.
  """

  require Logger

  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Principals
  alias FeishuOpenAPI.Auth
  alias FeishuOpenAPI.Event
  alias FeishuOpenAPI.Pagination

  @doc """
  Builds the dispatcher consumer record for one configured identity provider.
  """
  @spec identity_consumer(String.t(), map()) :: map()
  def identity_consumer(provider_id, config) when is_binary(provider_id) and is_map(config) do
    %{kind: :identity_provider, provider_id: provider_id, config: config}
  end

  @doc """
  Builds the provider authorization URL for OIDC login.
  """
  @spec authorization_url(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def authorization_url(config, opts) when is_map(config) and is_list(opts) do
    with true <- get_in(config, ["oidc", "enabled"]) != false || {:error, :oidc_disabled},
         {:ok, redirect_uri} <- required_opt(opts, :redirect_uri),
         {:ok, state} <- required_opt(opts, :state) do
      query =
        [
          app_id: Map.fetch!(config, "appId"),
          redirect_uri: redirect_uri,
          state: state,
          scope: Enum.join(get_in(config, ["oidc", "scopes"]) || [], " ")
        ]
        |> URI.encode_query()

      {:ok, "#{Config.domain_base_url(Map.fetch!(config, "domain"))}/open-apis/authen/v1/authorize?#{query}"}
    end
  end

  @doc """
  Exchanges an OIDC code and hydrates the user with contact data when possible.
  """
  @spec exchange_code(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def exchange_code(config, code, opts \\ []) when is_map(config) and is_binary(code) do
    client = Config.client(config, Keyword.get(opts, :client_opts, []))

    with {:ok, token} <- Auth.user_access_token(client, code, redirect_uri: Keyword.get(opts, :redirect_uri)),
         {:ok, user_info} <- user_info(client, token.access_token),
         {:ok, hydrated} <- hydrate_contact_user(client, user_info) do
      {:ok, %{token: token, user: hydrated}}
    end
  end

  @doc """
  Merges one Lark contact user into the Principal platform-subject model.
  """
  @spec upsert_user(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def upsert_user(provider_id, user) when is_binary(provider_id) and is_map(user) do
    with {:ok, user_id} <- user_id(user) do
      Principals.upsert_platform_subject_human(%{
        provider: provider_id,
        external_id: user_id,
        uid: user_id,
        display_name: display_name(user),
        avatar_url: avatar_url(user),
        email: enterprise_email(user) || optional_text(user, "email"),
        mobile: normalized_mobile(user),
        job_title: optional_text(user, "job_title"),
        metadata:
          compact_map(%{
            "open_id" => optional_text(user, "open_id"),
            "union_id" => optional_text(user, "union_id"),
            "tenant_key" => optional_text(user, "tenant_key"),
            "employee_no" => optional_text(user, "employee_no"),
            "department_ids" => fetch_list(user, "department_ids")
          })
      })
    end
  end

  @doc """
  Runs a full user sync and stops on the first write or provider error.
  """
  @spec sync_users(String.t(), map(), keyword()) :: {:ok, %{users: non_neg_integer()}} | {:error, term()}
  def sync_users(provider_id, config, opts \\ []) when is_binary(provider_id) and is_map(config) do
    client = Config.client(config, Keyword.get(opts, :client_opts, []))
    page_size = get_in(config, ["sync", "pageSize"]) || 50

    client
    |> Pagination.stream("contact/v3/users",
      query: [page_size: page_size],
      items: ["data", "items"]
    )
    |> Enum.reduce_while({:ok, 0}, fn
      {:ok, user}, {:ok, count} ->
        case upsert_user(provider_id, user) do
          {:ok, _} -> {:cont, {:ok, count + 1}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {:error, reason}, _acc ->
        {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, count} -> {:ok, %{users: count}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Reads departments to verify provider access and count visible department rows.
  """
  @spec sync_departments(String.t(), map(), keyword()) ::
          {:ok, %{departments: non_neg_integer()}} | {:error, term()}
  def sync_departments(_provider_id, config, opts \\ []) when is_map(config) do
    client = Config.client(config, Keyword.get(opts, :client_opts, []))
    page_size = get_in(config, ["sync", "pageSize"]) || 50

    client
    |> Pagination.stream("contact/v3/departments",
      query: [page_size: page_size],
      items: ["data", "items"]
    )
    |> Enum.reduce_while({:ok, 0}, fn
      {:ok, _department}, {:ok, count} -> {:cont, {:ok, count + 1}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, count} -> {:ok, %{departments: count}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Applies contact change events to every identity-provider consumer.
  """
  @spec handle_contact_event(String.t(), Event.t(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_contact_event(event_type, %Event{} = event, consumers) do
    consumers
    |> Enum.filter(&match?(%{kind: :identity_provider}, &1))
    |> Enum.map(&handle_contact_event_for_consumer(&1, event_type, event))
    |> collect_results()
  end

  defp handle_contact_event_for_consumer(%{provider_id: provider_id}, event_type, %Event{} = event) do
    content = event.content || %{}

    cond do
      String.starts_with?(event_type, "contact.user.") ->
        user = fetch_map(content, "user", content)

        case user_id(user) do
          {:ok, _id} -> upsert_user(provider_id, user)
          # Some contact events omit enough user fields that an incremental merge
          # would risk writing a low-quality Principal. Asking for a full sync is
          # safer than guessing which identifier the event meant.
          {:error, _reason} -> {:ok, %{status: :full_sync_needed, reason: :missing_user_id}}
        end

      String.starts_with?(event_type, "contact.department.") ->
        {:ok, %{status: :observed_department_event, event_type: event_type}}

      event_type == "contact.scope.updated_v3" ->
        {:ok, %{status: :full_sync_needed, reason: :contact_scope_updated}}

      true ->
        {:ok, %{status: :ignored_unknown_contact_event}}
    end
  end

  defp user_info(client, access_token) do
    FeishuOpenAPI.get(client, "/open-apis/authen/v1/user_info", user_access_token: access_token)
  end

  defp hydrate_contact_user(client, user_info) when is_map(user_info) do
    user_id =
      optional_text(user_info, "user_id") ||
        get_in(user_info, ["data", "user_id"]) ||
        get_in(user_info, ["data", "user", "user_id"])

    case user_id do
      id when is_binary(id) ->
        # OIDC user-info is not as rich as the contact API. Hydration is
        # best-effort so login can still succeed if contact lookup is unavailable.
        case FeishuOpenAPI.get(client, "contact/v3/users/:user_id",
               path_params: %{user_id: id},
               query: [user_id_type: "user_id"]
             ) do
          {:ok, %{"data" => %{"user" => user}}} when is_map(user) ->
            {:ok, Map.merge(user_info, user)}

          {:ok, _body} ->
            {:ok, user_info}

          {:error, reason} ->
            Logger.warning("lark adapter contact hydration failed: #{inspect(reason)}")
            {:ok, user_info}
        end

      nil ->
        {:ok, user_info}
    end
  end

  defp required_opt(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing, key}}
    end
  end

  defp user_id(user) do
    case optional_text(user, "user_id") || optional_text(user, "id") do
      value when is_binary(value) -> {:ok, value}
      nil -> {:error, :missing_user_id}
    end
  end

  defp display_name(user) do
    optional_text(user, "name") ||
      optional_text(user, "en_name") ||
      optional_text(user, "nickname") ||
      optional_text(user, "user_id")
  end

  defp avatar_url(user) do
    avatar = fetch_map(user, "avatar", %{})
    optional_text(avatar, "avatar_240") || optional_text(avatar, "avatar_origin")
  end

  defp enterprise_email(user) do
    optional_text(user, "enterprise_email") || optional_text(user, "work_email")
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

  defp optional_text(map, key) when is_map(map) do
    case fetch_value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _value ->
        nil
    end
  end

  defp fetch_map(map, key, default) do
    case fetch_value(map, key) do
      value when is_map(value) -> value
      _value -> default
    end
  end

  defp fetch_list(map, key) do
    case fetch_value(map, key) do
      value when is_list(value) -> value
      _value -> []
    end
  end

  defp fetch_value(map, key) when is_map(map) do
    atom_key = atom_key(key)

    # Provider data is string-keyed; tests and local adapters often use atom
    # keys. Existing atoms are accepted without opening atom-creation risk.
    cond do
      Map.has_key?(map, key) -> Map.fetch!(map, key)
      not is_nil(atom_key) and Map.has_key?(map, atom_key) -> Map.fetch!(map, atom_key)
      true -> nil
    end
  end

  defp atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] end)
    |> Map.new()
  end

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end
end
