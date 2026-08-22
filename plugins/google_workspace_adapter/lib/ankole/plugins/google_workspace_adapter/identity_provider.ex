defmodule Ankole.Plugins.GoogleWorkspaceAdapter.IdentityProvider do
  @moduledoc false

  alias Ankole.AuthZ
  alias Ankole.IdentityProviders.Directory, as: IdentityDirectory
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Plugins.GoogleWorkspaceAdapter.Config
  alias Ankole.Plugins.MapHelpers
  alias GoogleOpenAPI.Auth
  alias GoogleOpenAPI.Directory

  @spec authorization_url(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def authorization_url(config, opts) do
    with {:ok, redirect_uri} <- MapHelpers.required_opt(opts, :redirect_uri),
         {:ok, state} <- MapHelpers.required_opt(opts, :state) do
      {:ok,
       Auth.authorize_url(
         auth_base_url: "https://accounts.google.com",
         client_id: Map.fetch!(config, "clientID"),
         redirect_uri: redirect_uri,
         state: state,
         scopes: get_in(config, ["oidc", "scopes"]) || ["openid", "email", "profile"],
         hd: hosted_domain_hint(config)
       )}
    end
  end

  @spec exchange_code(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def exchange_code(config, code, opts \\ []) do
    client = Config.identity_client(config)

    with {:ok, token} <-
           Auth.exchange_code(client,
             code: code,
             redirect_uri: Keyword.get(opts, :redirect_uri)
           ),
         {:ok, claims} <- Auth.userinfo(client, token.access_token),
         :ok <- verify_login_claims(claims, config) do
      {:ok, %{token: token, user: login_user(claims)}}
    end
  end

  @spec upsert_user(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def upsert_user(provider_id, user, opts \\ []) do
    with {:ok, user_id} <- user_id(user) do
      IdentityDirectory.upsert_user(
        provider_id,
        %{
          provider: provider_id,
          external_id: user_id,
          display_name: display_name(user) || user_id,
          email: MapHelpers.optional_text(user, "primaryEmail"),
          job_title: job_title(user),
          mobile: normalized_mobile(user),
          metadata:
            MapHelpers.compact_metadata_map(%{
              "primary_email" => MapHelpers.optional_text(user, "primaryEmail"),
              "org_unit_path" => MapHelpers.optional_text(user, "orgUnitPath"),
              "hosted_domain" => MapHelpers.optional_text(user, "hd"),
              "suspended" => Map.get(user, "suspended"),
              "archived" => Map.get(user, "archived")
            })
        }
        |> MapHelpers.compact_map(),
        Keyword.take(opts, [:group_external_ids, :directory_group_index])
      )
    end
  end

  @spec sync_directory(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def sync_directory(provider_id, config, _opts \\ []) do
    with {:ok, %{groups: group_count, user_index: user_index}} <-
           sync_groups(provider_id, config),
         {:ok, user_count} <- sync_users(provider_id, config, user_index) do
      {:ok, %{users: user_count, groups: group_count}}
    end
  end

  defp sync_groups(provider_id, config) do
    client = Config.identity_client(config)

    Directory.stream_groups(client, customer: "my_customer", maxResults: page_size(config))
    |> Enum.reduce_while({:ok, %{groups: 0, user_index: %{}}}, fn
      {:ok, group}, {:ok, acc} ->
        with {:ok, group_id} <- group_id(group),
             {:ok, _directory_group} <- ensure_google_group(provider_id, group),
             {:ok, member_ids} <- group_member_ids(client, group_id, config) do
          index =
            Enum.reduce(
              member_ids,
              acc.user_index,
              &Map.update(&2, &1, [group_id], fn ids -> [group_id | ids] end)
            )

          {:cont, {:ok, %{groups: acc.groups + 1, user_index: index}}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {:error, reason}, _acc ->
        {:halt, {:error, reason}}
    end)
  end

  defp sync_users(provider_id, config, user_index) do
    client = Config.identity_client(config)

    with {:ok, directory_group_index} <- AuthZ.external_directory_group_index(provider_id) do
      Directory.stream_users(client, customer: "my_customer", maxResults: page_size(config))
      |> Enum.reduce_while({:ok, 0}, fn
        {:ok, user}, {:ok, count} ->
          if directory_user?(user, config) do
            user_id = Map.get(user, "id")

            case upsert_user(provider_id, user,
                   directory_group_index: directory_group_index,
                   group_external_ids: Map.get(user_index, user_id, [])
                 ) do
              {:ok, _observed} -> {:cont, {:ok, count + 1}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          else
            {:cont, {:ok, count}}
          end

        {:error, reason}, _acc ->
          {:halt, {:error, reason}}
      end)
    end
  end

  # Direct USER members only: nested groups are not expanded, matching the
  # flat group projection of the other directory providers.
  defp group_member_ids(client, group_id, config) do
    Directory.stream_members(client, group_id, maxResults: page_size(config))
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, member}, {:ok, acc} ->
        if Map.get(member, "type") == "USER" do
          case MapHelpers.optional_text(member, "id") do
            nil -> {:cont, {:ok, acc}}
            id -> {:cont, {:ok, [id | acc]}}
          end
        else
          {:cont, {:ok, acc}}
        end

      {:error, reason}, _acc ->
        {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  defp ensure_google_group(provider_id, group) do
    with {:ok, external_id} <- group_id(group) do
      IdentityDirectory.ensure_group(provider_id, %IdentityDirectory.Group{
        external_id: external_id,
        kind: "google_group",
        display_name: group_display_name(group, external_id),
        provider_metadata: %{
          "google" =>
            MapHelpers.compact_metadata_map(%{
              "email" => MapHelpers.optional_text(group, "email"),
              "name" => MapHelpers.optional_text(group, "name"),
              "description" => MapHelpers.optional_text(group, "description")
            })
        }
      })
    end
  end

  @doc false
  @spec directory_user?(map(), map()) :: boolean()
  def directory_user?(user, config) do
    include_suspended? = get_in(config, ["sync", "includeSuspended"]) == true

    is_binary(Map.get(user, "id")) and
      (include_suspended? or
         (Map.get(user, "suspended") != true and Map.get(user, "archived") != true))
  end

  # Login identity comes from the userinfo endpoint. `sub` is Google's stable
  # account id (the same id the Directory API reports for the user), so login
  # and directory sync converge on one subject; if they ever disagreed, the
  # email join at the Principal layer still merges them into one human.
  @doc false
  @spec verify_login_claims(map(), map()) :: :ok | {:error, term()}
  def verify_login_claims(claims, config) do
    allowed_domains = get_in(config, ["oidc", "allowedDomains"]) || []
    email = MapHelpers.optional_text(claims, "email")
    hosted_domain = downcased(MapHelpers.optional_text(claims, "hd"))

    cond do
      Map.get(claims, "email_verified") != true ->
        {:error, :email_unverified}

      is_nil(hosted_domain) ->
        {:error, :not_workspace_account}

      hosted_domain not in allowed_domains ->
        {:error, :login_domain_not_allowed}

      is_nil(email) or email_domain(email) not in allowed_domains ->
        {:error, :login_domain_not_allowed}

      true ->
        :ok
    end
  end

  @doc false
  @spec login_user(map()) :: map()
  def login_user(claims) do
    %{
      "id" => MapHelpers.optional_text(claims, "sub"),
      "primaryEmail" => downcased(MapHelpers.optional_text(claims, "email")),
      "name" => MapHelpers.optional_text(claims, "name"),
      "hd" => downcased(MapHelpers.optional_text(claims, "hd"))
    }
    |> MapHelpers.compact_map()
  end

  defp hosted_domain_hint(config) do
    # A single allowed domain becomes the account-picker hint; the hint is
    # user experience only — verify_login_claims is the enforcement point.
    case get_in(config, ["oidc", "allowedDomains"]) do
      [domain] -> domain
      _zero_or_many -> nil
    end
  end

  defp email_domain(email) do
    case String.split(email, "@") do
      [_local, domain] -> String.downcase(domain)
      _malformed -> nil
    end
  end

  defp downcased(nil), do: nil
  defp downcased(value), do: String.downcase(value)

  defp page_size(config), do: get_in(config, ["sync", "pageSize"]) || 500

  defp user_id(user) do
    case MapHelpers.optional_text(user, "id") do
      nil -> {:error, :missing_user_id}
      id -> {:ok, id}
    end
  end

  defp group_id(group) do
    case MapHelpers.optional_text(group, "id") do
      nil -> {:error, :missing_group_id}
      id -> {:ok, id}
    end
  end

  defp display_name(user) do
    case MapHelpers.fetch_value(user, "name") do
      name when is_map(name) -> MapHelpers.optional_text(name, "fullName")
      name when is_binary(name) -> MapHelpers.presence(name)
      _absent -> nil
    end || MapHelpers.optional_text(user, "primaryEmail")
  end

  defp group_display_name(group, external_id) do
    MapHelpers.optional_text(group, "name") || MapHelpers.optional_text(group, "email") ||
      "Google Group #{external_id}"
  end

  defp job_title(user) do
    user
    |> MapHelpers.fetch_list("organizations")
    |> Enum.find_value(fn
      organization when is_map(organization) -> MapHelpers.optional_text(organization, "title")
      _other -> nil
    end)
  end

  defp normalized_mobile(user) do
    user
    |> MapHelpers.fetch_list("phones")
    |> Enum.find_value(fn
      %{"type" => "mobile"} = phone -> MapHelpers.optional_text(phone, "value")
      _other -> nil
    end)
    |> case do
      nil ->
        nil

      phone ->
        case NativeKernel.phone_normalize_e164(String.trim(phone)) do
          normalized when is_binary(normalized) -> normalized
          {:error, _reason} -> nil
        end
    end
  end
end
