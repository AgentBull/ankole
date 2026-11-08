defmodule Ankole.Pod.Applets.AI do
  @moduledoc "Stateless Applet text and image generation through Pod model profiles."

  alias Ankole.AIGateway
  alias Ankole.AIGateway.Artifacts
  alias Ankole.AIGateway.Artifacts.Image
  alias Ankole.AIGateway.OpenAIError
  alias Ankole.AIGateway.ReasoningEffort
  alias Ankole.AIGateway.ResponseItems
  alias Ankole.Pod.Access
  alias Ankole.Pod.{Files, Pages}

  @profiles ~w(primary light heavy coding vision_fallback)
  @max_image_references 8
  @image_option_keys ~w(
    prompt images mask action size quality background outputFormat
    outputCompression moderation inputFidelity saveTo
  )

  def generate_text(%Ankole.AuthZ.Actor{} = actor, options) do
    with {:ok, principal} <-
           Access.write(actor.turn_authority, fn ->
             Access.principal(actor)
           end) do
      do_generate_text(principal, options)
    end
  end

  defp do_generate_text(principal, options) do
    with :ok <- profile(options["model"]),
         :ok <- prompt(options),
         {:ok, _effort} <- ReasoningEffort.normalize(options["effort"]),
         {:ok, %{body: body}} <-
           AIGateway.create_response(principal.uid, request(options),
             caller: "pod_applet",
             request_context: human_context(principal)
           ),
         {:ok, reason} <- finish_reason(body) do
      usage = body["usage"] || %{}

      {:ok,
       %{
         text: output_text(body),
         finishReason: reason,
         usage: %{
           inputTokens: usage["input_tokens"] || 0,
           outputTokens: usage["output_tokens"] || 0
         }
       }}
    else
      {:error, reason} ->
        {:error,
         %{status: status(reason), code: code(reason), message: code(reason), details: nil}}
    end
  end

  def generate_image(page, actor, options, opts \\ [])

  def generate_image(%{id: applet_page_id}, %Ankole.AuthZ.Actor{} = actor, options, opts)
      when is_map(options) and is_list(opts) do
    with {:ok, principal} <-
           Access.write(actor.turn_authority, fn ->
             Access.principal(actor)
           end),
         {:ok, validated} <- validate_image_options(options),
         {:ok, destination} <-
           authorize_image_destination(actor, applet_page_id, validated.save_to),
         {:ok, image_urls} <- resolve_pod_image_paths(actor, validated.images),
         {:ok, mask_url} <- resolve_optional_pod_image_path(actor, validated.mask),
         gateway_req = build_gateway_image_request(validated, image_urls, mask_url),
         {:ok, body} <- create_gateway_image(principal, gateway_req),
         {:ok, committed} <-
           commit_generated_image(
             actor,
             destination,
             body["bytes"],
             body["mime_type"]
           ) do
      usage = body["usage"] || %{}

      result = %{
        url: file_content_url(committed.page_id, committed.file.path, opts[:authentication_ref]),
        mimeType: body["mime_type"],
        file: %{
          path: "pages/#{committed.page_id}/#{committed.file.path}",
          objectId: committed.file.object_id,
          sha256: committed.file.sha256,
          size: committed.file.size,
          contentType: committed.file.content_type,
          pageId: committed.page_id,
          name: committed.name,
          mime: committed.file.content_type || body["mime_type"]
        },
        usage: %{
          inputTokens: usage["input_tokens"] || 0,
          outputTokens: usage["output_tokens"] || 0,
          totalTokens:
            usage["total_tokens"] ||
              (usage["input_tokens"] || 0) + (usage["output_tokens"] || 0)
        }
      }

      result =
        if is_binary(body["revised_prompt"]) and body["revised_prompt"] != "",
          do: Map.put(result, :revisedPrompt, body["revised_prompt"]),
          else: result

      {:ok, result}
    else
      {:error, :invalid_request} ->
        {:error,
         %{status: 400, code: "invalid_request", message: "invalid_request", details: nil}}

      {:error, {:file_too_large, _, _}} ->
        {:error, :file_too_large}

      {:error, _reason} = error ->
        error
    end
  end

  def generate_image(_page, _actor, _options, _opts), do: {:error, :invalid_request}

  defp create_gateway_image(principal, gateway_req) do
    case AIGateway.create_image(principal.uid, gateway_req,
           caller: "pod_applet",
           request_context: human_context(principal)
         ) do
      {:ok, %{body: body}} ->
        {:ok, body}

      {:error, %OpenAIError{} = error} ->
        {:error, map_openai_image_error(error)}

      {:error, reason} ->
        {:error,
         %{status: status(reason), code: code(reason), message: code(reason), details: nil}}
    end
  end

  # The usage ledger attributes an Applet call of a Human to that Human.
  defp human_context(%{type: :human, uid: uid}), do: %{"human_uid" => uid}
  defp human_context(_principal), do: %{}

  defp profile(model) when model in @profiles, do: :ok
  defp profile(_), do: {:error, :invalid_model}

  defp prompt(%{"prompt" => prompt} = options) when is_binary(prompt) do
    if is_nil(options["system"]) or is_binary(options["system"]),
      do: :ok,
      else: {:error, :invalid_request}
  end

  defp prompt(_), do: {:error, :invalid_request}

  defp request(options) do
    %{"model" => options["model"], "input" => options["prompt"], "store" => false}
    |> then(fn request ->
      if options["system"], do: Map.put(request, "instructions", options["system"]), else: request
    end)
    |> then(fn request ->
      if options["effort"],
        do: Map.put(request, "reasoning", %{"effort" => options["effort"]}),
        else: request
    end)
  end

  defp finish_reason(%{"status" => "completed"}), do: {:ok, "stop"}

  defp finish_reason(%{
         "status" => "incomplete",
         "incomplete_details" => %{"reason" => "max_output_tokens"}
       }),
       do: {:ok, "length"}

  defp finish_reason(_), do: {:error, :ai_unavailable}

  defp output_text(%{"output_text" => text}) when is_binary(text), do: text

  defp output_text(%{"output" => output}) when is_list(output) do
    output
    |> ResponseItems.message_content_parts()
    |> Enum.filter(&match?(%{"type" => "output_text"}, &1))
    |> ResponseItems.text_parts()
    |> Enum.join("")
  end

  defp output_text(_), do: ""

  defp code(reason) when reason in [:ai_not_configured, :invalid_model, :invalid_request],
    do: Atom.to_string(reason)

  defp code({:reasoning_effort, _}), do: "invalid_effort"
  defp code({:agent_token_quota_exceeded, _}), do: "agent_token_quota_exceeded"

  defp code(%Ankole.AIGateway.ProviderFailure{
         provider_status: status,
         provider_body: %{"error" => %{"param" => param}}
       })
       when status in [400, 422] and
              param in ["reasoning.effort", "reasoning_effort", "reasoningEffort"],
       do: "invalid_effort"

  defp code(reason) when reason in [:model_profile_not_configured, :system_principal_missing],
    do: "ai_not_configured"

  defp code({name, _})
       when name in [
              :unknown_model_selector,
              :invalid_model_profile,
              :model_profile_capability_mismatch
            ],
       do: "invalid_model"

  defp code(:invalid_model_profile), do: "invalid_model"

  defp code(_), do: "ai_unavailable"

  defp status({:agent_token_quota_exceeded, _}), do: 429

  defp status(reason),
    do:
      if(code(reason) == "ai_unavailable",
        do: 502,
        else: if(code(reason) == "invalid_request", do: 400, else: 422)
      )

  defp validate_image_options(options) do
    unknown = Map.keys(options) -- @image_option_keys
    prompt_val = Map.get(options, "prompt")
    images = Map.get(options, "images")
    mask = Map.get(options, "mask")
    save_to = Map.get(options, "saveTo")

    cond do
      unknown != [] ->
        {:error, :invalid_request}

      not (is_binary(prompt_val) and String.trim(prompt_val) != "") ->
        {:error, :invalid_request}

      not valid_image_paths?(images) ->
        {:error, :invalid_request}

      not (is_nil(mask) or (is_binary(mask) and String.trim(mask) != "")) ->
        {:error, :invalid_request}

      not valid_save_to?(save_to) ->
        {:error, :invalid_request}

      true ->
        {:ok,
         %{
           prompt: prompt_val,
           images: images || [],
           mask: mask,
           save_to: save_to,
           raw: options
         }}
    end
  end

  defp valid_image_paths?(nil), do: true

  defp valid_image_paths?(images)
       when is_list(images) and length(images) <= @max_image_references do
    Enum.all?(images, &(is_binary(&1) and String.trim(&1) != ""))
  end

  defp valid_image_paths?(_images), do: false

  defp valid_save_to?(nil), do: true

  defp valid_save_to?(%{"pageId" => page_id} = save_to) when is_binary(page_id) do
    unknown = Map.keys(save_to) -- ["pageId", "name"]
    name = Map.get(save_to, "name")

    unknown == [] and match?({:ok, _}, Ecto.UUID.cast(page_id)) and
      (is_nil(name) or (is_binary(name) and String.trim(name) != ""))
  end

  defp valid_save_to?(_save_to), do: false

  defp authorize_image_destination(actor, applet_page_id, nil) do
    with {:ok, _page} <- Pages.authorize(actor, applet_page_id, "node_view", trash: false) do
      {:ok, {:applet_asset, applet_page_id, nil, "node_view"}}
    end
  end

  defp authorize_image_destination(actor, _applet_page_id, %{"pageId" => target_id} = save_to) do
    with {:ok, target_page} <- Pages.authorize(actor, target_id, "node_view", trash: false) do
      case target_page.type do
        :applet ->
          with {:ok, _} <- Pages.authorize(actor, target_id, "node_edit", trash: false) do
            {:ok, {:applet_asset, target_id, Map.get(save_to, "name"), "node_edit"}}
          end

        type ->
          with {:ok, role} <- upload_role(type),
               {:ok, _} <- Files.authorize_upload(actor, target_id, role) do
            {:ok, {:upload, target_id, role, Map.get(save_to, "name")}}
          end
      end
    end
  end

  defp upload_role(:file), do: {:ok, "file"}
  defp upload_role(:doc), do: {:ok, "asset"}
  defp upload_role(:knowledge), do: {:ok, "asset"}
  defp upload_role(:base), do: {:ok, "attachment"}
  defp upload_role(_), do: {:error, :invalid_file_role}

  defp resolve_pod_image_paths(_actor, []), do: {:ok, []}

  defp resolve_pod_image_paths(actor, paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case resolve_pod_image_data_url(actor, path) do
        {:ok, data_url} -> {:cont, {:ok, [data_url | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, urls} -> {:ok, Enum.reverse(urls)}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_optional_pod_image_path(_actor, nil), do: {:ok, nil}
  defp resolve_optional_pod_image_path(actor, path), do: resolve_pod_image_data_url(actor, path)

  defp resolve_pod_image_data_url(actor, path) do
    with {:ok, page_id, relative} <- Files.parse_path(path),
         {:ok, _entry, bytes} <-
           Files.read(actor, page_id, relative, nil, max_bytes: Artifacts.max_image_bytes()),
         {:ok, mime_type} <- sniff_pod_image(bytes) do
      {:ok, "data:#{mime_type};base64,#{Base.encode64(bytes)}"}
    end
  end

  defp sniff_pod_image(bytes) do
    case Image.sniff(bytes) do
      {:ok, mime_type} -> {:ok, mime_type}
      {:error, _} -> {:error, :invalid_request}
    end
  end

  defp build_gateway_image_request(validated, image_urls, mask_url) do
    raw = validated.raw

    %{
      "prompt" => validated.prompt,
      "images" => image_urls
    }
    |> maybe_put_gateway("mask", mask_url)
    |> maybe_put_gateway("action", raw["action"])
    |> maybe_put_gateway("size", raw["size"])
    |> maybe_put_gateway("quality", raw["quality"])
    |> maybe_put_gateway("background", raw["background"])
    |> maybe_put_gateway("output_format", raw["outputFormat"])
    |> maybe_put_gateway("output_compression", raw["outputCompression"])
    |> maybe_put_gateway("moderation", raw["moderation"])
    |> maybe_put_gateway("input_fidelity", raw["inputFidelity"])
  end

  defp maybe_put_gateway(map, _key, nil), do: map
  defp maybe_put_gateway(map, _key, []), do: map
  defp maybe_put_gateway(map, key, value), do: Map.put(map, key, value)

  defp commit_generated_image(
         actor,
         {:applet_asset, applet_page_id, custom_name, required_action},
         bytes,
         mime_type
       ) do
    filename = image_filename(custom_name, mime_type)

    with {:ok, stored} <- Ankole.Files.store(bytes) do
      Access.write(
        actor.turn_authority,
        fn ->
          with {:ok, locked_page} <- Pages.lock(applet_page_id),
               {:ok, _} <- Pages.authorize(actor, locked_page.id, required_action, trash: false),
               {:ok, object} <- Ankole.Files.complete_object_in_tx(stored),
               sha256_hex = Base.encode16(object.sha256, case: :lower),
               rel_path = "assets/#{sha256_hex}/#{filename}",
               {:ok, %{files: [file]}} <-
                 Files.commit_files_in_tx(
                   locked_page.id,
                   [
                     %{
                       path: rel_path,
                       object_id: object.id,
                       source: "generated",
                       content_type: mime_type
                     }
                   ],
                   []
                 ) do
            {:ok, %{page_id: locked_page.id, name: filename, file: Files.entry(file)}}
          end
        end,
        after_commit: &Files.committed/1
      )
    end
  end

  defp commit_generated_image(actor, {:upload, target_id, role, custom_name}, bytes, mime_type) do
    filename = image_filename(custom_name, mime_type)

    with {:ok, uploaded} <-
           Files.upload(
             actor,
             target_id,
             role,
             nil,
             filename,
             bytes,
             mime_type,
             actor.turn_authority
           ) do
      {:ok, Map.put(uploaded, :name, filename)}
    end
  end

  defp image_filename(nil, mime_type), do: "generated." <> image_extension(mime_type)

  defp image_filename(name, mime_type) when is_binary(name) do
    clean = Ankole.Files.file_name(name)

    if Path.extname(clean) == "" do
      clean <> "." <> image_extension(mime_type)
    else
      clean
    end
  end

  defp image_extension("image/png"), do: "png"
  defp image_extension("image/jpeg"), do: "jpg"
  defp image_extension("image/webp"), do: "webp"
  defp image_extension("image/gif"), do: "gif"
  defp image_extension(_mime), do: "png"

  defp file_content_url(page_id, relative_path, auth_ref) do
    base =
      "/api/v2/pod/pages/#{page_id}/files/content?path=" <> URI.encode_www_form(relative_path)

    if is_binary(auth_ref) and auth_ref != "" do
      base <> "&authentication_ref=" <> URI.encode_www_form(auth_ref)
    else
      base
    end
  end

  defp map_openai_image_error(%OpenAIError{code: "request_too_large", message: message}) do
    %{status: 413, code: "file_too_large", message: message, details: nil}
  end

  defp map_openai_image_error(%OpenAIError{type: "image_generation_user_error"} = error) do
    %{status: 422, code: error.code, message: error.message, details: nil}
  end

  defp map_openai_image_error(%OpenAIError{status: status, code: code, message: message})
       when status in [400, 422] do
    if code == "unsupported_value" do
      %{status: 422, code: "unsupported_value", message: message, details: nil}
    else
      %{status: 400, code: "invalid_request", message: message, details: nil}
    end
  end

  defp map_openai_image_error(%OpenAIError{message: message}) do
    %{status: 502, code: "ai_unavailable", message: message, details: nil}
  end
end
