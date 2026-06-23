defmodule FeishuOpenAPI.Spec do
  @moduledoc """
  Internal request description passed from `FeishuOpenAPI.request/4` to
  `FeishuOpenAPI.Request`.

  `build/3` resolves the pieces that can be decided before authentication or
  `Req` option assembly, especially path rendering and access-token mode.
  Keeping this as a struct lets the request pipeline stay staged and readable:
  `Spec -> Request -> Req -> response handling`, instead of mixing path, auth,
  headers, body, and retry concerns in one function.
  """

  alias FeishuOpenAPI.Error

  @valid_access_token_types [:tenant_access_token, :app_access_token, :user_access_token, nil]

  @enforce_keys [:method, :path, :access_token_type]
  defstruct [
    :method,
    :path,
    :access_token_type,
    :tenant_key,
    :user_access_token,
    :user_access_token_key,
    query: nil,
    headers: [],
    body: :unset,
    form_multipart: :unset,
    req_options: [],
    raw: false
  ]

  @type body_directive :: :unset | term()

  @type t :: %__MODULE__{
          method: atom(),
          path: String.t(),
          access_token_type: :tenant_access_token | :app_access_token | :user_access_token | nil,
          tenant_key: String.t() | nil,
          user_access_token: String.t() | nil,
          user_access_token_key: String.t() | nil,
          query: keyword() | map() | nil,
          headers: list(),
          body: body_directive(),
          form_multipart: body_directive(),
          req_options: keyword(),
          raw: boolean()
        }

  @doc """
  Build a spec from the raw options passed to `FeishuOpenAPI.request/4`.

  Performs up-front validation (access_token_type, path rendering) so the
  rest of the pipeline can assume the inputs are well-formed.
  """
  @spec build(atom(), String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def build(method, path, opts) when is_atom(method) and is_binary(path) and is_list(opts) do
    path_params = Keyword.get(opts, :path_params, %{})
    user_token = Keyword.get(opts, :user_access_token)
    user_token_key = Keyword.get(opts, :user_access_token_key)

    with {:ok, access_token_type} <- resolve_access_token_type(opts, user_token, user_token_key),
         {:ok, rendered_path} <- render_path(path, path_params) do
      {:ok,
       %__MODULE__{
         method: method,
         path: rendered_path,
         access_token_type: access_token_type,
         tenant_key: Keyword.get(opts, :tenant_key),
         user_access_token: user_token,
         user_access_token_key: user_token_key,
         query: Keyword.get(opts, :query),
         headers: Keyword.get(opts, :headers, []),
         body: fetch_or_unset(opts, :body),
         form_multipart: fetch_or_unset(opts, :form_multipart),
         req_options: Keyword.get(opts, :req_options, []),
         raw: Keyword.get(opts, :raw, false)
       }}
    end
  end

  @doc """
  True when the SDK owns the credential that authenticated this request
  and can usefully invalidate it on stale-token errors.

  False for auth endpoints (`access_token_type: nil`) and explicit-bearer
  requests (`user_access_token: "..."`) — in both cases the SDK has nothing
  to refresh, so the stale-token retry branch should be skipped.
  """
  @spec auth_managed?(t()) :: boolean()
  def auth_managed?(%__MODULE__{access_token_type: nil}), do: false
  def auth_managed?(%__MODULE__{user_access_token: t}) when is_binary(t), do: false
  def auth_managed?(%__MODULE__{}), do: true

  # --- internals -----------------------------------------------------------

  defp resolve_access_token_type(opts, user_token, user_token_key) do
    case Keyword.fetch(opts, :access_token_type) do
      {:ok, type} when type in @valid_access_token_types ->
        validate_explicit_access_token_type(type, user_token, user_token_key)

      {:ok, other} ->
        {:error,
         %Error{
           code: :invalid_access_token_type,
           msg:
             "access_token_type must be one of #{inspect(@valid_access_token_types)}, got: #{inspect(other)}"
         }}

      :error ->
        default =
          cond do
            is_binary(user_token) -> :user_access_token
            is_binary(user_token_key) -> :user_access_token
            true -> :tenant_access_token
          end

        {:ok, default}
    end
  end

  defp validate_explicit_access_token_type(type, user_token, user_token_key) do
    if type != :user_access_token and (is_binary(user_token) or is_binary(user_token_key)) do
      {:error,
       %Error{
         code: :conflicting_access_token_options,
         msg:
           "user_access_token/user_access_token_key may only be used with access_token_type: :user_access_token or when access_token_type is omitted"
       }}
    else
      {:ok, type}
    end
  end

  defp render_path(path, params) do
    try do
      rendered =
        Regex.replace(~r/:([a-zA-Z_][a-zA-Z0-9_]*)/, path, fn _matched, name ->
          case fetch_param(params, name) do
            {:ok, value} ->
              URI.encode(to_string(value), &URI.char_unreserved?/1)

            :error ->
              raise ArgumentError,
                    "missing path param #{inspect(name)} for path #{path}"
          end
        end)

      {:ok, rendered}
    rescue
      e in ArgumentError ->
        {:error, %Error{code: :bad_path, msg: Exception.message(e)}}
    end
  end

  defp fetch_param(params, name) when is_map(params) and is_binary(name) do
    case Map.fetch(params, name) do
      {:ok, nil} -> :error
      {:ok, value} -> {:ok, value}
      :error -> fetch_param_from_enum(params, name)
    end
  end

  defp fetch_param(params, name) when is_list(params) and is_binary(name) do
    fetch_param_from_enum(params, name)
  end

  defp fetch_param(_params, _name), do: :error

  defp fetch_param_from_enum(params, name) do
    Enum.find_value(params, :error, fn
      {key, nil} ->
        if param_key_match?(key, name), do: :error

      {key, value} ->
        if param_key_match?(key, name), do: {:ok, value}

      _ ->
        nil
    end)
  end

  defp param_key_match?(key, name) when is_atom(key), do: Atom.to_string(key) == name
  defp param_key_match?(key, name) when is_binary(key), do: key == name
  defp param_key_match?(_, _), do: false

  defp fetch_or_unset(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> :unset
    end
  end
end
