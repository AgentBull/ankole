defmodule FeishuOpenAPI do
  @moduledoc """
  Thin Feishu/Lark OpenAPI client.

  Typical usage:

      client = FeishuOpenAPI.new(app_id, app_secret)

      # `/open-apis/` is auto-prepended to paths without a leading slash,
      # so the common case can be written as:
      {:ok, resp} = FeishuOpenAPI.post(client, "im/v1/chats",
        body: %{name: "工程组", chat_type: "private"},
        query: [user_id_type: "open_id"])

      # Explicit absolute paths (including the `/open-apis/` prefix) still
      # work, and any path starting with `/` is passed through untouched —
      # useful for non-`/open-apis` endpoints like `/callback/ws/endpoint`.
      {:ok, resp} = FeishuOpenAPI.put(client, "/open-apis/im/v1/chats/:chat_id",
        path_params: %{chat_id: "oc_xxx"},
        body: %{name: "新群名"})

  The client defaults to a `tenant_access_token`, automatically fetched and
  cached (see `FeishuOpenAPI.TokenManager`). Pass
  `access_token_type: :app_access_token`, `access_token_type: nil`,
  `user_access_token: "u-..."`, or `user_access_token_key: "user-1"` to
  override. Passing a `user_access_token`/`user_access_token_key` without
  an explicit `access_token_type:` implies `:user_access_token`.

  `body` / `query` / `path_params` / `headers` / `req_options` are forwarded
  to the underlying `Req.request/1` call. `raw: true` returns the untouched
  `Req.Response.t()` instead of parsing the `{code, msg, data}` envelope.
  """

  require Logger

  alias FeishuOpenAPI.{Client, Error, Request, Spec, TokenManager}

  @token_invalid_codes [99_991_663, 99_991_664, 99_991_671]
  @app_ticket_invalid_code 10_012
  @rate_limit_code 99_991_400
  @max_token_invalid_retries 1
  @max_retry_after_retries 1
  @default_retry_after_ms :timer.seconds(1)
  @max_retry_after_ms :timer.seconds(30)
  @multipart_field_names %{
    "file_type" => :file_type,
    "file_name" => :file_name,
    "image_type" => :image_type,
    "duration" => :duration
  }

  @doc "Shortcut for `FeishuOpenAPI.Client.new/3`."
  defdelegate new(app_id, app_secret, opts \\ []), to: FeishuOpenAPI.Client

  @doc "HTTP GET."
  def get(client, path, opts \\ []), do: request(client, :get, path, opts)
  @doc "HTTP POST."
  def post(client, path, opts \\ []), do: request(client, :post, path, opts)
  @doc "HTTP PUT."
  def put(client, path, opts \\ []), do: request(client, :put, path, opts)
  @doc "HTTP DELETE."
  def delete(client, path, opts \\ []), do: request(client, :delete, path, opts)
  @doc "HTTP PATCH."
  def patch(client, path, opts \\ []), do: request(client, :patch, path, opts)

  @doc "Like `get/3` but raises `FeishuOpenAPI.Error` on failure."
  def get!(client, path, opts \\ []), do: bang(request(client, :get, path, opts))
  @doc "Like `post/3` but raises `FeishuOpenAPI.Error` on failure."
  def post!(client, path, opts \\ []), do: bang(request(client, :post, path, opts))
  @doc "Like `put/3` but raises `FeishuOpenAPI.Error` on failure."
  def put!(client, path, opts \\ []), do: bang(request(client, :put, path, opts))
  @doc "Like `delete/3` but raises `FeishuOpenAPI.Error` on failure."
  def delete!(client, path, opts \\ []), do: bang(request(client, :delete, path, opts))
  @doc "Like `patch/3` but raises `FeishuOpenAPI.Error` on failure."
  def patch!(client, path, opts \\ []), do: bang(request(client, :patch, path, opts))

  @doc """
  Low-level request entry point. Returns `{:ok, decoded_body}` on success
  (where the response envelope had `"code": 0`), `{:ok, %Req.Response{}}`
  when `raw: true` or the body is not a JSON envelope (e.g. binary download),
  or `{:error, %FeishuOpenAPI.Error{}}`.

  Options (all optional):

    * `:body` — decoded into JSON and sent as request body
    * `:query` — keyword or map of query-string parameters
    * `:path_params` — map used to substitute `:name` placeholders in `path`
    * `:headers` — extra request headers (list of `{name, value}` tuples)
    * `:access_token_type` — `:tenant_access_token` (default),
      `:app_access_token`, `:user_access_token`, or `nil` for no auth header
    * `:user_access_token` — if set, wins over any token-manager lookup
    * `:user_access_token_key` — if set, uses `FeishuOpenAPI.UserTokenManager`
      to inject a cached `user_access_token` and auto-refresh it when expired
    * `:tenant_key` — marketplace-app tenant id
    * `:req_options` — options merged into the `Req` call
    * `:form_multipart` — passed through to Req (use `FeishuOpenAPI.upload/3`)
    * `:raw` — return the raw `%Req.Response{}` instead of decoding
  """
  @spec request(Client.t(), atom(), String.t(), keyword()) ::
          {:ok, map()} | {:ok, Req.Response.t()} | {:error, Error.t()}
  def request(%Client{} = client, method, path, opts \\ []) do
    start_time = System.monotonic_time()
    start_meta = %{method: method, path: path, app_id: client.app_id}
    previous_metadata = Logger.metadata()

    :telemetry.execute(
      [:feishu_openapi, :request, :start],
      %{system_time: System.system_time()},
      start_meta
    )

    Logger.metadata(
      feishu_app_id: client.app_id,
      feishu_method: method,
      feishu_path: path,
      feishu_log_id: nil
    )

    # Logger metadata is process-local. The request wrapper restores the previous
    # metadata so callers using the same process do not leak Feishu labels into
    # unrelated logs.
    try do
      result = do_request(client, method, path, opts, token_retries: 0, rate_retries: 0)

      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:feishu_openapi, :request, :stop],
        %{duration: duration},
        Map.merge(start_meta, result_meta(result))
      )

      result
    catch
      kind, reason ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:feishu_openapi, :request, :exception],
          %{duration: duration},
          Map.merge(start_meta, %{kind: kind, reason: reason, stacktrace: __STACKTRACE__})
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      Logger.reset_metadata(previous_metadata)
    end
  end

  defp do_request(%Client{} = client, method, path, opts, retry_state) do
    with {:ok, spec} <- Spec.build(method, path, opts) do
      do_send(client, spec, path, retry_state)
    end
  end

  # Sends a Spec and processes the response. Called on retries without
  # rebuilding the Spec (its method/path/body are stable across retries; only
  # the auth header is re-resolved via `Request.build/2`).
  defp do_send(%Client{} = client, %Spec{} = spec, original_path, retry_state) do
    with {:ok, req_opts} <- Request.build(client, spec) do
      req_opts
      |> Req.request()
      |> process_response(client, spec, original_path, retry_state)
    end
  end

  defp bang({:ok, result}), do: result
  defp bang({:error, %Error{} = err}), do: raise(err)

  defp result_meta({:ok, %Req.Response{status: status} = resp}) do
    %{status: status, log_id: log_id_from(resp), outcome: :ok}
  end

  defp result_meta({:ok, %{"code" => code}}) do
    %{code: code, outcome: :ok}
  end

  defp result_meta({:ok, _other}), do: %{outcome: :ok}

  defp result_meta({:error, %Error{code: code, http_status: status, log_id: log_id}}) do
    %{status: status, log_id: log_id, code: code, outcome: :error}
  end

  @doc """
  Upload helper for the handful of Feishu endpoints that take multipart bodies.

      FeishuOpenAPI.upload(client, "/open-apis/im/v1/files",
        fields: [file_type: "mp4", file_name: "x.mp4"],
        file: {:path, "/tmp/x.mp4"})

  The `:file` option accepts:
    * `{:path, "/abs/path"}` — reads the file from disk, filename inferred
    * `{:path, "/abs/path", "override.ext"}` — override the filename
    * `{:iodata, iodata_or_binary, "name.ext"}` — in-memory content

  All other `opts` are forwarded to `request/4`.
  """
  @spec upload(Client.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def upload(%Client{} = client, path, opts) do
    with {:ok, fields} <- build_multipart_fields(Keyword.get(opts, :fields, [])),
         {:ok, file_part} <- build_file_part(Keyword.fetch!(opts, :file)) do
      forwarded =
        opts
        |> Keyword.drop([:fields, :file, :body])
        |> Keyword.put(:form_multipart, fields ++ [file_part])

      request(client, :post, path, forwarded)
    end
  end

  @doc """
  Download helper for the handful of binary-returning endpoints.

      {:ok, %{body: bin, filename: name, headers: h}} =
        FeishuOpenAPI.download(client, "/open-apis/im/v1/files/:file_key",
          path_params: %{file_key: "file_xxx"})
  """
  @spec download(Client.t(), String.t(), keyword()) ::
          {:ok,
           %{
             body: binary(),
             filename: String.t() | nil,
             headers: list() | map(),
             status: integer()
           }}
          | {:error, Error.t()}
  def download(%Client{} = client, path, opts \\ []) do
    case request(client, :get, path, Keyword.put(opts, :raw, true)) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}}
      when status in 200..299 ->
        {:ok,
         %{
           body: body,
           filename: filename_from_headers(headers),
           headers: headers,
           status: status
         }}

      {:ok, %Req.Response{status: status, body: body} = resp} ->
        maybe_error_from_body(body, resp, status)

      {:error, _} = err ->
        err
    end
  end

  # --- internals -----------------------------------------------------------

  defp log_id_from(%Req.Response{} = resp), do: fetch_header(resp, "x-tt-logid")
  defp log_id_from(_), do: nil

  # Case-insensitive header lookup that handles Req's two shapes:
  #   * `%{"name" => ["value"]}` / `%{"name" => "value"}` (map-of-lists or singletons)
  #   * `[{"name", "value"}]` / `[{"name", ["value", ...]}]` (list of tuples)
  defp fetch_header(%Req.Response{headers: headers}, name), do: fetch_header(headers, name)

  defp fetch_header(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [v | _] -> v
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp fetch_header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {k, [v | _]} when is_binary(k) or is_atom(k) ->
        if String.downcase(to_string(k)) == name, do: v

      {k, v} when (is_binary(k) or is_atom(k)) and is_binary(v) ->
        if String.downcase(to_string(k)) == name, do: v

      _ ->
        nil
    end)
  end

  defp fetch_header(_, _), do: nil

  defp process_response({:ok, %Req.Response{} = resp}, client, %Spec{} = spec, path, retry_state) do
    log_id = log_id_from(resp)
    if log_id, do: Logger.metadata(feishu_log_id: log_id)

    resp = maybe_decode_json_body(resp, spec)

    cond do
      spec.raw ->
        # Raw mode is used for downloads and unusual endpoints. It must bypass
        # envelope handling so binary bodies and nonstandard success shapes survive.
        {:ok, resp}

      rate_limited?(resp) ->
        handle_rate_limited(resp, client, spec, path, retry_state)

      true ->
        decode_envelope(resp, client, spec, path, retry_state)
    end
  end

  defp process_response({:error, reason}, _client, _spec, _path, _retry_state) do
    {:error, Error.transport(reason)}
  end

  defp maybe_decode_json_body(resp, %Spec{raw: true}), do: resp
  defp maybe_decode_json_body(resp, %Spec{}), do: decode_json_body(resp)

  defp decode_json_body(%Req.Response{body: body} = resp) when is_binary(body) do
    case Torque.decode(body) do
      {:ok, decoded} -> %{resp | body: decoded}
      {:error, _reason} -> resp
    end
  end

  defp decode_json_body(%Req.Response{} = resp), do: resp

  # Feishu signals rate limits in three shapes:
  #   * HTTP 429 with body code 99991400 (current style)
  #   * HTTP 400 with body code 99991400 (legacy endpoints)
  #   * HTTP 200 with body code 99991400 (edge case, seen in practice)
  # Either way, an `x-ogw-ratelimit-reset` header (seconds) tells us how long to wait.
  defp rate_limited?(%Req.Response{status: 429}), do: true
  defp rate_limited?(%Req.Response{body: %{"code" => @rate_limit_code}}), do: true
  defp rate_limited?(_), do: false

  defp handle_rate_limited(%Req.Response{} = resp, client, %Spec{} = spec, path, retry_state) do
    {delay_ms, source} = rate_limit_delay(resp)

    if Keyword.get(retry_state, :rate_retries, 0) < @max_retry_after_retries do
      :telemetry.execute(
        [:feishu_openapi, :request, :rate_limited],
        %{delay_ms: delay_ms},
        %{
          method: spec.method,
          path: path,
          app_id: client.app_id,
          http_status: resp.status,
          source: source,
          limit: ratelimit_limit(resp),
          log_id: log_id_from(resp)
        }
      )

      # This SDK retries only once. Provider rate limits are usually short, but
      # hiding a longer outage behind many sleeps would make callers harder to
      # reason about.
      :timer.sleep(delay_ms)

      do_send(client, spec, path, Keyword.update(retry_state, :rate_retries, 1, &(&1 + 1)))
    else
      {:error,
       %Error{
         code: :rate_limited,
         msg: "rate limited (#{rate_limit_msg_context(resp, source)}) after retry",
         http_status: resp.status,
         log_id: log_id_from(resp),
         raw_body: resp.body
       }}
    end
  end

  defp rate_limit_msg_context(
         %Req.Response{status: status, body: %{"code" => @rate_limit_code}},
         _
       ),
       do: "HTTP #{status}, code #{@rate_limit_code}"

  defp rate_limit_msg_context(%Req.Response{status: status}, _), do: "HTTP #{status}"

  # Prefer Feishu's `x-ogw-ratelimit-reset` over the generic `Retry-After`;
  # fall back to a small default if neither is present.
  defp rate_limit_delay(%Req.Response{} = resp) do
    {raw_value, source} =
      case fetch_header(resp, "x-ogw-ratelimit-reset") do
        nil ->
          case fetch_header(resp, "retry-after") do
            nil -> {nil, :default}
            v -> {v, :retry_after}
          end

        v ->
          {v, :x_ogw_ratelimit_reset}
      end

    {raw_value |> parse_retry_after() |> clamp_delay(), source}
  end

  defp ratelimit_limit(%Req.Response{} = resp) do
    case fetch_header(resp, "x-ogw-ratelimit-limit") do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {n, _} -> n
          _ -> nil
        end
    end
  end

  defp parse_retry_after(nil), do: @default_retry_after_ms

  defp parse_retry_after(v) when is_binary(v) do
    case Integer.parse(v) do
      {seconds, _} when seconds > 0 -> :timer.seconds(seconds)
      {0, _} -> 0
      _ -> @default_retry_after_ms
    end
  end

  defp parse_retry_after(_), do: @default_retry_after_ms

  defp clamp_delay(ms) when is_integer(ms) and ms > @max_retry_after_ms, do: @max_retry_after_ms
  defp clamp_delay(ms) when is_integer(ms) and ms >= 0, do: ms
  defp clamp_delay(_), do: @default_retry_after_ms

  defp decode_envelope(
         %Req.Response{status: status, body: body} = resp,
         client,
         %Spec{} = spec,
         path,
         retry_state
       ) do
    case body do
      %{"code" => 0} = decoded ->
        {:ok, decoded}

      %{"code" => c} when c in @token_invalid_codes ->
        # Only retry on stale-token codes when the SDK actually manages a
        # token for this request. Auth endpoints (access_token_type: nil) and
        # explicit-bearer requests have nothing to invalidate, so retrying
        # would be wasted and could recurse into the auth pipeline.
        cond do
          not Spec.auth_managed?(spec) ->
            {:error, Error.from_response(body, resp)}

          Keyword.get(retry_state, :token_retries, 0) >= @max_token_invalid_retries ->
            {:error, Error.from_response(body, resp)}

          true ->
            invalidate_for_retry(client, spec)

            do_send(
              client,
              spec,
              path,
              Keyword.update(retry_state, :token_retries, 1, &(&1 + 1))
            )
        end

      %{"code" => @app_ticket_invalid_code} ->
        # Skip app_ticket recovery on auth endpoints — they don't use
        # app_ticket-backed tokens, and recovery would recurse back into auth.
        if Spec.auth_managed?(spec), do: _ = maybe_recover_app_ticket(client)
        {:error, Error.from_response(body, resp)}

      %{"code" => _} ->
        {:error, Error.from_response(body, resp)}

      _ when status in 200..299 ->
        # Not a JSON envelope (e.g. binary body); surface the raw response.
        {:ok, resp}

      _ ->
        {:error, http_error(resp, status, body)}
    end
  end

  # Called when a response body carries `"code": 10012` (app_ticket_invalid).
  # For marketplace apps, drop the cached ticket and ask Feishu to re-push a fresh
  # one. Self-built apps never use app_ticket, so we skip the work.
  defp maybe_recover_app_ticket(%Client{app_type: :marketplace} = client) do
    Logger.warning(fn ->
      "feishu_openapi received code 10012 (app_ticket_invalid) for app #{client.app_id}; " <>
        "invalidating cached ticket and triggering async resend"
    end)

    TokenManager.invalidate_app_ticket(client)
    TokenManager.async_resend_app_ticket(client)
    :ok
  end

  defp maybe_recover_app_ticket(_client), do: :ok

  defp invalidate_for_retry(client, %Spec{} = spec) do
    cond do
      is_binary(spec.user_access_token) ->
        :ok

      spec.access_token_type == :user_access_token ->
        :ok

      spec.access_token_type == :app_access_token ->
        TokenManager.invalidate(client, :app)

      spec.access_token_type == :tenant_access_token ->
        TokenManager.invalidate(client, :tenant, spec.tenant_key)

      true ->
        :ok
    end
  end

  defp build_file_part({:path, path}) do
    build_streaming_file_part(path, Path.basename(path))
  end

  defp build_file_part({:path, path, name}) do
    build_streaming_file_part(path, name)
  end

  defp build_file_part({:iodata, data, name}),
    do: {:ok, {:file, {IO.iodata_to_binary(data), filename: name}}}

  defp build_streaming_file_part(path, name) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        # Req can stream regular files with a known size. Rejecting directories
        # and special files avoids hanging uploads or provider-side body errors.
        {:ok, {:file, {File.stream!(path, 64_000, []), filename: name, size: size}}}

      {:ok, %File.Stat{type: type}} ->
        {:error,
         %Error{
           code: :bad_file,
           msg: "expected a regular file, got #{inspect(type)}",
           details: type
         }}

      {:error, reason} ->
        {:error, %Error{code: :bad_file, msg: format_file_error(reason), details: reason}}
    end
  end

  defp build_multipart_fields(fields) when is_list(fields) do
    fields
    |> Enum.map(&build_multipart_field/1)
    |> collect_results()
  end

  defp build_multipart_fields(_fields), do: {:error, Error.transport(:invalid_multipart_fields)}

  defp build_multipart_field({name, value}) when is_atom(name),
    do: {:ok, {name, to_string(value)}}

  defp build_multipart_field({name, value}) when is_binary(name) do
    case Map.fetch(@multipart_field_names, name) do
      # Binary field names are accepted only from a small allowlist. Multipart
      # part names are atoms in Req, and dynamic atom creation is not acceptable.
      {:ok, atom_name} -> {:ok, {atom_name, to_string(value)}}
      :error -> {:error, Error.transport({:invalid_multipart_field_name, name})}
    end
  end

  defp build_multipart_field(_field), do: {:error, Error.transport(:invalid_multipart_field)}

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  defp filename_from_headers(headers) when is_map(headers) do
    headers
    |> Map.get("content-disposition", [])
    |> List.wrap()
    |> List.first()
    |> parse_filename()
  end

  defp filename_from_headers(headers) when is_list(headers) do
    Enum.find_value(headers, fn
      {k, v} when is_binary(k) ->
        if String.downcase(k) == "content-disposition", do: parse_filename(v)

      _ ->
        nil
    end)
  end

  defp filename_from_headers(_), do: nil

  defp parse_filename(nil), do: nil

  defp parse_filename(value) when is_binary(value) do
    case Regex.run(~r/filename\*?=(?:UTF-8'')?"?([^";]+)"?/i, value) do
      [_, name] -> URI.decode(name)
      _ -> nil
    end
  end

  defp maybe_error_from_body(body, resp, status) when is_map(body) do
    case body do
      %{"code" => _} -> {:error, Error.from_response(body, resp)}
      _ -> {:error, http_error(resp, status, body)}
    end
  end

  defp maybe_error_from_body(body, resp, status),
    do: {:error, http_error(resp, status, body)}

  defp http_error(resp, status, body) do
    %Error{
      code: :http_error,
      msg: "HTTP #{status}",
      http_status: status,
      log_id: log_id_from(resp),
      raw_body: body
    }
  end

  defp format_file_error(reason) do
    reason
    |> :file.format_error()
    |> to_string()
  end
end
