defmodule DingTalkOpenAPI.Contact do
  @moduledoc """
  DingTalk contacts (通讯录) directory access over the old domain (`topapi/v2`).

  The department tree is rooted at department id `1`. User listing is
  cursor-paginated per department (`size` ≤ 100). Used by the identity provider
  for full and incremental directory sync.
  """

  alias DingTalkOpenAPI.{Client, Error, Pagination}

  @list_sub_path "topapi/v2/department/listsub"
  @get_dept_path "topapi/v2/department/get"
  @list_user_path "topapi/v2/user/list"
  @get_user_path "topapi/v2/user/get"

  @root_department_id 1

  @doc "Root department id of the DingTalk org tree."
  @spec root_department_id() :: integer()
  def root_department_id, do: @root_department_id

  @doc "List immediate sub-departments of `dept_id` (default root). Returns the department list."
  @spec list_sub_departments(Client.t(), integer()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_sub_departments(%Client{} = client, dept_id \\ @root_department_id) do
    case DingTalkOpenAPI.post(client, @list_sub_path, body: %{"dept_id" => dept_id}) do
      {:ok, %{"result" => list}} when is_list(list) -> {:ok, list}
      {:ok, other} -> {:error, %Error{reason: :unexpected_shape, raw: other}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Fetch a single department's detail."
  @spec get_department(Client.t(), integer()) :: {:ok, map()} | {:error, Error.t()}
  def get_department(%Client{} = client, dept_id) do
    case DingTalkOpenAPI.post(client, @get_dept_path, body: %{"dept_id" => dept_id}) do
      {:ok, %{"result" => dept}} when is_map(dept) -> {:ok, dept}
      {:ok, other} -> {:error, %Error{reason: :unexpected_shape, raw: other}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Stream all users of a department across cursor pages. Yields `{:ok, user}` per
  user and a terminal `{:error, %Error{}}` on failure.
  """
  @spec stream_department_users(Client.t(), integer(), keyword()) :: Enumerable.t()
  def stream_department_users(%Client{} = client, dept_id, opts \\ []) do
    size = Keyword.get(opts, :size, 100)
    Pagination.stream(client, @list_user_path, body: %{"dept_id" => dept_id}, size: size)
  end

  @doc "Fetch a single user's full profile by enterprise `userid`."
  @spec get_user(Client.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_user(%Client{} = client, userid) when is_binary(userid) do
    case DingTalkOpenAPI.post(client, @get_user_path, body: %{"userid" => userid}) do
      {:ok, %{"result" => user}} when is_map(user) -> {:ok, user}
      {:ok, other} -> {:error, %Error{reason: :unexpected_shape, raw: other}}
      {:error, _reason} = error -> error
    end
  end
end
