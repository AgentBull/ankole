defmodule Ankole.Connectors.HTTP do
  @moduledoc "HTTP execution for declared REST operations, with bounded JSON and streaming file transfers."
  alias Ankole.Connectors.ToolSpec
  alias Ankole.Files.HTTP

  def call(%ToolSpec{operation: operation} = tool, args, base_url, headers, opts \\ []) do
    with {:ok, url, body} <- request_parts(operation, args, base_url),
         {:ok, response} <-
           HTTP.request(
             operation["method"],
             url,
             headers,
             encode_body(body),
             opts
             |> Keyword.put(:idempotent, ToolSpec.retry_safe?(tool))
             |> Keyword.put_new(:timeout, 30_000)
           ) do
      case decode(response, idempotent: ToolSpec.retry_safe?(tool)) do
        {:error, error} -> {:error, redact_credentials(error, headers)}
        result -> result
      end
    end
  end

  def request_parts(operation, args, base_url) do
    path_keys =
      Regex.scan(~r/:([a-z_][a-z0-9_]*)/, operation["path"], capture: :all_but_first)
      |> List.flatten()

    segments = operation["path_segments"] || []

    invalid =
      Enum.find(path_keys, fn key ->
        not Map.has_key?(args, key) or not valid_path?(args[key], key in segments)
      end)

    case invalid do
      nil ->
        path =
          Regex.replace(~r/:([a-z_][a-z0-9_]*)/, operation["path"], fn _, key ->
            value = to_string(args[key])

            if key in segments,
              do:
                value
                |> String.split("/")
                |> Enum.map_join("/", fn segment ->
                  URI.encode(segment, &URI.char_unreserved?/1)
                end),
              else: URI.encode(value, &URI.char_unreserved?/1)
          end)

        query_keys = operation["query"] || []

        query =
          args
          |> Map.take(query_keys)
          |> Enum.reject(fn {_, value} -> is_nil(value) end)
          |> Enum.flat_map(fn
            {key, values} when is_list(values) -> Enum.map(values, &{key, &1})
            pair -> [pair]
          end)
          |> URI.encode_query()

        url =
          String.trim_trailing(base_url, "/") <>
            path <> if(query == "", do: "", else: "?" <> query)

        body =
          if operation["method"] in ["GET", "HEAD"],
            do: nil,
            else: Map.drop(args, path_keys ++ query_keys ++ ["resource_scope"])

        {:ok, url, body}

      key ->
        {:error, %{code: "invalid_arguments", field: key, retryable: false, request_sent: false}}
    end
  end

  defp valid_path?("", true), do: true

  defp valid_path?(value, multiple?) do
    parts = if multiple?, do: String.split(to_string(value), "/"), else: [to_string(value)]
    Enum.all?(parts, &(&1 not in ["", ".", ".."]))
  end

  def decode(response, opts \\ [])

  def decode(%{status: status, body: body, headers: headers}, _opts) when status in 200..299 do
    cond do
      body == "" ->
        {:ok, %{}}

      true ->
        case Torque.decode(body) do
          {:ok, result} ->
            {:ok, result}

          {:error, _} ->
            {:error,
             %{
               code: "invalid_upstream_response",
               status: status,
               retryable: false,
               content_type: header(headers, "content-type")
             }}
        end
    end
  end

  def decode(%{status: status, headers: headers} = response, opts) do
    unknown? = status >= 500 and not Keyword.get(opts, :idempotent, false)

    {:error,
     %{
       code:
         cond do
           unknown? -> "upstream_outcome_unknown"
           status == 429 -> "upstream_rate_limited"
           true -> "upstream_rejected"
         end,
       status: status,
       request_sent: true,
       details: error_body(Map.get(response, :body, "")),
       retryable: not unknown? and (status == 429 or status >= 500),
       retryAfterSeconds: retry_after(header(headers, "retry-after"))
     }}
  end

  defp error_body(""), do: nil

  defp error_body(body) do
    case Torque.decode(body) do
      {:ok, details} -> details
      _ -> body
    end
  end

  @doc false
  def redact_credentials(value, headers) do
    secrets =
      Enum.flat_map(headers, fn {name, secret} ->
        if String.downcase(name) in [
             "authorization",
             "proxy-authorization",
             "x-api-key",
             "api-key"
           ] do
          [secret, String.replace_prefix(secret, "Bearer ", "")]
        else
          []
        end
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    redact(value, secrets)
  end

  defp redact(value, secrets) when is_binary(value),
    do: Enum.reduce(secrets, value, &String.replace(&2, &1, "[REDACTED]"))

  defp redact(value, secrets) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, redact(item, secrets)} end)

  defp redact(value, secrets) when is_list(value), do: Enum.map(value, &redact(&1, secrets))
  defp redact(value, _), do: value

  defp encode_body(nil), do: nil
  defp encode_body(body), do: Torque.encode!(body)

  defp header(headers, key),
    do:
      Enum.find_value(headers, fn {name, value} -> if String.downcase(name) == key, do: value end)

  defp retry_after(nil), do: nil

  defp retry_after(value) do
    case Integer.parse(value) do
      {seconds, ""} -> max(seconds, 0)
      _ -> nil
    end
  end
end
