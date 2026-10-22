defmodule Ankole.Plugins.ChinaMarketAIProviders.WorkerProviders.FunctionCompute.Client do
  @moduledoc "Sandbox ROA, NAS RPC, and E2B requests with their separate wire formats."

  alias Ankole.Plugins.ChinaMarketAIProviders.WorkerProviders.FunctionCompute.Signature

  @pop "/pop/2026-08-20"

  def pop(provider, action, method, path, body \\ nil, params \\ %{}) do
    signed(
      provider,
      action,
      "2026-08-20",
      method,
      "sandbox.#{provider.settings["region"]}.aliyuncs.com",
      @pop <> path,
      body,
      params
    )
  end

  def nas(provider, action, params) do
    signed(
      provider,
      action,
      "2017-06-26",
      :post,
      "nas.#{provider.settings["region"]}.aliyuncs.com",
      "/",
      nil,
      params
    )
  end

  def api(provider, method, path, opts \\ []) do
    with {:ok, response} <-
           request(
             method,
             "https://" <> provider.settings["apiDomain"] <> path,
             Keyword.put(opts, :headers, [{"x-api-key", provider.secrets["apiKey"]}])
           ),
         do: {:ok, response.body}
  end

  def sandboxes(provider, metadata, token \\ nil) do
    params = %{metadata: URI.encode_query(metadata), state: "running,paused", limit: 100}
    params = if token, do: Map.put(params, :nextToken, token), else: params

    with {:ok, response} <-
           request(:get, "https://" <> provider.settings["apiDomain"] <> "/v2/sandboxes",
             headers: [{"x-api-key", provider.secrets["apiKey"]}],
             params: params
           ) do
      case List.first(Req.Response.get_header(response, "x-next-token")) do
        next when next in [nil, ""] ->
          {:ok, response.body}

        next ->
          with {:ok, rest} <- sandboxes(provider, metadata, next),
               do: {:ok, response.body ++ rest}
      end
    end
  end

  def file(provider, sandbox, method, path, content \\ nil) do
    {origin, headers} = envd(provider, sandbox)
    opts = [headers: headers, params: [path: path, username: "root"]]

    opts =
      if content,
        do: Keyword.put(opts, :form_multipart, file: {content, filename: path}),
        else: opts

    with {:ok, response} <- request(method, origin <> "/files", opts),
         do: {:ok, response.body}
  end

  def restore_oss_connections(provider, sandbox) do
    {origin, headers} = envd(provider, sandbox)

    payload =
      Ankole.JSON.encode!(%{
        process: %{
          cmd: "/usr/bin/python3",
          args: ["/usr/local/libexec/function-compute-resume-oss.py"]
        }
      })

    headers =
      headers ++
        [
          {"authorization", "Basic " <> Base.encode64("root:")},
          {"content-type", "application/connect+json"},
          {"connect-protocol-version", "1"},
          {"connect-timeout-ms", "15000"}
        ]

    with {:ok, response} <-
           request(:post, origin <> "/process.Process/Start",
             headers: headers,
             body: <<0, byte_size(payload)::32, payload::binary>>,
             decode_body: false,
             receive_timeout: 20_000
           ),
         do: command_result(response.body, nil)
  end

  defp command_result(<<flags, size::32, payload::binary-size(size), rest::binary>>, result) do
    case {flags, Ankole.JSON.decode(payload)} do
      {0, {:ok, %{"event" => %{"end" => %{"exited" => true} = ended}}}} ->
        case Map.get(ended, "exitCode", 0) do
          0 -> command_result(rest, :ok)
          code -> command_result(rest, {:error, {:function_compute_storage_resume, code}})
        end

      {0, {:ok, %{"event" => event}}} when is_map(event) ->
        command_result(rest, result)

      {2, {:ok, trailers}} when is_map(trailers) and rest == "" ->
        if Map.has_key?(trailers, "error"),
          do: {:error, {:function_compute_storage_resume, trailers["error"]}},
          else: result || {:error, :function_compute_command_incomplete}

      _ ->
        {:error, :function_compute_command_invalid}
    end
  end

  defp command_result(_, _), do: {:error, :function_compute_command_incomplete}

  defp envd(provider, sandbox) do
    domain =
      sandbox["domain"] || String.replace_prefix(provider.settings["apiDomain"], "api.", "")

    id = sandbox["sandboxID"]
    headers = [{"e2b-sandbox-id", id}, {"e2b-sandbox-port", "49983"}]

    headers =
      if sandbox["envdAccessToken"],
        do: [{"x-access-token", sandbox["envdAccessToken"]} | headers],
        else: headers

    {"https://49983-#{id}.#{domain}", headers}
  end

  def path(value), do: Signature.path(value)

  defp signed(provider, action, version, method, host, path, body, params) do
    payload = if is_nil(body), do: "", else: Ankole.JSON.encode!(body)
    uri = %URI{scheme: "https", host: host, path: path, query: Signature.query(params)}

    headers = [
      {"content-type", "application/json"},
      {"host", host},
      {"x-acs-action", action},
      {"x-acs-version", version},
      {"x-acs-date", DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()},
      {"x-acs-signature-nonce", Ankole.Ecto.UUIDv7.autogenerate()},
      {"x-acs-content-sha256", Signature.hash(payload)}
    ]

    headers =
      if provider.secrets["securityToken"],
        do: [{"x-acs-security-token", provider.secrets["securityToken"]} | headers],
        else: headers

    headers = Signature.sign(method, uri, headers, payload, provider.secrets)

    with {:ok, response} <- request(method, URI.to_string(uri), headers: headers, body: payload),
         do: {:ok, response.body}
  end

  defp request(method, url, opts) do
    result =
      [retry: false, redirect: false, receive_timeout: 60_000]
      |> Keyword.merge(Application.get_env(:ankole, :function_compute_req_options, []))
      |> Req.new()
      |> Req.request([method: method, url: url] ++ opts)

    case result do
      {:ok, %{status: status} = response} when status in 200..299 ->
        {:ok, response}

      {:ok, response} ->
        body = if is_map(response.body), do: response.body, else: %{}

        {:error,
         {:function_compute_api, response.status, body["Code"] || body["code"],
          body["Message"] || body["message"]}}

      {:error, reason} ->
        {:error, {:function_compute_unreachable, reason}}
    end
  end
end
