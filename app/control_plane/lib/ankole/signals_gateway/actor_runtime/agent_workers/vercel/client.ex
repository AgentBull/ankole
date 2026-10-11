defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Vercel.Client do
  @moduledoc "Vercel Sandbox REST requests and cursor pagination."

  def request(provider, method, path, opts \\ []) do
    params = Keyword.get(opts, :params, []) |> Keyword.put(:teamId, provider.settings["teamId"])

    result =
      [
        base_url: "https://api.vercel.com",
        auth: {:bearer, provider.secrets["token"]},
        headers: [{"content-type", "application/json"}],
        retry: false,
        receive_timeout: 30_000
      ]
      |> Keyword.merge(Application.get_env(:ankole, :vercel_api_req_options, []))
      |> Req.new()
      |> Req.request([method: method, url: path] ++ Keyword.put(opts, :params, params))

    case result do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: %{"error" => %{"code" => code} = error}}} ->
        {:error, {:vercel_api, status, code, error["message"]}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:vercel_api, status, nil, inspect(body) |> String.slice(0, 500)}}

      {:error, reason} ->
        {:error, {:vercel_unreachable, reason}}
    end
  end

  def list(provider, path, key, params) do
    with {:ok, body} <- request(provider, :get, path, params: Keyword.put(params, :limit, 50)) do
      case get_in(body, ["pagination", "next"]) do
        nil ->
          {:ok, Map.fetch!(body, key)}

        cursor ->
          with {:ok, rest} <- list(provider, path, key, Keyword.put(params, :cursor, cursor)),
               do: {:ok, Map.fetch!(body, key) ++ rest}
      end
    end
  end

  def path(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
