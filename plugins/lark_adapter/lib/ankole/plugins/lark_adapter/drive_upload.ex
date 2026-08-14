defmodule Ankole.Plugins.LarkAdapter.DriveUpload do
  @moduledoc false

  alias Ankole.Logging
  alias FeishuOpenAPI.Client
  alias FeishuOpenAPI.Error

  @telemetry_event [:ankole, :lark_adapter, :large_file_upload]
  @upload_part_interval_ms 200

  @type recipient :: %{
          required(:member_type) => String.t(),
          required(:member_id) => String.t()
        }

  @type upload_result :: %{
          file_token: String.t(),
          url: String.t(),
          block_num: pos_integer()
        }

  @spec upload(Client.t(), binary(), String.t(), recipient(), map()) ::
          {:ok, upload_result()} | {:error, term()}
  def upload(
        %Client{} = client,
        content,
        name,
        %{member_type: member_type, member_id: member_id} = recipient,
        context
      )
      when is_binary(content) and byte_size(content) > 0 and is_binary(name) and
             is_binary(member_type) and is_binary(member_id) and is_map(context) do
    started_at = System.monotonic_time()
    size = byte_size(content)
    log_started(context, size, member_type)

    result =
      run_upload(client, content, name, recipient, context)

    observe_result(result, context, size, member_type, started_at)
    result
  end

  defp run_upload(client, content, name, recipient, context) do
    size = byte_size(content)

    with {:ok, root_token} <- root_folder_token(client),
         {:ok, upload} <- prepare_upload(client, root_token, name, size),
         :ok <- upload_parts(client, content, name, upload),
         {:ok, file_token} <- finish_upload(client, upload) do
      authorize_and_resolve_url(client, file_token, recipient, upload.block_num, context)
    end
  end

  defp root_folder_token(client) do
    case FeishuOpenAPI.get(client, "drive/explorer/v2/root_folder/meta") do
      {:ok, %{"data" => %{"token" => token}}} when is_binary(token) and token != "" ->
        {:ok, token}

      {:ok, _body} ->
        upload_error(:root_folder, :invalid_response)

      {:error, reason} ->
        upload_error(:root_folder, reason)
    end
  end

  defp prepare_upload(client, root_token, name, size) do
    result =
      FeishuOpenAPI.post(client, "drive/v1/files/upload_prepare",
        body: %{
          file_name: name,
          parent_type: "explorer",
          parent_node: root_token,
          size: size
        }
      )

    case result do
      {:ok,
       %{
         "data" => %{
           "upload_id" => upload_id,
           "block_size" => block_size,
           "block_num" => block_num
         }
       }}
      when is_binary(upload_id) and upload_id != "" and is_integer(block_size) and
             block_size > 0 and is_integer(block_num) and block_num > 0 ->
        expected_block_num = div(size + block_size - 1, block_size)

        if block_num == expected_block_num do
          {:ok, %{upload_id: upload_id, block_size: block_size, block_num: block_num}}
        else
          upload_error(:prepare, :invalid_block_plan)
        end

      {:ok, _body} ->
        upload_error(:prepare, :invalid_response)

      {:error, reason} ->
        upload_error(:prepare, reason)
    end
  end

  defp upload_parts(client, content, name, upload) do
    0..(upload.block_num - 1)
    |> Enum.reduce_while(:ok, fn sequence, :ok ->
      offset = sequence * upload.block_size
      size = min(upload.block_size, byte_size(content) - offset)
      chunk = binary_part(content, offset, size)

      case FeishuOpenAPI.upload(client, "drive/v1/files/upload_part",
             fields: [upload_id: upload.upload_id, seq: sequence, size: size],
             file: {:iodata, chunk, name}
           ) do
        {:ok, _body} ->
          maybe_wait_for_next_part(sequence, upload.block_num)
          {:cont, :ok}

        {:error, reason} ->
          {:halt, upload_error(:part, reason)}
      end
    end)
  end

  defp maybe_wait_for_next_part(sequence, block_num) when sequence + 1 < block_num,
    do: Process.sleep(@upload_part_interval_ms)

  defp maybe_wait_for_next_part(_sequence, _block_num), do: :ok

  defp finish_upload(client, upload) do
    case FeishuOpenAPI.post(client, "drive/v1/files/upload_finish",
           body: %{upload_id: upload.upload_id, block_num: upload.block_num}
         ) do
      {:ok, %{"data" => %{"file_token" => file_token}}}
      when is_binary(file_token) and file_token != "" ->
        {:ok, file_token}

      {:ok, _body} ->
        upload_error(:finish, :invalid_response)

      {:error, reason} ->
        upload_error(:finish, reason)
    end
  end

  defp authorize_and_resolve_url(client, file_token, recipient, block_num, context) do
    with :ok <- grant_view_access(client, file_token, recipient),
         {:ok, url} <- fetch_file_url(client, file_token) do
      {:ok, %{file_token: file_token, url: url, block_num: block_num}}
    else
      {:error, _reason} = error ->
        cleanup_file(client, file_token, context)
        error
    end
  end

  defp grant_view_access(client, file_token, recipient) do
    case FeishuOpenAPI.post(client, "drive/v1/permissions/:token/members",
           path_params: %{token: file_token},
           query: [type: "file", need_notification: false],
           body: %{
             member_type: recipient.member_type,
             member_id: recipient.member_id,
             perm: "view",
             type: collaborator_type(recipient.member_type)
           }
         ) do
      {:ok, _body} -> :ok
      {:error, reason} -> upload_error(:grant, reason)
    end
  end

  defp collaborator_type("openchat"), do: "chat"
  defp collaborator_type("openid"), do: "user"

  defp fetch_file_url(client, file_token) do
    result =
      FeishuOpenAPI.post(client, "drive/v1/metas/batch_query",
        body: %{
          request_docs: [%{doc_token: file_token, doc_type: "file"}],
          with_url: true
        }
      )

    case result do
      {:ok, %{"data" => %{"metas" => metas}}} when is_list(metas) ->
        case Enum.find_value(metas, &valid_url/1) do
          url when is_binary(url) -> {:ok, url}
          nil -> upload_error(:metadata, :missing_url)
        end

      {:ok, _body} ->
        upload_error(:metadata, :invalid_response)

      {:error, reason} ->
        upload_error(:metadata, reason)
    end
  end

  defp valid_url(%{"url" => url}) when is_binary(url) do
    case String.trim(url) do
      "" -> nil
      url -> url
    end
  end

  defp valid_url(_meta), do: nil

  defp cleanup_file(client, file_token, context) do
    case FeishuOpenAPI.delete(client, "drive/v1/files/:file_token",
           path_params: %{file_token: file_token},
           query: [type: "file"]
         ) do
      {:ok, _body} ->
        :ok

      {:error, reason} ->
        Logging.warning(
          "lark_adapter.outbox.large_file_cleanup_failed",
          "lark adapter could not clean up an undeliverable cloud file",
          log_context(context, %{
            failure_code: error_code(reason)
          })
        )
    end
  end

  defp upload_error(stage, reason),
    do: {:error, {:large_file_upload_failed, stage, reason}}

  defp observe_result(result, context, size, member_type, started_at) do
    duration = System.monotonic_time() - started_at
    {outcome, stage, block_num, failure_code} = result_observation(result)

    :telemetry.execute(
      @telemetry_event,
      %{duration: duration, size_bytes: size, block_count: block_num},
      %{
        adapter: "lark",
        outcome: outcome,
        stage: stage,
        fallback_reason: Map.get(context, :fallback_reason),
        member_type: member_type
      }
    )

    fields =
      log_context(context, %{
        size_bytes: size,
        block_count: block_num,
        member_type: member_type,
        stage: stage,
        failure_code: failure_code,
        duration_ms: System.convert_time_unit(duration, :native, :millisecond)
      })

    case outcome do
      :success ->
        Logging.info(
          "lark_adapter.outbox.large_file_upload_completed",
          "lark adapter uploaded a large file to cloud space",
          fields
        )

      :failure ->
        Logging.warning(
          "lark_adapter.outbox.large_file_upload_failed",
          "lark adapter could not upload a large file to cloud space",
          fields
        )
    end
  end

  defp result_observation({:ok, %{block_num: block_num}}),
    do: {:success, :completed, block_num, nil}

  defp result_observation({:error, {:large_file_upload_failed, stage, reason}}),
    do: {:failure, stage, 0, error_code(reason)}

  defp error_code(%Error{code: code}) when is_integer(code) or is_atom(code), do: code
  defp error_code(reason) when is_atom(reason), do: reason
  defp error_code(_reason), do: nil

  defp log_started(context, size, member_type) do
    Logging.info(
      "lark_adapter.outbox.large_file_upload_started",
      "lark adapter started a large file cloud upload",
      log_context(context, %{size_bytes: size, member_type: member_type})
    )
  end

  defp log_context(context, fields) do
    Map.merge(
      fields,
      Map.take(context, [
        :agent_uid,
        :binding_name,
        :outbound_key,
        :operation,
        :fallback_reason
      ])
    )
  end
end
