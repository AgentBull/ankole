defmodule GoogleOpenAPI.Directory do
  @moduledoc """
  Admin SDK Directory API helpers.

  Every call authenticates with a cached service-account bearer token minted
  for the read-only directory scopes and the client's delegated subject. Page
  size caps follow the API: 500 for users, 200 for groups and members.
  """

  alias GoogleOpenAPI.Auth
  alias GoogleOpenAPI.Client
  alias GoogleOpenAPI.Error
  alias GoogleOpenAPI.Pagination

  @directory_scopes [
    "https://www.googleapis.com/auth/admin.directory.user.readonly",
    "https://www.googleapis.com/auth/admin.directory.group.readonly",
    "https://www.googleapis.com/auth/admin.directory.group.member.readonly"
  ]

  @max_users_page_size 500
  @max_groups_page_size 200
  @max_members_page_size 200

  @spec directory_scopes() :: [String.t()]
  def directory_scopes, do: @directory_scopes

  @spec list_users(Client.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def list_users(%Client{} = client, query \\ []) do
    request(client, "/users", cap_page_size(query, @max_users_page_size))
  end

  @spec get_user(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get_user(%Client{} = client, user_key, query \\ []) when is_binary(user_key) do
    request(client, "/users/" <> encode_segment(user_key), query)
  end

  @spec list_groups(Client.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def list_groups(%Client{} = client, query \\ []) do
    request(client, "/groups", cap_page_size(query, @max_groups_page_size))
  end

  @spec list_members(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def list_members(%Client{} = client, group_key, query \\ []) when is_binary(group_key) do
    request(
      client,
      "/groups/" <> encode_segment(group_key) <> "/members",
      cap_page_size(query, @max_members_page_size)
    )
  end

  @doc """
  Lazily streams users through `nextPageToken` continuation.
  """
  @spec stream_users(Client.t(), keyword()) :: Enumerable.t()
  def stream_users(%Client{} = client, query \\ []) do
    Pagination.stream(&list_users(client, &1), "users", query)
  end

  @doc """
  Lazily streams groups through `nextPageToken` continuation.
  """
  @spec stream_groups(Client.t(), keyword()) :: Enumerable.t()
  def stream_groups(%Client{} = client, query \\ []) do
    Pagination.stream(&list_groups(client, &1), "groups", query)
  end

  @doc """
  Lazily streams direct group members through `nextPageToken` continuation.
  """
  @spec stream_members(Client.t(), String.t(), keyword()) :: Enumerable.t()
  def stream_members(%Client{} = client, group_key, query \\ []) do
    Pagination.stream(&list_members(client, group_key, &1), "members", query)
  end

  defp request(client, path, query) do
    with {:ok, token} <- Auth.jwt_bearer_token(client, scope: @directory_scopes) do
      GoogleOpenAPI.request(
        :get,
        client.api_base_url <> "/admin/directory/v1" <> path,
        query: query,
        headers: GoogleOpenAPI.bearer_headers(token),
        req_options: client.req_options
      )
    end
  end

  defp cap_page_size(query, cap) do
    case Keyword.get(query, :maxResults) do
      size when is_integer(size) -> Keyword.put(query, :maxResults, min(max(size, 1), cap))
      _absent -> query
    end
  end

  defp encode_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
