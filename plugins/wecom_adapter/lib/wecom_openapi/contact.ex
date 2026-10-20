defmodule WeComOpenAPI.Contact do
  @moduledoc """
  WeCom contacts (通讯录) directory access.

  Requires a client built from the contacts-sync secret (`管理工具 → 通讯录同步`):
  since 2022-06-20 the ordinary self-built-app secret no longer returns names or
  other sensitive member fields. The department tree is rooted at department id
  `1`; user listing is per-department (`fetch_child=0`) without cursors. Used by
  the identity provider for periodic full directory sync.
  """

  alias WeComOpenAPI.{Corp.Client, Error}

  @department_list_path "/cgi-bin/department/list"
  @user_list_path "/cgi-bin/user/list"
  @user_get_path "/cgi-bin/user/get"

  @root_department_id 1

  @doc "Root department id of the WeCom org tree."
  @spec root_department_id() :: integer()
  def root_department_id, do: @root_department_id

  @doc """
  List departments. With no `dept_id` the whole tree is returned; with one, the
  department and its children. Each entry has `id`, `parentid`, `order`, and
  (with the contacts-sync secret) `name`.
  """
  @spec list_departments(Client.t(), integer() | nil) :: {:ok, [map()]} | {:error, Error.t()}
  def list_departments(%Client{} = client, dept_id \\ nil) do
    query = if dept_id, do: [id: dept_id], else: []

    case WeComOpenAPI.get(client, @department_list_path, query: query) do
      {:ok, %{"department" => list}} when is_list(list) -> {:ok, list}
      {:ok, other} -> {:error, %Error{reason: :unexpected_shape, raw: other}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  List the detailed members of one department (`fetch_child=0`). Members can
  belong to several departments, so callers de-duplicate by `userid`.
  """
  @spec list_department_users(Client.t(), integer()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_department_users(%Client{} = client, dept_id) when is_integer(dept_id) do
    query = [department_id: dept_id, fetch_child: 0]

    case WeComOpenAPI.get(client, @user_list_path, query: query) do
      {:ok, %{"userlist" => list}} when is_list(list) -> {:ok, list}
      {:ok, other} -> {:error, %Error{reason: :unexpected_shape, raw: other}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Fetch a single member's profile by `userid`."
  @spec get_user(Client.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_user(%Client{} = client, userid) when is_binary(userid) do
    case WeComOpenAPI.get(client, @user_get_path, query: [userid: userid]) do
      {:ok, %{"userid" => _} = user} -> {:ok, user}
      {:ok, other} -> {:error, %Error{reason: :unexpected_shape, raw: other}}
      {:error, _reason} = error -> error
    end
  end
end
