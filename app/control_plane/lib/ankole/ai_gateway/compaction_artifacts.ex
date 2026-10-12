defmodule Ankole.AIGateway.CompactionArtifacts do
  alias Ankole.AIGateway.ResponseChain

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

  alias Ankole.AIGateway.{CompactionSummarizer}
  alias Ankole.AIGateway.HostedTools.Brain

  import Ankole.AIGateway.CompactionHistory,
    only: [
      raw_history: 3,
      messages_to_items: 1,
      provider_neutral_tail_items: 1,
      input_items: 1,
      items_token_estimate: 1
    ]

  import Ankole.AIGateway.CompactionPolicy,
    only: [checkpoint_budget_tokens: 1, user_message_budget_tokens: 0]

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
          optional(:opaque_prefix) => [map()],
          optional(:brain_context_pack) => [map()],
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

  @doc "Returns the items that replace a checkpoint in model history."
  @spec replay_items(map()) :: [map()]
  def replay_items(%{"output" => output} = content) when is_list(output),
    do: Map.get(content, "brain_context_pack", []) ++ output

  @spec version(CompactionArtifact.t()) :: 2 | 3 | nil
  def version(%CompactionArtifact{content: %{"version" => version}}) when version in [2, 3],
    do: version

  def version(_artifact), do: nil

  @spec summary_text(CompactionArtifact.t()) :: String.t() | nil
  def summary_text(%CompactionArtifact{content: %{"summary" => %{"text" => text}}})
      when is_binary(text),
      do: text

  def summary_text(_artifact), do: nil

  @spec opaque_prefix(CompactionArtifact.t()) :: [map()]
  def opaque_prefix(%CompactionArtifact{content: %{"opaque_prefix" => opaque_prefix}})
      when is_list(opaque_prefix),
      do: opaque_prefix

  def opaque_prefix(_artifact), do: []

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

  A preserved opaque prefix replays ahead of the artifact output.
  """
  @spec output_for_checkpoint(String.t(), Message.t()) ::
          {:ok, [term()]} | {:error, :invalid_compaction_handle}
  def output_for_checkpoint(subject_uid, %Message{type: "checkpoint", content: [ref]}) do
    case ref do
      %{"type" => "compaction_artifact", "id" => public_id} ->
        with {:ok, artifact} <- get_for_subject(subject_uid, public_id) do
          {:ok, opaque_prefix(artifact) ++ output(artifact)}
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
  Replaces Ankole compaction handles in Response input items.

  A handle resolves to its stored opaque prefix, when the artifact preserved
  Provider-owned compaction state, followed by one checkpoint user message.
  The checkpoint prompt is AIGateway policy. Provider-native compaction items
  remain unchanged for a Responses resolver.
  """
  @spec resolve_input_handles(String.t(), [map()]) ::
          {:ok, [map()]} | {:error, :invalid_compaction_handle}
  def resolve_input_handles(subject_uid, items) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case resolve_input_item_handle(subject_uid, item) do
        {:ok, resolved} when is_list(resolved) -> {:cont, {:ok, Enum.reverse(resolved, acc)}}
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
          {:ok, opaque_prefix(artifact) ++ [checkpoint_message(summary)]}
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
         }
         |> put_brain_context_pack(attrs)}
    end
  end

  defp artifact_content(id, attrs) do
    summary_text = Map.fetch!(attrs, :summary_text)
    retained_items = Map.get(attrs, :retained_items, [])
    retained_user_originals = Map.get(attrs, :retained_user_originals, [])
    opaque_prefix = Map.get(attrs, :opaque_prefix, [])

    cond do
      not is_binary(summary_text) or String.trim(summary_text) == "" ->
        {:error, :empty_compaction_summary}

      not is_list(retained_items) ->
        {:error, :invalid_compaction_artifact}

      not is_list(retained_user_originals) ->
        {:error, :invalid_compaction_artifact}

      not is_list(opaque_prefix) ->
        {:error, :invalid_compaction_artifact}

      true ->
        content = %{
          "version" => 2,
          "summary" => %{"text" => String.trim(summary_text)},
          "output" => retained_user_originals ++ [compaction_item(id)] ++ retained_items,
          "retention" => artifact_retention(attrs, retained_items, retained_user_originals),
          "usage" => response_usage(Map.get(attrs, :usage, %{}))
        }

        # Provider-owned compaction items the local summary could not read.
        # They stay outside `output`, so the reply keeps exactly one compaction
        # item; both replay surfaces emit them ahead of the local checkpoint.
        content =
          if opaque_prefix == [],
            do: content,
            else: Map.put(content, "opaque_prefix", opaque_prefix)

        {:ok, put_brain_context_pack(content, attrs)}
    end
  end

  defp put_brain_context_pack(content, attrs) do
    case Map.get(attrs, :brain_context_pack, []) do
      [] -> content
      pack -> Map.put(content, "brain_context_pack", pack)
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
        |> put_truthy(
          "previous_summary_discarded",
          Map.get(retention, "previous_summary_discarded")
        )
        |> put_truthy("opaque_prefix_items", Map.get(retention, "opaque_prefix_items"))

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

  defp put_truthy(map, _key, nil), do: map
  defp put_truthy(map, _key, false), do: map
  defp put_truthy(map, key, value), do: Map.put(map, key, value)

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

  def checkpoint_pack(subject_uid, conversation_id, request, input, history) do
    case ResponseChain.get_conversation_for_subject(subject_uid, conversation_id) do
      {:ok, conversation} ->
        Brain.checkpoint_context_pack(subject_uid, conversation, request, input, fn ->
          conversation_id |> source_chain(history, request) |> messages_to_items()
        end)

      {:error, _reason} ->
        []
    end
  end

  # A checkpoint row is derived context. Its source chain keeps the user text
  # through consecutive compactions.
  defp source_chain(conversation_id, history, request) do
    if Enum.any?(history, &(&1.type == "checkpoint")),
      do: raw_history(conversation_id, history, request),
      else: history
  end

  def upstream_artifact_attrs(subject_uid, conversation_id, upstream) do
    %{
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      source: :upstream,
      binding: upstream.binding,
      output: upstream.output,
      usage: upstream.usage
    }
  end

  def create_artifact_for_candidate(subject_uid, conversation_id, candidate, summary) do
    insert_artifact(
      artifact_attrs_for_candidate(subject_uid, conversation_id, candidate, summary)
    )
  end

  def artifact_attrs_for_candidate(subject_uid, conversation_id, candidate, summary) do
    %{
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      summary_text: summary.text,
      brain_context_pack: candidate.brain_context_pack,
      retained_items:
        candidate.retained_client_tool_search ++
          provider_neutral_tail_items(candidate.retained_tail),
      # The replayed originals may end with a still-unanswered clarify
      # call/output pair; "user_message_count" counts only user messages.
      retained_user_originals:
        candidate.retained_user_originals ++ candidate.retained_pending_clarify,
      retention: %{
        "strategy" => "tail_rows",
        "requested" => candidate.tail_rows_requested,
        "actual" => length(candidate.retained_tail),
        "user_budget_tokens" => user_message_budget_tokens(),
        "user_message_count" => length(candidate.retained_user_originals)
      },
      usage: summary.usage
    }
  end

  def compaction_metadata(summary, candidate, total_tokens, flags) do
    %{
      "summarizer" => %{
        "model" => summary.model,
        "selector" => CompactionSummarizer.profile(),
        "usage" => summary.usage,
        "truncated" => summary.truncated
      },
      "history_usage_tokens_before" => total_tokens,
      "covered_message_count" => length(candidate.prefix)
    }
    |> Map.merge(flags)
  end

  def request_metadata(%{"metadata" => metadata}) when is_map(metadata), do: metadata
  def request_metadata(_request), do: %{}

  # A checkpoint replays Provider items it kept verbatim, so it records its
  # issuer like any other stored message. The replay recovery is the one
  # checkpoint without an issuer, because it keeps no Provider state at all.
  def checkpoint_metadata(request, internal_metadata, issuer) do
    internal_metadata
    |> Map.put("request_metadata", request_metadata(request))
    |> put_issuer(issuer)
  end

  def put_issuer(metadata, issuer) when is_binary(issuer),
    do: Map.put(metadata, "issuer", issuer)

  def put_issuer(metadata, _issuer), do: metadata

  def issuer_of(%{runtime: runtime}) when is_map(runtime), do: Map.get(runtime, "provider_id")
  def issuer_of(_context), do: nil

  def checkpoint_within_budget(candidate, summary, current_input, threshold) do
    checkpoint_items =
      candidate.brain_context_pack ++
        candidate.opaque_prefix ++
        candidate.retained_user_originals ++
        candidate.retained_pending_clarify ++
        [compaction_summary_item(summary.text)] ++
        candidate.retained_client_tool_search ++
        provider_neutral_tail_items(candidate.retained_tail) ++ input_items(current_input)

    checkpoint_items_within_budget(checkpoint_items, threshold)
  end

  def checkpoint_items_within_budget(checkpoint_items, threshold) do
    if items_token_estimate(checkpoint_items) <= checkpoint_budget_tokens(threshold) do
      :ok
    else
      {:error, :compaction_output_over_budget}
    end
  end

  def compaction_summary_item(summary_text) do
    %{
      "type" => "compaction",
      "encrypted_content" => summary_text,
      "created_by" => "ankole-aigateway"
    }
  end

  def with_upstream_pack(
        %{source: :upstream, output: output} = attrs,
        pack,
        current_input,
        threshold
      ) do
    checkpoint_items = pack ++ output ++ input_items(current_input)

    with :ok <- checkpoint_items_within_budget(checkpoint_items, threshold) do
      {:ok, Map.put(attrs, :brain_context_pack, pack)}
    end
  end
end
