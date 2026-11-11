defmodule Ankole.AIGateway.MediaJobs do
  @moduledoc """
  Video and music generation.

  A Provider finishes a generation after the gateway request has returned, so
  a request creates a media job and answers with its id. A background job
  sends the request to the Provider, asks a Provider that works on its own
  for the state of the generation, and saves the generated file in the
  tenant's object storage. The caller reads the job until it is `completed`
  or `failed`, and then reads the file.

  The Pod or Site `video` and `music` profiles select the model. Neither has a
  language-model fallback.
  """

  require Ash.Query

  alias Ankole.AIGateway.FailureResponse
  alias Ankole.AIGateway.Jobs.RunMediaJob
  alias Ankole.AIGateway.OpenAIError
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.RequestExecution
  alias Ankole.AIGateway.RequestParams
  alias Ankole.AIGateway.Resolver
  alias Ankole.AIGateway.Schemas.MediaJob
  alias Ankole.AIGateway.UsageLedger
  alias Ankole.Files
  alias Ankole.Principals
  alias Ankole.Repo

  @capabilities ~w(video music)
  @request_fields %{
    "video" =>
      ~w(prompt duration resolution aspect_ratio size generate_audio seed first_frame last_frame),
    "music" => ~w(prompt lyrics instrumental duration)
  }
  @default_content_types %{video: "video/mp4", music: "audio/mpeg"}
  # A frame travels inside the job row until the Provider has the request.
  @max_frame_chars 14 * 1024 * 1024
  @poll_seconds 10
  @generation_timeout_seconds 60 * 60
  @download_timeout_ms 10 * 60 * 1_000
  @retention_seconds 7 * 24 * 60 * 60

  @doc """
  Creates a media job for a `video` or `music` request and returns it with
  status 202.
  """
  @spec create(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(subject_uid, capability, request, opts)
      when capability in @capabilities and is_map(request) do
    with {:ok, request} <- RequestParams.prepare(request, @request_fields[capability]),
         :ok <- validate(capability, request),
         {:ok, runtime} <- Resolver.resolve_request_model(subject_uid, capability, request),
         # Preparing the request here reports a field that the Provider does
         # not accept to the caller instead of to the job.
         {:ok, _prepared} <- build(runtime, request),
         {:ok, job} <- insert(runtime, request, opts) do
      {:ok, RequestExecution.gateway_response(202, body(job), runtime)}
    end
  end

  def create(_subject_uid, _capability, _request, _opts), do: {:error, :invalid_request_body}

  @doc "Returns the caller's media job."
  @spec fetch(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(subject_uid, capability, id) do
    with {:ok, job} <- get_for_subject(subject_uid, capability, id), do: {:ok, body(job)}
  end

  @doc """
  Returns the generated file of the caller's completed media job: the stored
  object and its media type.
  """
  @spec content(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def content(subject_uid, capability, id) do
    with {:ok, job} <- get_for_subject(subject_uid, capability, id) do
      case job do
        %{status: :completed, object_id: object_id} ->
          with {:ok, object} <- Files.fetch_object(object_id) do
            {:ok, %{object: object, content_type: job.content_type, id: job.id}}
          end

        _unfinished ->
          {:error,
           %OpenAIError{
             status: 409,
             type: "invalid_request_error",
             code: "media_not_ready",
             message: "The media job is #{job.status} and has no file."
           }}
      end
    end
  end

  @doc """
  Advances a media job by one step: sends the request, asks for the state of
  the generation, or saves the generated file. Returns `{:snooze, seconds}`
  while the Provider works. On `last_attempt?`, an error that would otherwise
  be tried again fails the job.
  """
  @spec run(String.t(), boolean()) :: :ok | {:snooze, pos_integer()} | {:error, term()}
  def run(id, last_attempt?) do
    case Ankole.Ash.read_one(Ash.Query.filter(MediaJob, id == ^id)) do
      {:ok, %MediaJob{status: status} = job} when status in [:pending, :in_progress] ->
        case advance(job) do
          {:fail, reason} -> fail(job, reason)
          {:error, reason} when last_attempt? -> fail(job, reason)
          result -> result
        end

      _finished_or_deleted ->
        :ok
    end
  end

  @doc "Deletes the media jobs whose retention has ended, which releases their files."
  @spec cleanup_expired(DateTime.t()) :: non_neg_integer()
  def cleanup_expired(now \\ DateTime.utc_now(:microsecond)) do
    case Ankole.Ash.destroy_where(MediaJob, :collect, %{now: now}, select: [:id]) do
      {:ok, records} -> length(records)
      {:error, error} -> raise error
    end
  end

  @doc false
  @spec fail_unexpected(String.t(), Exception.t()) :: :ok
  def fail_unexpected(id, exception) when is_binary(id) do
    case Ankole.Ash.read_one(Ash.Query.filter(MediaJob, id == ^id)) do
      {:ok, %MediaJob{status: status} = job} when status in [:pending, :in_progress] ->
        _ =
          fail(
            job,
            OpenAIError.server(
              500,
              "media_job_failed",
              Exception.message(exception)
            )
          )

        :ok

      _other ->
        :ok
    end
  end

  defp insert(runtime, request, opts) do
    now = DateTime.utc_now(:microsecond)

    request_context =
      (Keyword.get(opts, :request_context) || %{})
      |> maybe_put_caller(Keyword.get(opts, :caller))

    Repo.transact_top_level(fn ->
      with {:ok, job} <-
             Ankole.Ash.create(MediaJob, :submit, %{
               subject_uid: runtime["subject_uid"],
               subject_type: Keyword.get(opts, :subject_type),
               capability: String.to_existing_atom(runtime["capability"]),
               provider_id: runtime["provider_id"],
               model: runtime["model"],
               request: request,
               request_context: request_context,
               expires_at: DateTime.add(now, @retention_seconds, :second)
             }),
           {:ok, _oban_job} <- Oban.insert(RunMediaJob.new(%{media_job_id: job.id})) do
        {:ok, job}
      end
    end)
  end

  defp maybe_put_caller(request_context, caller) when is_binary(caller) and caller != "",
    do: Map.put(request_context, "caller", caller)

  defp maybe_put_caller(request_context, _caller), do: request_context

  defp advance(job) do
    with {:ok, runtime} <- runtime(job), do: step(job, runtime)
  end

  # The job reads the profile again on every step. The credential affinity
  # keeps the steps of one job on one credential of a Provider pool, because
  # only the account that started a generation can read it.
  defp runtime(job) do
    request =
      Map.put(
        job.request,
        "__ankole_request_context",
        Map.put(job.request_context, "affinity_key", job.id)
      )

    case Resolver.resolve_request_model(job.subject_uid, to_string(job.capability), request) do
      {:ok, %{"provider_id" => provider_id, "model" => model} = runtime}
      when provider_id == job.provider_id and model == job.model ->
        {:ok, runtime}

      {:ok, _other_model} ->
        {:fail,
         OpenAIError.server(
           409,
           "model_profile_changed",
           "The model profile changed while the media job ran.",
           "invalid_request_error"
         )}

      {:error, _reason} = error ->
        error
    end
  end

  # The row leaves `pending` atomically before the Provider receives the
  # request, so a concurrent or retried worker never asks for a second
  # generation, which the Provider would bill.
  defp step(%MediaJob{status: :pending} = job, runtime) do
    case Ankole.Ash.update_where(
           Ash.Query.filter(MediaJob, id == ^job.id and status == :pending),
           :claim_pending
         ) do
      {:ok, [%MediaJob{} = claimed]} ->
        case upstream(runtime, claimed.request) do
          {:ok, result} -> record(claimed, runtime, result)
          {:error, reason} -> {:fail, reason}
        end

      {:ok, []} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp step(%MediaJob{result_url: url} = job, runtime) when is_binary(url), do: save(job, runtime)

  defp step(%MediaJob{upstream_job_id: upstream_job_id} = job, runtime)
       when is_binary(upstream_job_id) do
    if DateTime.diff(DateTime.utc_now(), job.inserted_at) > @generation_timeout_seconds do
      {:fail,
       OpenAIError.server(
         504,
         "media_generation_timeout",
         "The Provider did not finish the generation within an hour."
       )}
    else
      with {:ok, result} <- upstream(runtime, state_request(job)),
           do: record(job, runtime, result)
    end
  end

  defp step(_interrupted, _runtime) do
    {:fail,
     OpenAIError.server(
       500,
       "media_job_interrupted",
       "The media job stopped while it sent the request, so the state of the generation is unknown."
     )}
  end

  defp record(job, runtime, %{"status" => "completed", "url" => url} = result)
       when is_binary(url) do
    with {:ok, job} <- update(job, %{result_url: url, usage: result["usage"] || %{}}),
         do: save(job, runtime)
  end

  defp record(_job, _runtime, %{"status" => "failed"} = result) do
    message =
      case result["error"] do
        text when is_binary(text) -> text
        %{"message" => text} when is_binary(text) -> text
        _unnamed -> "The Provider reported that the generation failed."
      end

    {:fail, OpenAIError.server(502, "media_generation_failed", message)}
  end

  defp record(job, _runtime, %{"job_id" => upstream_job_id}) when is_binary(upstream_job_id) do
    with {:ok, _job} <- update(job, %{upstream_job_id: upstream_job_id}),
         do: {:snooze, @poll_seconds}
  end

  defp record(_job, _runtime, _result) do
    {:fail,
     OpenAIError.server(
       502,
       "invalid_media_output",
       "The Provider returned neither a file nor a generation to wait for."
     )}
  end

  # The Provider has finished and billed the generation, so a failed download
  # is tried again from the kept link and never sends the request again.
  defp save(job, runtime) do
    with {:ok, %{size: size} = stored} when size > 0 <- download(job, runtime),
         {:ok, job} <- complete(job, stored) do
      :ok =
        UsageLedger.record_capability(
          runtime,
          job.subject_type,
          %{"usage" => job.usage || %{}},
          quantity: job.request["duration"],
          caller: job.request_context["caller"],
          request_context: Map.delete(job.request_context || %{}, "caller")
        )

      :ok
    else
      {:ok, _empty} -> {:error, {:media_download_failed, :empty_file}}
      {:error, _reason} = error -> error
    end
  end

  defp download(job, runtime) do
    with {:ok, prepared} <- build(runtime, state_request(job)) do
      "GET"
      |> Files.HTTP.stream(job.result_url, download_headers(job.result_url, prepared), nil,
        timeout: @download_timeout_ms
      )
      |> Files.store()
    end
  rescue
    error in Files.HTTP.Error -> {:error, {:media_download_failed, error.reason}}
  end

  # A link on the Provider's own origin is read with the headers of a Provider
  # request, which hold the credential. Any link on another scheme, host, or
  # port carries its own signature and receives no credential.
  @doc false
  def download_headers(url, %{upstream: %{url: provider_url, headers: headers}})
      when is_binary(url) and is_binary(provider_url) do
    target = URI.parse(url)
    provider = URI.parse(provider_url)

    if target.scheme in ["http", "https"] and target.scheme == provider.scheme and
         is_binary(target.host) and target.host != "" and
         is_binary(provider.host) and provider.host != "" and
         {String.downcase(target.host), target.port || URI.default_port(target.scheme)} ==
           {String.downcase(provider.host), provider.port || URI.default_port(provider.scheme)} do
      headers
    else
      []
    end
  end

  def download_headers(_url, _prepared), do: []

  defp complete(job, stored) do
    Repo.transact_top_level(fn ->
      with {:ok, _object} <- Files.complete_object_in_tx(stored) do
        update(job, %{
          status: :completed,
          object_id: stored.object_id,
          content_type: content_type(job),
          byte_size: stored.size,
          result_url: nil,
          # The frames have served their purpose and are large.
          request: Map.drop(job.request, ~w(first_frame last_frame))
        })
      end
    end)
  end

  # The link's file extension names the media type; a link without a media
  # extension holds the format that Providers of the capability generate.
  defp content_type(job) do
    type = MIME.from_path(URI.parse(job.result_url).path || "")
    prefix = if job.capability == :video, do: "video/", else: "audio/"

    if String.starts_with?(type, prefix),
      do: type,
      else: Map.fetch!(@default_content_types, job.capability)
  end

  defp fail(job, reason) do
    %{error: error} = FailureResponse.project(reason)

    with {:ok, _job} <-
           update(job, %{
             status: :failed,
             result_url: nil,
             error: Map.take(error, ~w(code message)),
             request: Map.drop(job.request, ~w(first_frame last_frame))
           }),
         do: :ok
  end

  defp update(job, attrs), do: Ankole.Ash.update(job, :advance, attrs)

  defp upstream(runtime, request) do
    with {:ok, prepared} <- build(runtime, request),
         {:ok, response} <- RequestExecution.execute_prepared_request(runtime, prepared, []) do
      {:ok, response.body}
    end
  end

  # A request with `job_id` asks the Provider for the state of that generation.
  defp state_request(%MediaJob{upstream_job_id: nil} = job), do: job.request

  defp state_request(%MediaJob{} = job),
    do: Map.put(job.request, "job_id", job.upstream_job_id)

  defp build(%{"capability" => "video"} = runtime, request),
    do: Providers.build_video_request(runtime, request)

  defp build(%{"capability" => "music"} = runtime, request),
    do: Providers.build_music_request(runtime, request)

  defp get_for_subject(subject_uid, capability, id) when capability in @capabilities do
    with {:ok, subject_uid} <- Principals.normalize_uid(subject_uid),
         {:ok, id} <- Ecto.UUID.cast(id),
         capability = String.to_existing_atom(capability),
         {:ok, %MediaJob{} = job} <-
           MediaJob
           |> Ash.Query.filter(
             id == ^id and subject_uid == ^subject_uid and capability == ^capability
           )
           |> Ankole.Ash.read_one() do
      {:ok, job}
    else
      _missing_or_invalid -> {:error, OpenAIError.not_found("id", "Media job not found.")}
    end
  end

  defp body(%MediaJob{} = job) do
    %{
      "id" => job.id,
      "status" => to_string(job.status),
      "model" => "#{job.provider_id}/#{job.model}",
      "created_at" => DateTime.to_unix(job.inserted_at),
      "expires_at" => DateTime.to_unix(job.expires_at)
    }
    |> Map.merge(result_fields(job))
  end

  defp result_fields(%MediaJob{status: :completed} = job),
    do: %{"content_type" => job.content_type, "size" => job.byte_size}

  defp result_fields(%MediaJob{status: :failed} = job), do: %{"error" => job.error}
  defp result_fields(_running), do: %{}

  defp validate("video", request) do
    cond do
      not text?(request["prompt"]) ->
        invalid("prompt", "missing_required_parameter", "prompt must be a non-empty string.")

      field = Enum.find(~w(resolution aspect_ratio size), &(not optional_text?(request[&1]))) ->
        invalid(field, "invalid_value", "#{field} must be a non-empty string.")

      request["generate_audio"] not in [nil, true, false] ->
        invalid("generate_audio", "invalid_value", "generate_audio must be a boolean.")

      not (is_nil(request["seed"]) or is_integer(request["seed"])) ->
        invalid("seed", "invalid_value", "seed must be an integer.")

      field = Enum.find(~w(first_frame last_frame), &(not optional_frame?(request[&1]))) ->
        invalid(
          field,
          "invalid_value",
          "#{field} must be an https URL or a base64 data URL of an image of up to 10 MiB."
        )

      true ->
        validate_duration(request)
    end
  end

  defp validate("music", request) do
    cond do
      not text?(request["prompt"]) ->
        invalid("prompt", "missing_required_parameter", "prompt must be a non-empty string.")

      not optional_text?(request["lyrics"]) ->
        invalid("lyrics", "invalid_value", "lyrics must be a non-empty string.")

      request["instrumental"] not in [nil, true, false] ->
        invalid("instrumental", "invalid_value", "instrumental must be a boolean.")

      true ->
        validate_duration(request)
    end
  end

  defp validate_duration(%{"duration" => duration})
       when not (is_integer(duration) and duration > 0),
       do: invalid("duration", "invalid_value", "duration must be a positive number of seconds.")

  defp validate_duration(_request), do: :ok

  defp optional_frame?(nil), do: true

  defp optional_frame?(frame) when is_binary(frame),
    do:
      String.starts_with?(frame, ["https://", "data:image/"]) and
        byte_size(frame) <= @max_frame_chars

  defp optional_frame?(_frame), do: false

  defp text?(value), do: is_binary(value) and String.trim(value) != ""
  defp optional_text?(value), do: is_nil(value) or text?(value)

  defp invalid(param, code, message), do: {:error, OpenAIError.invalid(param, code, message)}
end
