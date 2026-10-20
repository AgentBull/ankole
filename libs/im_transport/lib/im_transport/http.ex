defmodule IMTransport.HTTP do
  @moduledoc "Shared request-body and response primitives with no provider policy."

  def decoded_body(body) when is_map(body), do: body

  def decoded_body(body) when is_binary(body) do
    case Torque.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  def decoded_body(body), do: body

  def put_body(req_opts, opts) do
    cond do
      Keyword.has_key?(opts, :body) ->
        req_opts
        |> Keyword.put(:body, Torque.encode!(Keyword.fetch!(opts, :body)))
        |> Keyword.update!(:headers, &(&1 ++ [{"content-type", "application/json"}]))

      Keyword.has_key?(opts, :form) ->
        Keyword.put(req_opts, :form, Keyword.fetch!(opts, :form))

      true ->
        req_opts
    end
  end

  def retry_after(response) do
    case Req.Response.get_header(response, "retry-after") do
      [value | _rest] when is_binary(value) ->
        case Integer.parse(value) do
          {seconds, _rest} -> seconds
          :error -> nil
        end

      _value ->
        nil
    end
  end

  def filename_from_response(response) do
    case Req.Response.get_header(response, "content-disposition") do
      [value | _rest] when is_binary(value) ->
        case Regex.run(~r/filename\*?=(?:UTF-8''|\")?([^\";]+)/i, value, capture: :all_but_first) do
          [filename] -> URI.decode(filename)
          _no_match -> nil
        end

      _absent ->
        nil
    end
  end
end
