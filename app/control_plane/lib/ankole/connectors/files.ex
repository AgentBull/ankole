defmodule Ankole.Connectors.Files do
  @moduledoc "Streaming multipart uploads and Pod file references for connector tools."
  alias Ankole.Files.HTTP
  @chunk_bytes 8 * 1024 * 1024

  def multipart(actor, file_ref, url, headers, fields, file_field, file_name, opts \\ []) do
    with {:ok, page, path} <- Ankole.Pod.Files.parse_path(file_ref),
         {:ok, file} <- Ankole.Pod.Files.resolve_read(actor, page, path),
         {:ok, object} <- Ankole.Files.fetch_object(file.object_id) do
      boundary = "ankole-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

      prefix =
        Enum.map(fields, fn {name, value} ->
          [
            "--",
            boundary,
            "\r\nContent-Disposition: form-data; name=\"",
            quote_part(name),
            "\"\r\n\r\n",
            to_string(value),
            "\r\n"
          ]
        end) ++
          [
            [
              "--",
              boundary,
              "\r\nContent-Disposition: form-data; name=\"",
              quote_part(file_field),
              "\"; filename=\"",
              quote_part(file_name),
              "\"\r\nContent-Type: application/octet-stream\r\n\r\n"
            ]
          ]

      suffix = "\r\n--" <> boundary <> "--\r\n"

      chunks =
        Stream.unfold(0, fn
          offset when offset >= file.size ->
            nil

          offset ->
            case Ankole.Files.read_object_range(object, offset, @chunk_bytes) do
              {:ok, bytes} when byte_size(bytes) > 0 -> {bytes, offset + byte_size(bytes)}
              {:error, reason} -> raise HTTP.Error, reason: reason
            end
        end)

      body = Stream.concat([[IO.iodata_to_binary(prefix)], chunks, [suffix]])
      length = IO.iodata_length(prefix) + file.size + byte_size(suffix)

      headers = [
        {"content-type", "multipart/form-data; boundary=" <> boundary},
        {"content-length", to_string(length)} | headers
      ]

      HTTP.request("POST", url, headers, body, opts)
    end
  end

  def download(actor, url, headers, destination, opts \\ []) do
    with {:ok, %{page_id: page_id, file: file}} <-
           HTTP.download(
             actor,
             url,
             headers,
             %{
               page_id: destination["page_id"],
               role: destination["role"],
               name: destination["name"],
               content_type: destination["content_type"],
               base_object_id: destination["base_object_id"]
             },
             opts
           ) do
      {:ok,
       %{
         "file_ref" => "pages/" <> page_id <> "/" <> file.path,
         "size" => file.size,
         "content_type" => file.content_type
       }}
    end
  end

  defp quote_part(value),
    do:
      value
      |> to_string()
      |> String.replace("\r", "")
      |> String.replace("\n", "")
      |> String.replace("\"", "%22")
end
