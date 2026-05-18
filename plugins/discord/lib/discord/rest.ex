defmodule Discord.Rest do
  @moduledoc false

  @api_base "https://discord.com/api/v10"

  @spec request(Discord.Source.t(), atom(), map() | keyword()) :: {:ok, term()} | {:error, term()}
  def request(source, operation, params \\ %{})

  def request(source, :get_current_bot, _params), do: get(source, "/users/@me")
  def request(source, :get_application, _params), do: get(source, "/applications/#{source.application_id}")
  def request(source, :create_message, params), do: post(source, "/channels/#{params["channel_id"]}/messages", params["body"])
  def request(source, :edit_message, params), do: patch(source, "/channels/#{params["channel_id"]}/messages/#{params["message_id"]}", params["body"])

  def request(source, :create_thread, params) do
    post(source, "/channels/#{params["channel_id"]}/messages/#{params["message_id"]}/threads", params["body"])
  end

  def request(source, :exchange_oauth_code, params) do
    body = [
      grant_type: "authorization_code",
      code: params["code"],
      redirect_uri: params["redirect_uri"]
    ]

    Req.post(oauth_req(source), url: "https://discord.com/api/oauth2/token", form: body)
    |> decode_response()
  end

  def request(_source, :fetch_userinfo, params) do
    Req.get(url: @api_base <> "/users/@me", auth: {:bearer, params["access_token"]})
    |> decode_response()
  end

  def request(_source, operation, _params), do: {:error, Discord.Error.unsupported("unsupported Discord REST operation", %{operation: operation})}

  defp get(source, path), do: source |> req(path) |> Req.get() |> decode_response()
  defp post(source, path, body), do: source |> req(path) |> Req.post(json: body) |> decode_response()
  defp patch(source, path, body), do: source |> req(path) |> Req.patch(json: body) |> decode_response()

  defp req(source, path) do
    source.req_options
    |> Keyword.merge(url: api_base(source) <> path, auth: {:bearer, source.bot_token})
    |> Req.new()
  end

  defp oauth_req(source) do
    Req.new(auth: {:basic, "#{source.application_id}:#{source.client_secret}"})
  end

  defp api_base(%{api_base: base}) when is_binary(base), do: String.trim_trailing(base, "/")
  defp api_base(_source), do: @api_base

  defp decode_response({:ok, %{status: status, body: body}}) when status in 200..299, do: {:ok, body}
  defp decode_response({:ok, response}), do: {:error, response}
  defp decode_response({:error, reason}), do: {:error, reason}
end
