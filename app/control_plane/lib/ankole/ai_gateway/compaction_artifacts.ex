defmodule Ankole.AIGateway.CompactionArtifacts do
  @moduledoc """
  Canonical storage and replay seam for AIGateway compaction artifacts.

  The `compaction_trigger` protocol, `/compress`, and automatic compaction all
  create an artifact first. A checkpoint message row is only a response-chain
  continuation pointer to one artifact.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIGateway.Schemas.CompactionArtifact
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Principals
  alias Ankole.Repo

  @handle_prefix "ankole:compact:v1:"

  @type artifact_attrs :: %{
          required(:subject_uid) => String.t(),
          optional(:id) => Ecto.UUID.t(),
          optional(:conversation_id) => Ecto.UUID.t() | nil,
          optional(:source) => :upstream,
          optional(:summary_text) => String.t(),
          optional(:binding) => map(),
          optional(:output) => [term()],
          optional(:retained_items) => [map()],
          optional(:retained_user_originals) => [map()],
          optional(:retention) => map(),
          optional(:usage) => map()
        }

  @spec new_id() :: Ecto.UUID.t()
  def new_id, do: UUIDv7.autogenerate()

  @spec public_id(Ecto.UUID.t()) :: String.t()
  def public_id(uuid) when is_binary(uuid), do: "cmp_#{uuid}"

  @spec response_id(Ecto.UUID.t()) :: String.t()
  def response_id(uuid) when is_binary(uuid), do: "resp_#{uuid}"

  @spec handle(Ecto.UUID.t()) :: String.t()
  def handle(uuid) when is_binary(uuid), do: @handle_prefix <> public_id(uuid)

  @spec ref_item(Ecto.UUID.t()) :: map()
  def ref_item(uuid) when is_binary(uuid) do
    %{"id" => public_id(uuid), "type" => "compaction_artifact"}
  end

  @spec compaction_item(Ecto.UUID.t()) :: map()
  def compaction_item(uuid) when is_binary(uuid) do
    %{
      "id" => public_id(uuid),
      "type" => "compaction",
      "encrypted_content" => handle(uuid),
      "created_by" => "ankole-aigateway"
    }
  end

  @spec insert_artifact(artifact_attrs()) :: {:ok, CompactionArtifact.t()} | {:error, term()}
  def insert_artifact(attrs) when is_map(attrs) do
    insert_artifact_in_tx(Repo, attrs)
  end

  @spec insert_artifact_in_tx(module(), artifact_attrs()) ::
          {:ok, CompactionArtifact.t()} | {:error, term()}
  def insert_artifact_in_tx(repo, attrs) when is_map(attrs) do
    with {:ok, subject_uid} <- Principals.normalize_uid(Map.fetch!(attrs, :subject_uid)),
         {:ok, id} <- artifact_id(attrs),
         {:ok, content} <- artifact_content(id, attrs) do
      %CompactionArtifact{id: id}
      |> CompactionArtifact.changeset(%{
        subject_uid: subject_uid,
        conversation_id: Map.get(attrs, :conversation_id),
        content: content
      })
      |> repo.insert()
    else
      {:error, :invalid_uid} -> {:error, :invalid_subject}
      {:error, _reason} = error -> error
    end
  end

  @spec get_for_subject(String.t(), String.t()) ::
          {:ok, CompactionArtifact.t()} | {:error, :invalid_compaction_handle}
  def get_for_subject(subject_uid, public_or_handle) when is_binary(public_or_handle) do
    with {:ok, subject_uid} <- Principals.normalize_uid(subject_uid),
         {:ok, id} <- artifact_uuid(public_or_handle),
         %CompactionArtifact{} = artifact <-
           Repo.one(
             from(artifact in CompactionArtifact,
               where: artifact.id == ^id and artifact.subject_uid == ^subject_uid
             )
           ) do
      {:ok, artifact}
    else
      _missing_or_invalid -> {:error, :invalid_compaction_handle}
    end
  end

  @spec output(CompactionArtifact.t()) :: [term()]
  def output(%CompactionArtifact{content: %{"output" => output}}) when is_list(output),
    do: output

  def output(_artifact), do: []

  @spec version(CompactionArtifact.t()) :: 2 | 3 | nil
  def version(%CompactionArtifact{content: %{"version" => version}}) when version in [2, 3],
    do: version

  def version(_artifact), do: nil

  @spec summary_text(CompactionArtifact.t()) :: String.t() | nil
  def summary_text(%CompactionArtifact{content: %{"summary" => %{"text" => text}}})
      when is_binary(text),
      do: text

  def summary_text(_artifact), do: nil

  @spec upstream_binding(CompactionArtifact.t()) :: map() | nil
  def upstream_binding(%CompactionArtifact{
        content: %{"version" => 3, "source" => "upstream", "binding" => binding}
      })
      when is_map(binding),
      do: binding

  def upstream_binding(_artifact), do: nil

  @spec response_body(CompactionArtifact.t(), keyword()) :: map()
  def response_body(%CompactionArtifact{} = artifact, opts \\ []) do
    body = %{
      "id" => "compact_#{artifact.id}",
      "object" => "response.compaction",
      "created_at" => unix_timestamp(artifact.inserted_at),
      "output" => output(artifact),
      "usage" => response_usage(get_in(artifact.content, ["usage"]))
    }

    case Keyword.get(opts, :ankole) do
      %{} = ankole -> Map.put(body, "ankole", ankole)
      _missing -> body
    end
  end

  @doc """
  Materializes a checkpoint row into the artifact output it references.
  """
  @spec output_for_checkpoint(String.t(), Message.t()) ::
          {:ok, [term()]} | {:error, :invalid_compaction_handle}
  def output_for_checkpoint(subject_uid, %Message{type: "checkpoint", content: [ref]}) do
    case ref do
      %{"type" => "compaction_artifact", "id" => public_id} ->
        with {:ok, artifact} <- get_for_subject(subject_uid, public_id) do
          {:ok, output(artifact)}
        end

      _invalid ->
        {:error, :invalid_compaction_handle}
    end
  end

  def output_for_checkpoint(_subject_uid, _message), do: {:ok, []}

  @doc "Returns the stored artifact content for one checkpoint row."
  @spec content_for_checkpoint(String.t(), Message.t()) ::
          {:ok, map()} | {:error, :invalid_compaction_handle}
  def content_for_checkpoint(subject_uid, %Message{type: "checkpoint", content: [ref]}) do
    case ref do
      %{"type" => "compaction_artifact", "id" => public_id} ->
        with {:ok, artifact} <- get_for_subject(subject_uid, public_id) do
          {:ok, artifact.content}
        end

      _invalid ->
        {:error, :invalid_compaction_handle}
    end
  end

  def content_for_checkpoint(_subject_uid, _message), do: {:error, :invalid_compaction_handle}

  @spec summary_for_checkpoint(String.t(), Message.t()) ::
          {:ok, String.t() | nil} | {:error, :invalid_compaction_handle}
  def summary_for_checkpoint(subject_uid, %Message{type: "checkpoint", content: [ref]}) do
    case ref do
      %{"type" => "compaction_artifact", "id" => public_id} ->
        with {:ok, artifact} <- get_for_subject(subject_uid, public_id) do
          {:ok, summary_text(artifact)}
        end

      _invalid ->
        {:error, :invalid_compaction_handle}
    end
  end

  def summary_for_checkpoint(_subject_uid, _message), do: {:ok, nil}

  @doc """
  Replaces Ankole compaction handles in Response input items with a user message.

  The checkpoint prompt is AIGateway policy. Provider-native compaction items
  remain unchanged for a Responses resolver.
  """
  @spec resolve_input_handles(String.t(), [map()]) ::
          {:ok, [map()]} | {:error, :invalid_compaction_handle}
  def resolve_input_handles(subject_uid, items) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case resolve_input_item_handle(subject_uid, item) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      {:error, _reason} = error -> error
    end
  end

  def resolve_input_handles(_subject_uid, items), do: {:ok, items}

  @spec resolve_request_input_handles(String.t(), map()) ::
          {:ok, map()} | {:error, :invalid_compaction_handle}
  def resolve_request_input_handles(subject_uid, %{"input" => input} = request)
      when is_list(input) do
    with {:ok, resolved} <- resolve_input_handles(subject_uid, input) do
      {:ok, Map.put(request, "input", resolved)}
    end
  end

  def resolve_request_input_handles(_subject_uid, request) when is_map(request),
    do: {:ok, request}

  defp resolve_input_item_handle(subject_uid, %{"type" => "compaction"} = item) do
    case Map.get(item, "encrypted_content") do
      @handle_prefix <> _rest = handle ->
        with {:ok, artifact} <- get_for_subject(subject_uid, handle),
             summary when is_binary(summary) <- summary_text(artifact) do
          {:ok, checkpoint_message(summary)}
        else
          _missing_or_invalid -> {:error, :invalid_compaction_handle}
        end

      _non_ankole_content ->
        {:ok, item}
    end
  end

  defp resolve_input_item_handle(_subject_uid, item), do: {:ok, item}

  defp checkpoint_message(summary) do
    %{
      "type" => "message",
      "role" => "user",
      "content" => [
        %{
          "type" => "input_text",
          "text" =>
            "Context checkpoint: an earlier context window of this same agent already worked on this task and was compacted into the summary below. Tool side effects (files created or edited, commands run, processes started) remain in effect. Messages after this summary are verbatim and take precedence over it; continue the summary's in-progress work unless later messages supersede it.\n\n#{summary}"
        }
      ]
    }
  end

  defp artifact_id(%{id: id}) when is_binary(id), do: UUIDv7.cast(id)
  defp artifact_id(_attrs), do: {:ok, new_id()}

  defp artifact_content(_id, %{source: :upstream} = attrs) do
    output = Map.get(attrs, :output)
    binding = Map.get(attrs, :binding)

    cond do
      not is_list(output) or output == [] ->
        {:error, :invalid_compaction_artifact}

      not CompactionArtifact.valid_upstream_binding?(binding) ->
        {:error, :invalid_compaction_artifact}

      true ->
        {:ok,
         %{
           "version" => 3,
           "source" => "upstream",
           "binding" => binding,
           "output" => output,
           "usage" => response_usage(Map.get(attrs, :usage, %{}))
         }}
    end
  end

  defp artifact_content(id, attrs) do
    summary_text = Map.fetch!(attrs, :summary_text)
    retained_items = Map.get(attrs, :retained_items, [])
    retained_user_originals = Map.get(attrs, :retained_user_originals, [])

    cond do
      not is_binary(summary_text) or String.trim(summary_text) == "" ->
        {:error, :empty_compaction_summary}

      not is_list(retained_items) ->
        {:error, :invalid_compaction_artifact}

      not is_list(retained_user_originals) ->
        {:error, :invalid_compaction_artifact}

      true ->
        {:ok,
         %{
           "version" => 2,
           "summary" => %{"text" => String.trim(summary_text)},
           "output" => retained_user_originals ++ [compaction_item(id)] ++ retained_items,
           "retention" => artifact_retention(attrs, retained_items, retained_user_originals),
           "usage" => response_usage(Map.get(attrs, :usage, %{}))
         }}
    end
  end

  defp artifact_retention(attrs, retained_items, retained_user_originals) do
    attrs
    |> Map.get(:retention, %{})
    |> case do
      %{} = retention ->
        %{
          "strategy" => Map.get(retention, "strategy", "tail_rows"),
          "requested" => Map.get(retention, "requested"),
          "actual" => Map.get(retention, "actual", length(retained_items)),
          "user_budget_tokens" => Map.get(retention, "user_budget_tokens"),
          "user_message_count" =>
            Map.get(retention, "user_message_count", length(retained_user_originals))
        }
        |> maybe_put(
          "previous_summary_discarded",
          Map.get(retention, "previous_summary_discarded")
        )

      _other ->
        %{
          "strategy" => "tail_rows",
          "requested" => nil,
          "actual" => length(retained_items),
          "user_budget_tokens" => nil,
          "user_message_count" => length(retained_user_originals)
        }
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp artifact_uuid(@handle_prefix <> public_id), do: artifact_uuid(public_id)
  defp artifact_uuid("cmp_" <> uuid), do: UUIDv7.cast(uuid)
  defp artifact_uuid(_value), do: :error

  defp response_usage(%{} = usage) do
    input_tokens = usage_integer(usage, ["input_tokens", "prompt_tokens", "inputTokens"])
    output_tokens = usage_integer(usage, ["output_tokens", "completion_tokens", "outputTokens"])
    total_tokens = usage_integer(usage, ["total_tokens", "totalTokens"])
    total_tokens = if total_tokens > 0, do: total_tokens, else: input_tokens + output_tokens

    %{
      "input_tokens" => input_tokens,
      "output_tokens" => output_tokens,
      "total_tokens" => total_tokens,
      "input_tokens_details" => %{
        "cached_tokens" => usage_integer(usage, ["cached_tokens", "cachedTokens"])
      },
      "output_tokens_details" => %{
        "reasoning_tokens" => usage_integer(usage, ["reasoning_tokens", "reasoningTokens"])
      }
    }
  end

  defp response_usage(_usage), do: response_usage(%{})

  defp usage_integer(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, 0, fn key ->
      case Map.get(map, key) do
        value when is_integer(value) and value >= 0 -> value
        _value -> false
      end
    end)
  end

  defp usage_integer(_map, _keys), do: 0

  defp unix_timestamp(%DateTime{} = datetime), do: DateTime.to_unix(datetime)
  defp unix_timestamp(_datetime), do: System.system_time(:second)
end
