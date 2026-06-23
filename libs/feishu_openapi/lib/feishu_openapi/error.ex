defmodule FeishuOpenAPI.Error do
  @moduledoc """
  Represents a failed Feishu/Lark API call.

  `:code` is `:transport` for network-level failures; otherwise it is the
  non-zero `code` value returned by the OpenAPI response body.

  `raw_body` and `details` may contain the original request payload — they are
  redacted from `inspect/1` output to avoid leaking secrets/PII into logs.
  """

  @type t :: %__MODULE__{
          code: integer() | atom(),
          msg: String.t() | nil,
          http_status: integer() | nil,
          log_id: String.t() | nil,
          raw_body: term(),
          details: term()
        }

  defexception [:code, :msg, :http_status, :log_id, :raw_body, :details]

  @error_code_reference_url "https://open.feishu.cn/document/server-docs/api-call-guide/generic-error-code"

  @doc "Public reference URL appended to error messages for numeric business codes."
  @spec error_code_reference_url() :: String.t()
  def error_code_reference_url, do: @error_code_reference_url

  @impl true
  def message(%__MODULE__{code: code, msg: msg, log_id: log_id}) do
    parts = ["feishu_openapi error: code=#{inspect(code)}"]
    parts = if msg, do: parts ++ ["msg=" <> msg], else: parts
    parts = if log_id, do: parts ++ ["log_id=" <> log_id], else: parts
    # Only numeric codes come back from Feishu; SDK-internal codes are atoms
    # (`:transport`, `:rate_limited`, `:bad_path`, ...) and have their own
    # meaning that users don't need to look up in the reference doc.
    parts =
      if is_integer(code), do: parts ++ ["(see " <> @error_code_reference_url <> ")"], else: parts

    Enum.join(parts, " ")
  end

  @doc """
  Build an error from a decoded OpenAPI response body (`%{"code" => c, "msg" => m, ...}`)
  plus the raw `Req.Response` used to surface status and log id.
  """
  @spec from_response(map(), Req.Response.t()) :: t()
  def from_response(%{"code" => code} = body, %Req.Response{} = resp) do
    error_details = Map.get(body, "error")

    %__MODULE__{
      code: code,
      msg: Map.get(body, "msg") || nested_message(error_details),
      http_status: resp.status,
      log_id: log_id_from(resp) || nested_log_id(error_details),
      raw_body: body,
      details: error_details
    }
  end

  @doc "Build a transport-level error."
  @spec transport(term()) :: t()
  def transport(reason) do
    %__MODULE__{code: :transport, msg: inspect(reason), details: reason}
  end

  defp log_id_from(%Req.Response{headers: headers}) when is_map(headers) do
    case Map.get(headers, "x-tt-logid") do
      [id | _] -> id
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  defp log_id_from(_), do: nil

  defp nested_message(%{"message" => message}) when is_binary(message), do: message
  defp nested_message(_), do: nil

  defp nested_log_id(%{"logid" => log_id}) when is_binary(log_id), do: log_id
  defp nested_log_id(_), do: nil

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%FeishuOpenAPI.Error{} = err, opts) do
      visible = [code: err.code, msg: err.msg, http_status: err.http_status, log_id: err.log_id]

      visible =
        Enum.reject(visible, fn {_, v} -> is_nil(v) end) ++
          redacted_marker(err)

      concat(["#FeishuOpenAPI.Error<", to_doc(visible, opts), ">"])
    end

    defp redacted_marker(%FeishuOpenAPI.Error{raw_body: nil, details: nil}), do: []
    defp redacted_marker(_), do: [raw_body: :redacted, details: :redacted]
  end
end
