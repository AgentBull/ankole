defmodule BullxTelegram.BotAPI do
  @moduledoc false

  @api_base "https://api.telegram.org"

  @spec request(BullxTelegram.Source.t(), String.t(), keyword() | map()) :: {:ok, term()} | {:error, term()}
  def request(source, method, params \\ []) when is_binary(method) do
    body = normalize_params(params)

    Req.post(
      Keyword.merge(source.req_options,
        url: api_base(source) <> "/bot" <> source.bot_token <> "/" <> method,
        json: body
      )
    )
    |> decode_response()
  end

  defp normalize_params(params) when is_list(params), do: Map.new(params)
  defp normalize_params(%{} = params), do: params

  defp api_base(%{api_base: base}) when is_binary(base), do: String.trim_trailing(base, "/")
  defp api_base(_source), do: @api_base

  defp decode_response({:ok, %{status: status, body: %{"ok" => true, "result" => result}}}) when status in 200..299, do: {:ok, result}
  defp decode_response({:ok, %{status: status, body: body}}) when status in 200..299, do: {:ok, body}
  defp decode_response({:ok, response}), do: {:error, response}
  defp decode_response({:error, reason}), do: {:error, reason}
end
