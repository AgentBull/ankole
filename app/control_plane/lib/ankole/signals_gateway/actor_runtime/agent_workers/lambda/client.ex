defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Lambda.Client do
  @moduledoc "Signed Lambda MicroVM and image-build requests."

  @api "/2025-09-09"

  def request(provider, method, path, body \\ nil, params \\ []) do
    url = "https://lambda.#{provider.settings["region"]}.amazonaws.com" <> @api <> path
    url = if params == [], do: url, else: url <> "?" <> URI.encode_query(params)

    signed(provider, "lambda", method, url, encode(body), [{"content-type", "application/json"}])
  end

  def list(provider, path, params \\ []) do
    with {:ok, %{"items" => items} = page} <-
           request(provider, :get, path, nil, Keyword.put(params, :maxResults, 50)) do
      case page["nextToken"] do
        nil ->
          {:ok, items}

        token ->
          with {:ok, rest} <- list(provider, path, Keyword.put(params, :nextToken, token)),
               do: {:ok, items ++ rest}
      end
    end
  end

  def upload(provider, key, zip) do
    bucket = provider.settings["buildBucket"]
    url = "https://s3.#{provider.settings["region"]}.amazonaws.com/#{path(bucket)}/#{key}"

    with {:ok, _body} <-
           signed(provider, "s3", :put, url, zip, [{"content-type", "application/zip"}]),
         do: {:ok, "s3://#{bucket}/#{key}"}
  end

  def ecr_token(provider, region) do
    provider = %{provider | settings: Map.put(provider.settings, "region", region)}

    headers = [
      {"content-type", "application/x-amz-json-1.1"},
      {"x-amz-target", "AmazonEC2ContainerRegistry_V20150921.GetAuthorizationToken"}
    ]

    signed(provider, "ecr", :post, "https://api.ecr.#{region}.amazonaws.com/", "{}", headers)
  end

  def path(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp signed(provider, service, method, url, body, headers) do
    with {:ok, credentials} <- credentials(provider.secrets) do
      headers = [{"host", URI.parse(url).host} | headers]

      headers =
        case credentials[:token] do
          nil -> headers
          token -> [{"x-amz-security-token", token} | headers]
        end

      signed_headers =
        :aws_signature.sign_v4(
          credentials.access_key_id,
          credentials.secret_access_key,
          provider.settings["region"],
          service,
          :calendar.universal_time(),
          method |> to_string() |> String.upcase(),
          url,
          headers,
          body,
          uri_encode_path: service != "s3"
        )

      result =
        [retry: false, redirect: false, receive_timeout: 30_000, decode_body: false]
        |> Keyword.merge(Application.get_env(:ankole, :lambda_api_req_options, []))
        |> Req.new()
        |> Req.request(method: method, url: url, headers: signed_headers, body: body)

      case result do
        {:ok, response} ->
          with {:ok, decoded} <- decode_response(service, response.body) do
            if response.status in 200..299,
              do: {:ok, decoded},
              else:
                {:error, {:lambda_api, response.status, error_code(%{response | body: decoded})}}
          end

        {:error, reason} ->
          {:error, {:lambda_unreachable, reason}}
      end
    end
  end

  defp decode_response("s3", body), do: {:ok, body}
  defp decode_response(_service, ""), do: {:ok, nil}
  defp decode_response(_service, body), do: Ankole.JSON.decode(body)

  defp credentials(%{"accessKeyId" => id, "secretAccessKey" => secret} = secrets),
    do: {:ok, %{access_key_id: id, secret_access_key: secret, token: secrets["sessionToken"]}}

  defp credentials(secrets) when map_size(secrets) == 0 do
    with {:ok, _apps} <- Application.ensure_all_started(:aws_credentials) do
      case :aws_credentials.get_credentials() do
        :undefined -> {:error, :lambda_credentials_unavailable}
        values -> {:ok, values}
      end
    end
  end

  defp error_code(response) do
    type =
      List.first(Req.Response.get_header(response, "x-amzn-errortype")) ||
        if(is_map(response.body), do: response.body["__type"])

    if is_binary(type), do: type |> String.split("#") |> List.last() |> String.split(":") |> hd()
  end

  defp encode(nil), do: ""
  defp encode(body), do: Ankole.JSON.encode!(body)
end
