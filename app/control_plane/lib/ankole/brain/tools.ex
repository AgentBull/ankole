defmodule Ankole.Brain.Tools do
  @moduledoc """
  Model-facing Brain operations: one catalog and one executor.

  The catalog is the contract a carrier declares to a model. AIGateway declares
  it as the hosted `brain` tool. Every operation executes for a `Context` that
  names the querier, the disclosure recipients, the default write scope, and the
  parent fallback, so each carrier applies the same knowledge and disclosure
  boundaries. A write commits inside the operation; a later failure of the
  surrounding model turn does not revert it.
  """

  alias Ankole.Brain.Access
  alias Ankole.Brain.Claims
  alias Ankole.Brain.Config
  alias Ankole.Brain.ContextPack
  alias Ankole.Brain.Experts
  alias Ankole.Brain.Forget
  alias Ankole.Brain.GetPage
  alias Ankole.Brain.LazySkillVisibility
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Recall
  alias Ankole.Brain.Scope
  alias Ankole.Brain.SourceLearning
  alias Ankole.Brain.Sources
  alias Ankole.Brain.Synthesis
  alias Ankole.JSON

  defmodule Context do
    @moduledoc """
    Who runs an operation and who receives its answer.

    `default_write_scope` and `parent_fallback` are resolved once per carrier
    request: a Turn derives them from its conversation, a request without a
    conversation uses the subject's own principal scope and canonical page.
    `write_fence` runs before every write; `nil` means the carrier has no turn
    to fence.
    """

    defstruct querier_uid: nil,
              disclosure: nil,
              default_write_scope: nil,
              channel_id: nil,
              participant_uids: [],
              parent_fallback: nil,
              holder_default: nil,
              write_fence: nil

    @type t :: %__MODULE__{
            querier_uid: String.t(),
            disclosure: Ankole.Brain.Access.disclosure(),
            default_write_scope: {:ok, String.t()} | {:error, term()},
            channel_id: String.t() | nil,
            participant_uids: [String.t()],
            parent_fallback: {:channel, String.t()} | {:page, String.t()} | {:error, term()},
            holder_default: String.t() | nil,
            write_fence: (-> :ok | {:error, term()}) | nil
          }
  end

  @operations ~w(remember learn_source recall get_page forget entity whoknows synthesize delta)
  @read_only_operations ~w(recall get_page entity whoknows delta)
  @take_kinds ~w(take bet hunch)
  @audience_scope_pattern ~r/\A(world|group:.+|principal:.+)\z/
  @url_pattern ~r/\Ahttps?:\/\//
  @lazy_skill_slug_prefix "lazyload-agent-skills/"
  @lazy_skill_hint "Use skill_view to load lazyload-agent-skills/ results.\n"
  @audience_scope_description "scope must be 'world', 'group:<name>', or 'principal:<uid>'"

  @doc "Returns every operation name in declaration order."
  @spec operations() :: [String.t()]
  def operations, do: @operations

  @doc "Returns whether an operation reads without writing."
  @spec read_only?(String.t()) :: boolean()
  def read_only?(operation), do: operation in @read_only_operations

  @doc "Returns whether a value names one operation."
  @spec operation?(term()) :: boolean()
  def operation?(operation), do: operation in @operations

  @doc "Returns the text a model must see before a result that names lazy Skill records."
  @spec lazy_skill_hint() :: String.t()
  def lazy_skill_hint, do: @lazy_skill_hint

  @doc """
  Returns the provider function declarations of the given operations, in the
  catalog order. The names are the model-facing tool names.
  """
  @spec function_specs([String.t()]) :: [map()]
  def function_specs(operations) when is_list(operations) do
    @operations
    |> Enum.filter(&(&1 in operations))
    |> Enum.map(fn name ->
      %{
        "type" => "function",
        "name" => name,
        "description" => description(name),
        "parameters" => parameters(name)
      }
    end)
  end

  @doc """
  Runs one operation for a context.

  The result is the JSON document the model receives. `{:error, reason}`
  reports a refused or failed operation; the carrier renders it as a failed
  tool result without failing the surrounding response.
  """
  @spec execute(String.t(), map(), Context.t()) :: {:ok, map()} | {:error, term()}
  def execute(operation, params, %Context{} = context) when is_map(params) do
    with :ok <- ensure_enabled(),
         :ok <- ensure_operation(operation) do
      run(operation, params, context)
    end
  end

  def execute(_operation, _params, %Context{}), do: {:error, :invalid_params}

  @doc """
  Returns whether a result names lazy Skill discovery records, so the carrier
  can prepend `lazy_skill_hint/0` for the model.
  """
  @spec lazy_skill_result?(term()) :: boolean()
  def lazy_skill_result?(value) when is_list(value), do: Enum.any?(value, &lazy_skill_result?/1)

  def lazy_skill_result?(%{} = value) do
    Enum.any?(value, fn
      {key, slug} when key in ["slug", "object_slug", :slug, :object_slug] and is_binary(slug) ->
        String.starts_with?(slug, @lazy_skill_slug_prefix)

      {_key, child} ->
        lazy_skill_result?(child)
    end)
  end

  def lazy_skill_result?(_value), do: false

  @doc "Assembles the zero-model context pack for a context and conversation facts."
  @spec context_pack(Context.t(), map()) :: map()
  def context_pack(%Context{} = context, params) when is_map(params) do
    ContextPack.context_pack(
      context.querier_uid,
      %{
        participant_uids: List.wrap(params[:participant_uids] || []),
        recent_text: params[:recent_text] || "",
        channel_id: context.channel_id
      },
      disclosure: context.disclosure
    )
  end

  @doc "Returns the zero-model volunteer pointers one message text names."
  @spec volunteer_pointers(Context.t(), String.t()) :: [map()]
  def volunteer_pointers(%Context{} = context, message_text) do
    ContextPack.volunteer_pointers(context.querier_uid, message_text,
      disclosure: context.disclosure
    )
  end

  # Operations

  defp run("remember", params, context) do
    with {:ok, claim_text} <- required(params, "claim"),
         {:ok, kind} <- claim_kind(params["kind"]),
         :ok <- validate_grid(params, "confidence"),
         :ok <- validate_grid(params, "weight"),
         {:ok, scope} <- write_scope(params["scope"], context),
         {:ok, provenance} <- required(params, "provenance"),
         :ok <- fence(context),
         {:ok, visibility} <- LazySkillVisibility.for_querier(context.querier_uid),
         {:ok, attrs} <-
           put_parent(
             %{
               claim: claim_text,
               kind: kind,
               holder: params["holder"] || context.holder_default,
               audience_scope: scope,
               context: params["context"],
               provenance: provenance
             },
             context,
             params["entity"],
             visibility
           ),
         {:ok, %{claim: claim} = outcome} <- write_claim(kind, attrs, params, context) do
      # The resolved parent goes back to the model: an entity that did not
      # resolve filed to the fallback, and silence about that would let the
      # model keep misspelling the entity forever.
      {:ok,
       %{
         "status" => to_string(outcome[:status] || :inserted),
         "claim_id" => claim.id,
         "superseded_claim_id" => outcome[:superseded_claim_id],
         "audience_scope" => claim.audience_scope,
         "object_slug" => claim.object_slug,
         "signal_gateway_channel_id" => claim.signal_gateway_channel_id
       }}
    end
  end

  defp run("learn_source", params, context) do
    with {:ok, url} <- required(params, "url"),
         :ok <- validate_learnable_url(url),
         {:ok, scope} <- write_scope(params["scope"], context),
         :ok <- fence(context),
         {:ok, source} <- find_or_register_url_source(url, scope),
         {:ok, _enqueued} <- SourceLearning.enqueue_learn(source.id) do
      {:ok,
       %{
         "status" => "learning",
         "source_id" => source.id,
         "audience_scope" => source.default_audience_scope
       }}
    end
  end

  defp run("recall", params, context) do
    with {:ok, query} <- required(params, "query") do
      Recall.recall(
        context.querier_uid,
        %{
          query: query,
          entity: optional_text(params["entity"]),
          budget_tokens: params["budget_tokens"]
        },
        disclosure: context.disclosure
      )
      |> entity_resolution_payload()
    end
  end

  defp run("get_page", params, context) do
    with {:ok, reference} <- required(params, "reference") do
      case GetPage.get_page(context.querier_uid, reference, disclosure: context.disclosure) do
        {:ok, page} -> {:ok, %{"page" => JSON.plain(page)}}
        {:ambiguous, candidates} -> {:ok, %{"candidates" => JSON.plain(candidates)}}
        {:error, :not_found} -> {:ok, %{"error" => "not_found"}}
        {:error, _reason} = error -> error
      end
    end
  end

  defp run("forget", params, context) do
    with {:ok, reason} <- required(params, "reason"),
         {:ok, target} <- forget_target(params),
         :ok <- fence(context),
         {:ok, _forgotten} <- forget(target, reason, context) do
      {:ok, %{"status" => "forgotten"}}
    end
  end

  defp run("entity", params, context) do
    with {:ok, name} <- required(params, "name"),
         {:ok, access} <- Access.for_readers(context.querier_uid, context.disclosure),
         {:ok, visibility} <- LazySkillVisibility.for_querier(context.querier_uid) do
      case Objects.resolve_reference(name, lazy_skill_visibility: visibility) do
        {:ok, object} ->
          card =
            ContextPack.entity_card(
              object.slug,
              access,
              context.disclosure,
              Config.forgetting(),
              DateTime.utc_now(),
              context.channel_id,
              visibility
            )

          {:ok, %{"entity" => JSON.plain(card)}}

        {:ambiguous, candidates} ->
          {:ok, %{"candidates" => JSON.plain(candidates)}}

        {:error, :not_found} ->
          {:ok, %{"error" => "not_found"}}
      end
    end
  end

  defp run("whoknows", params, context) do
    with {:ok, topic} <- required(params, "topic"),
         {:ok, experts} <-
           Experts.who_knows(context.querier_uid, topic,
             limit: params["limit"] || 5,
             disclosure: context.disclosure
           ) do
      {:ok, %{"experts" => JSON.plain(experts)}}
    end
  end

  defp run("synthesize", params, context) do
    with {:ok, question} <- required(params, "question"),
         :ok <- fence(context),
         {:ok, result} <-
           Synthesis.synthesize(context.querier_uid, question, disclosure: context.disclosure) do
      {:ok, JSON.plain(result)}
    end
  end

  defp run("delta", params, context) do
    with {:ok, since} <- optional_datetime(params, "since"),
         {:ok, until_at} <- optional_datetime(params, "until") do
      Synthesis.delta(
        context.querier_uid,
        %{entity: optional_text(params["entity"]), since: since, until: until_at},
        disclosure: context.disclosure
      )
      |> entity_resolution_payload()
    end
  end

  # remember

  defp write_claim(kind, attrs, params, context) do
    cond do
      kind in Claims.fact_kinds() and is_nil(params["until_date"]) ->
        attrs =
          Map.merge(attrs, %{
            notability: params["notability"] || "medium",
            confidence: params["confidence"] || 0.75,
            valid_from: DateTime.utc_now(:microsecond)
          })

        Claims.write_fact(attrs, context.querier_uid)

      kind in Claims.fact_kinds() ->
        {:error, :until_date_only_for_takes}

      true ->
        with :ok <- validate_until_date(params["until_date"]) do
          attrs =
            attrs
            |> Map.delete(:context)
            |> Map.merge(%{weight: params["weight"] || 0.6, until_date: params["until_date"]})

          case Claims.write_take(attrs, context.querier_uid) do
            {:ok, claim} -> {:ok, %{claim: claim, status: :inserted}}
            {:error, _reason} = error -> error
          end
        end
    end
  end

  defp claim_kind(nil), do: {:ok, "fact"}

  defp claim_kind(kind) when is_binary(kind) do
    if kind in Claims.fact_kinds() or kind in @take_kinds,
      do: {:ok, kind},
      else: {:error, {:invalid_kind, kind}}
  end

  defp claim_kind(kind), do: {:error, {:invalid_kind, kind}}

  # Confidence and weight live on a 0.05 grid. Rejecting an off-grid value here
  # gives the model an immediate, self-explaining error instead of a write
  # failure deep in the claim path.
  defp validate_grid(params, key) do
    case Map.get(params, key) do
      nil ->
        :ok

      value when is_number(value) and value >= 0 and value <= 1 ->
        if abs(value * 20 - Float.round(value * 20)) < 1.0e-6,
          do: :ok,
          else: {:error, {:off_grid, key}}

      _value ->
        {:error, {:off_grid, key}}
    end
  end

  # Parents on the named entity when it uniquely resolves, then the carrier's
  # fallback: the Turn's channel, or the subject's own canonical page for
  # channel-less requests. The fallback for an unresolved or ambiguous name is
  # the documented tool behavior, and the response reports the parent it
  # landed on.
  defp put_parent(attrs, context, entity, visibility) do
    resolved =
      case entity do
        entity when is_binary(entity) and entity != "" ->
          case Objects.resolve_reference(entity, lazy_skill_visibility: visibility) do
            {:ok, object} -> {:object, object.slug}
            _ambiguous_or_missing -> nil
          end

        _missing ->
          nil
      end

    case {resolved, context.parent_fallback} do
      {{:object, slug}, _fallback} ->
        {:ok, Map.put(attrs, :object_slug, slug)}

      {nil, {:channel, channel_id}} ->
        {:ok, Map.put(attrs, :signal_gateway_channel_id, channel_id)}

      {nil, {:page, slug}} ->
        {:ok, Map.put(attrs, :object_slug, slug)}

      {nil, {:error, reason}} ->
        {:error, reason}

      {nil, _missing} ->
        {:error, :missing_parent_fallback}
    end
  end

  defp write_scope(explicit, context) when is_binary(explicit) and explicit != "" do
    with true <- Regex.match?(@audience_scope_pattern, explicit) || {:error, :invalid_scope},
         :ok <- Scope.validate_writable(explicit, context.querier_uid) do
      {:ok, explicit}
    end
  end

  defp write_scope(_missing, context) do
    with {:ok, scope} <- context.default_write_scope,
         :ok <- Scope.validate_writable(scope, context.querier_uid) do
      {:ok, scope}
    end
  end

  defp fence(%Context{write_fence: nil}), do: :ok
  defp fence(%Context{write_fence: fence}) when is_function(fence, 0), do: fence.()

  # `until_date` gates the take into Dreaming's due-date grading, so a value
  # that grade_takes cannot parse must be rejected at write time.
  defp validate_until_date(nil), do: :ok

  defp validate_until_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, _date} -> :ok
      {:error, _reason} -> {:error, :invalid_until_date}
    end
  end

  defp validate_until_date(_value), do: {:error, :invalid_until_date}

  # learn_source

  defp validate_learnable_url(url) do
    if Regex.match?(@url_pattern, url), do: :ok, else: {:error, :invalid_url}
  end

  # First registration wins the default scope; a later call with another scope
  # reuses the Source unchanged, and the response reports the scope that
  # actually applies. Changing it afterwards is a Console decision.
  defp find_or_register_url_source(url, scope) do
    case Sources.get_or_create(%{
           kind: "url",
           upstream_id: url,
           name: url,
           default_audience_scope: scope
         }) do
      {:ok, source} -> {:ok, source}
      {:error, %Ecto.Changeset{}} -> {:error, :source_registration_failed}
      {:error, _reason} = error -> error
    end
  end

  # forget

  defp forget_target(params) do
    case {optional_text(params["claim_id"]), optional_text(params["slug"])} do
      {claim_id, nil} when is_binary(claim_id) -> {:ok, {:claim, claim_id}}
      {nil, slug} when is_binary(slug) -> {:ok, {:object, slug}}
      _both_or_neither -> {:error, :forget_target_required}
    end
  end

  defp forget({:claim, claim_id}, reason, context),
    do: Forget.forget_claim(claim_id, reason, context.querier_uid)

  defp forget({:object, slug}, reason, context),
    do: Forget.forget_object(slug, reason, context.querier_uid)

  # Shared plumbing

  defp ensure_enabled do
    if Config.enabled?(), do: :ok, else: {:error, :brain_disabled}
  end

  defp ensure_operation(operation) do
    if operation?(operation), do: :ok, else: {:error, {:unknown_operation, operation}}
  end

  # An entity reference the model gave that does not resolve comes back as a
  # correctable result payload with candidates, mirroring get_page, instead of
  # an opaque error.
  defp entity_resolution_payload(result) do
    case result do
      {:ok, payload} ->
        {:ok, JSON.plain(payload)}

      {:error, {:ambiguous_entity, candidates}} ->
        {:ok, %{"error" => "ambiguous_entity", "candidates" => JSON.plain(candidates)}}

      {:error, {:entity_not_found, entity}} ->
        {:ok, %{"error" => "entity_not_found", "entity" => entity}}

      {:error, _reason} = error ->
        error
    end
  end

  defp required(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing, key}}
          text -> {:ok, text}
        end

      _value ->
        {:error, {:missing, key}}
    end
  end

  defp optional_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp optional_text(_value), do: nil

  # An unparseable instant is an explicit error: silently treating it as absent
  # would widen the report to all history behind the caller's back.
  defp optional_datetime(params, key) do
    case Map.get(params, key) do
      empty when empty in [nil, ""] ->
        {:ok, nil}

      value when is_binary(value) ->
        case parse_datetime(value) do
          nil -> {:error, {:invalid_datetime, key}}
          datetime -> {:ok, datetime}
        end

      _value ->
        {:error, {:invalid_datetime, key}}
    end
  end

  # A plain ISO 8601 date is a natural model input for delta; it reads as
  # midnight UTC of that day.
  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        datetime

      {:error, _reason} ->
        case Date.from_iso8601(value) do
          {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
          {:error, _reason} -> nil
        end
    end
  end

  # Catalog

  defp description("remember") do
    Enum.join(
      [
        "Write one durable memory claim to the shared Brain.",
        "Use it for information with long-term value: facts, preferences, commitments, beliefs, events, and your own takes, bets, or hunches. Do not store small talk or transient task detail.",
        "Consult ConfidentialityPolicy.md when you choose scope. Omit scope to use the conversation audience; set it explicitly when the fact should reach a different audience. When one input contains parts with different disclosure ranges, split it and call remember once for each part with its own scope.",
        "holder names who HOLDS the judgment, not who the claim is about: when a person states an opinion about someone else, the holder is that person. Relaying someone's judgment keeps their holder; your own endorsement of it is a separate take.",
        "Use multiples of 0.05 for confidence and weight.",
        "The write persists immediately; a later failure or retry of this turn does not revert it."
      ],
      "\n"
    )
  end

  defp description("learn_source") do
    "Register one web url as a Brain learning source and start its learning run in the background. Consult the brain-learning skill for source routing and scope judgment before first use."
  end

  defp description("recall") do
    Enum.join(
      [
        "Search the Brain memory for stored knowledge that matches a query.",
        "Returns structured current facts and takes first, then page passages, inside the token budget.",
        "Give entity to narrow the search to one entity and its relation neighborhood."
      ],
      "\n"
    )
  end

  defp description("get_page") do
    "Read one full memory page by slug or by natural-language name. Returns the page body with its current facts, timeline, and links, cut to what you may see. An ambiguous reference returns candidates instead of a guess. A lazyload-agent-skills/ page is a Skill discovery record: load that Skill with skill_view."
  end

  defp description("forget") do
    "Remove one memory from recall. Give exactly one target: claim_id expires one claim; slug soft-deletes one page. The required reason enters the audit provenance."
  end

  defp description("entity") do
    "Read the entity card of one named entity: title, type, aliases, selected current facts, relations, and backlink count."
  end

  defp description("whoknows") do
    "Rank people and agents by what they hold about one topic. Use it to answer who in the organization knows a subject."
  end

  defp description("synthesize") do
    Enum.join(
      [
        "Synthesize stored memories into a durable analysis page that answers one question, and return that page.",
        "This runs a model over recalled evidence and is expensive: use it sparingly, only when recall and get_page cannot answer.",
        "The page takes the narrowest audience scope of its evidence, so a conclusion never reaches more people than the facts behind it. The result reports that scope and how many pieces of evidence the page could not carry."
      ],
      "\n"
    )
  end

  defp description("delta") do
    "Report what changed in memory: new, superseded, and expired claims and timeline events. Bound the report with entity, since, and until."
  end

  defp parameters("remember") do
    object_schema(
      %{
        "claim" =>
          string_schema(
            "One atomic assertion. Split a compound statement into separate remember calls.",
            max_length: 2_000
          ),
        "kind" => %{
          "type" => "string",
          "enum" => Claims.fact_kinds() ++ @take_kinds,
          "description" =>
            "The claim kind. Fact kinds record observations: 'event', 'preference', 'commitment', 'belief', 'fact'. Take kinds record judgments and predictions: 'take', 'bet', 'hunch'."
        },
        "scope" =>
          scope_schema(
            "Omitted scope binds the claim to this conversation's audience (DM asker, or the group's member Group). Set scope explicitly when the fact should reach a different audience: consult ConfidentialityPolicy.md and select the widest scope that does not break a known confidentiality requirement."
          ),
        "holder" =>
          string_schema(
            "Canonical page slug of who HOLDS this judgment, not who it is about. Defaults to you, the current agent."
          ),
        "entity" =>
          string_schema(
            "Page slug or name of an existing entity page to attach the claim to. A name that does not resolve files the claim to the current channel instead; the result reports the parent it landed on."
          ),
        "notability" => %{
          "type" => "string",
          "enum" => ["high", "medium", "low"],
          "description" => "Fact notability. Defaults to medium."
        },
        "confidence" =>
          grid_schema(
            "For fact kinds: certainty that the fact is correct, 0..1 in 0.05 steps. Defaults to 0.75. A fact the subject reports about themselves caps at 0.75 without independent support."
          ),
        "weight" =>
          grid_schema(
            "For take kinds: how strongly the holder holds the judgment, 0..1 in 0.05 steps. Defaults to 0.6. Your own adoption of a relayed judgment caps at 0.55."
          ),
        "until_date" => %{
          "type" => "string",
          "format" => "date",
          "description" =>
            "For take kinds only: the ISO date by which the judgment or prediction can be resolved."
        },
        "context" =>
          string_schema(
            "Necessary context that explains the fact; not a second claim. Applies to fact kinds only and is ignored for take kinds.",
            min_length: 0,
            max_length: 2_000
          ),
        "provenance" => string_schema("Quote or close paraphrase of the source of this claim.")
      },
      ["claim", "kind", "provenance"]
    )
  end

  defp parameters("learn_source") do
    object_schema(
      %{
        "url" =>
          Map.merge(
            string_schema("Public web address of the material to learn.", max_length: 2_000),
            %{"pattern" => "^https?://"}
          ),
        "scope" =>
          scope_schema(
            "Audience scope of the learned knowledge. Defaults to this conversation's scope. Pass 'world' only when the material is public and the requester wants the whole deployment to know it."
          )
      },
      ["url"]
    )
  end

  defp parameters("recall") do
    object_schema(
      %{
        "query" => string_schema("What to search for."),
        "entity" =>
          string_schema(
            "Page slug or name that narrows the search to one entity and its relation neighborhood."
          ),
        "budget_tokens" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 12_000,
          "description" => "Token budget for the result. Defaults to 4000."
        }
      },
      ["query"]
    )
  end

  defp parameters("get_page") do
    object_schema(
      %{
        "reference" => string_schema("Page slug or natural-language name of the page to read.")
      },
      ["reference"]
    )
  end

  defp parameters("forget") do
    object_schema(
      %{
        "claim_id" => string_schema("The claim to expire."),
        "slug" => string_schema("The page to soft-delete."),
        "reason" => string_schema("Why this memory must go. Recorded in the audit provenance.")
      },
      ["reason"]
    )
  end

  defp parameters("entity") do
    object_schema(
      %{"name" => string_schema("Page slug or natural-language name of the entity.")},
      ["name"]
    )
  end

  defp parameters("whoknows") do
    object_schema(
      %{
        "topic" => string_schema("The topic to find experts for."),
        "limit" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 20,
          "description" => "Maximum number of experts. Defaults to 5."
        }
      },
      ["topic"]
    )
  end

  defp parameters("synthesize") do
    object_schema(
      %{"question" => string_schema("The question to answer from stored memories.")},
      ["question"]
    )
  end

  defp parameters("delta") do
    object_schema(
      %{
        "entity" => string_schema("Page slug or name that bounds the report to one entity."),
        "since" => string_schema("ISO 8601 date or datetime start of the change window."),
        "until" => string_schema("ISO 8601 date or datetime end of the change window.")
      },
      []
    )
  end

  defp object_schema(properties, required) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
  end

  defp string_schema(description, opts \\ []) do
    %{
      "type" => "string",
      "minLength" => Keyword.get(opts, :min_length, 1),
      "description" => description
    }
    |> maybe_put("maxLength", Keyword.get(opts, :max_length))
  end

  defp scope_schema(description) do
    %{
      "type" => "string",
      "pattern" => "^(world|group:.+|principal:.+)$",
      "description" => description <> " " <> @audience_scope_description <> "."
    }
  end

  defp grid_schema(description) do
    %{
      "type" => "number",
      "minimum" => 0,
      "maximum" => 1,
      "multipleOf" => 0.05,
      "description" => description
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
