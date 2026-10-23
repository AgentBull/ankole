defmodule AnkoleWeb.Schemas.BrainAPI do
  @moduledoc """
  OpenAPI schemas for the Brain Console API.

  These declarations are the single ownership point for the Brain request
  and response shapes: the generated Console client types come from here,
  so a server change surfaces in the generation check instead of drifting
  past a hand-written mirror.
  """

  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.ActorRef

  defmodule BrainObjectTypesResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainObjectTypesResponse",
        type: :object,
        properties: %{
          types: %Schema{type: :array, items: %Schema{type: :string}}
        },
        required: [:types],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrainPageFact do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainPageFact",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          claim: %Schema{type: :string},
          kind: %Schema{type: :string, nullable: true},
          holder: %Schema{type: :string, nullable: true},
          notability: %Schema{type: :string, nullable: true},
          confidence: %Schema{type: :number, nullable: true},
          valid_from: %Schema{type: :string, nullable: true},
          valid_until: %Schema{type: :string, nullable: true},
          expired_at: %Schema{type: :string, nullable: true},
          superseded_by: %Schema{type: :string, nullable: true},
          provenance: %Schema{type: :string, nullable: true},
          audience_scope: %Schema{type: :string},
          author: %Schema{allOf: [ActorRef], nullable: true}
        },
        required: [:id, :claim, :audience_scope],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrainPageTake do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainPageTake",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          claim: %Schema{type: :string},
          kind: %Schema{type: :string, nullable: true},
          holder: %Schema{type: :string, nullable: true},
          weight: %Schema{type: :number, nullable: true},
          active: %Schema{type: :boolean, nullable: true},
          since_date: %Schema{type: :string, nullable: true},
          until_date: %Schema{type: :string, nullable: true},
          graded_quality: %Schema{type: :string, nullable: true},
          graded_confidence: %Schema{type: :number, nullable: true},
          graded_at: %Schema{type: :string, nullable: true},
          resolved_quality: %Schema{type: :string, nullable: true},
          resolved_outcome: %Schema{type: :boolean, nullable: true},
          resolved_at: %Schema{type: :string, nullable: true},
          superseded_by: %Schema{type: :string, nullable: true},
          provenance: %Schema{type: :string, nullable: true},
          audience_scope: %Schema{type: :string},
          author: %Schema{allOf: [ActorRef], nullable: true}
        },
        required: [:id, :claim, :audience_scope],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrainPageTimeline do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainPageTimeline",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          date: %Schema{type: :string},
          summary: %Schema{type: :string},
          detail: %Schema{type: :string, nullable: true},
          provenance: %Schema{type: :string, nullable: true},
          event_object_slug: %Schema{type: :string, nullable: true},
          audience_scope: %Schema{type: :string},
          author: %Schema{allOf: [ActorRef], nullable: true}
        },
        required: [:id, :date, :summary, :audience_scope],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrainPageLinks do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainPageLinks",
        type: :object,
        properties: %{
          outgoing: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                to: %Schema{type: :string},
                link_type: %Schema{type: :string},
                context: %Schema{type: :string, nullable: true}
              },
              required: [:to, :link_type, :context],
              additionalProperties: false
            }
          },
          incoming: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                from: %Schema{type: :string},
                link_type: %Schema{type: :string},
                context: %Schema{type: :string, nullable: true}
              },
              required: [:from, :link_type, :context],
              additionalProperties: false
            }
          }
        },
        required: [:outgoing, :incoming],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrainPageContradiction do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainPageContradiction",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          verdict: %Schema{type: :string},
          axis: %Schema{type: :string, nullable: true},
          severity: %Schema{type: :string},
          claim_id: %Schema{type: :string},
          counterpart: %Schema{
            type: :object,
            properties: %{
              id: %Schema{type: :string},
              claim: %Schema{type: :string},
              holder: %Schema{type: :string, nullable: true}
            },
            required: [:id, :claim],
            additionalProperties: false
          }
        },
        required: [:id, :verdict, :severity, :claim_id, :counterpart],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrainObjectPage do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainObjectPage",
        type: :object,
        properties: %{
          slug: %Schema{type: :string},
          type: %Schema{type: :string},
          subtype: %Schema{type: :string, nullable: true},
          title: %Schema{type: :string},
          deleted: %Schema{type: :boolean},
          effective_date: %Schema{type: :string, nullable: true},
          content_hash: %Schema{type: :string, nullable: true},
          library_managed: %Schema{
            type: :boolean,
            description:
              "True when a Brain Source owns the body projection. Use edit_block_reason to select the supported management action."
          },
          body: %Schema{type: :string},
          rendered: %Schema{type: :string},
          editable: %Schema{type: :boolean},
          edit_block_reason: %Schema{
            type: :string,
            nullable: true
          },
          meta: %Schema{type: :object, additionalProperties: true},
          facts: %Schema{type: :array, items: BrainPageFact},
          takes: %Schema{type: :array, items: BrainPageTake},
          contradictions: %Schema{type: :array, items: BrainPageContradiction},
          timelines: %Schema{type: :array, items: BrainPageTimeline},
          tags: %Schema{type: :array, items: %Schema{type: :string}},
          links: BrainPageLinks
        },
        required: [
          :slug,
          :type,
          :title,
          :deleted,
          :content_hash,
          :body,
          :rendered,
          :editable,
          :edit_block_reason,
          :meta,
          :facts,
          :takes,
          :contradictions,
          :timelines,
          :tags,
          :links
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrainObjectCandidate do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainObjectCandidate",
        type: :object,
        properties: %{
          slug: %Schema{type: :string},
          title: %Schema{type: :string},
          type: %Schema{type: :string},
          subtype: %Schema{type: :string, nullable: true}
        },
        required: [:slug, :title, :type],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrainObjectShowResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainObjectShowResponse",
        type: :object,
        properties: %{
          object: BrainObjectPage,
          candidates: %Schema{type: :array, items: BrainObjectCandidate}
        },
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrainClaim do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainClaim",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          claim_type: %Schema{type: :string, enum: ["fact", "take"]},
          claim: %Schema{type: :string},
          kind: %Schema{type: :string, nullable: true},
          holder: %Schema{type: :string, nullable: true},
          audience_scope: %Schema{type: :string},
          author: %Schema{allOf: [ActorRef], nullable: true},
          object_slug: %Schema{type: :string, nullable: true},
          conversation_id: %Schema{type: :string, format: :uuid, nullable: true},
          notability: %Schema{type: :string, nullable: true},
          confidence: %Schema{type: :number, nullable: true},
          valid_from: %Schema{type: :string, nullable: true},
          valid_until: %Schema{type: :string, nullable: true},
          expired_at: %Schema{type: :string, nullable: true},
          weight: %Schema{type: :number, nullable: true},
          active: %Schema{type: :boolean, nullable: true},
          since_date: %Schema{type: :string, nullable: true},
          until_date: %Schema{type: :string, nullable: true},
          graded_quality: %Schema{type: :string, nullable: true},
          graded_confidence: %Schema{type: :number, nullable: true},
          resolved_quality: %Schema{type: :string, nullable: true},
          resolved_outcome: %Schema{type: :boolean, nullable: true},
          resolved_at: %Schema{type: :string, nullable: true},
          superseded_by: %Schema{type: :string, nullable: true},
          provenance: %Schema{type: :string, nullable: true},
          created_at: %Schema{type: :string}
        },
        required: [:id, :claim_type, :claim, :audience_scope, :created_at],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrainClaimListResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainClaimListResponse",
        type: :object,
        properties: %{
          claims: %Schema{type: :array, items: BrainClaim}
        },
        required: [:claims],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrainDreamResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainDreamResponse",
        type: :object,
        properties: %{
          result: %Schema{
            type: :object,
            properties: %{
              status: %Schema{type: :string, enum: ["enqueued", "already_pending"]}
            },
            required: [:status],
            additionalProperties: false
          }
        },
        required: [:result],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrainModelStatus do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainModelStatus",
        type: :object,
        properties: %{
          configured: %Schema{type: :boolean},
          provider_id: %Schema{type: :string, nullable: true},
          model: %Schema{type: :string, nullable: true},
          provider_available: %Schema{type: :boolean, nullable: true},
          provider_error: %Schema{type: :string, nullable: true},
          profile: %Schema{type: :string, nullable: true},
          profile_error: %Schema{type: :string, nullable: true}
        },
        required: [:configured],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrainHealth do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainHealth",
        type: :object,
        properties: %{
          enabled: %Schema{type: :boolean},
          maintainer_agent_uid: %Schema{type: :string, nullable: true},
          config: %Schema{
            type: :object,
            description: "Per brain.* key: \"ok\", or {invalid: reason} for a broken stored row.",
            additionalProperties: AnkoleWeb.Schemas.ConsoleAPI.JSONValue
          },
          models: %Schema{
            type: :object,
            properties: %{
              embedding: BrainModelStatus,
              rerank: BrainModelStatus,
              web_fetch: BrainModelStatus,
              extraction: BrainModelStatus,
              dreaming: BrainModelStatus
            },
            required: [:embedding, :rerank, :web_fetch, :extraction, :dreaming],
            additionalProperties: false
          },
          embedding_signature: AnkoleWeb.Schemas.ConsoleAPI.JSONValue,
          signals: %Schema{
            type: :object,
            properties: %{
              pending_channels: %Schema{type: :integer},
              oldest_pending_age_seconds: %Schema{type: :integer, nullable: true}
            },
            required: [:pending_channels],
            additionalProperties: false
          },
          embeddings: %Schema{
            type: :object,
            properties: %{
              failed_chunks: %Schema{type: :integer},
              failed_claims: %Schema{type: :integer},
              pending_chunks: %Schema{type: :integer},
              recent_error: %Schema{type: :string, nullable: true}
            },
            required: [:failed_chunks, :failed_claims, :pending_chunks],
            additionalProperties: false
          },
          context_pack: %Schema{
            type: :object,
            description: "Injection counters since this node booted.",
            properties: %{
              served: %Schema{type: :integer},
              degraded: %Schema{type: :integer}
            },
            required: [:served, :degraded],
            additionalProperties: false
          },
          channels_without_member_group: %Schema{
            type: :array,
            items: %Schema{type: :string}
          },
          skill_lessons: %Schema{
            type: :object,
            description: "Skill-lesson drift signals, all read from agent_skill_lessons.",
            properties: %{
              enabled: %Schema{type: :boolean},
              active_per_agent: %Schema{
                type: :object,
                additionalProperties: %Schema{type: :integer}
              },
              added_last_7d: %Schema{type: :integer},
              retired_last_7d: %Schema{
                type: :object,
                additionalProperties: %Schema{type: :integer}
              },
              oldest_active_days: %Schema{type: :integer, nullable: true}
            },
            additionalProperties: false
          }
        },
        required: [
          :enabled,
          :maintainer_agent_uid,
          :config,
          :models,
          :signals,
          :embeddings,
          :context_pack,
          :channels_without_member_group,
          :skill_lessons
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrainHealthResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainHealthResponse",
        type: :object,
        properties: %{
          health: BrainHealth
        },
        required: [:health],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrainRecallClaim do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainRecallClaim",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          claim_type: %Schema{type: :string},
          claim: %Schema{type: :string},
          kind: %Schema{type: :string, nullable: true},
          holder: %Schema{type: :string, nullable: true},
          confidence: %Schema{type: :number, nullable: true},
          weight: %Schema{type: :number, nullable: true},
          notability: %Schema{type: :string, nullable: true},
          valid_from: %Schema{type: :string, nullable: true},
          valid_until: %Schema{type: :string, nullable: true},
          since_date: %Schema{type: :string, nullable: true},
          until_date: %Schema{type: :string, nullable: true},
          object_slug: %Schema{type: :string, nullable: true},
          conversation_id: %Schema{type: :string, format: :uuid, nullable: true},
          provenance: %Schema{type: :string, nullable: true},
          audience_scope: %Schema{type: :string}
        },
        required: [:id, :claim_type, :claim, :audience_scope],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrainRecallChunk do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainRecallChunk",
        type: :object,
        properties: %{
          object_slug: %Schema{type: :string},
          title: %Schema{type: :string},
          type: %Schema{type: :string},
          chunk_index: %Schema{type: :integer},
          content_kind: %Schema{type: :string, nullable: true},
          text: %Schema{type: :string},
          audience_scope: %Schema{type: :string}
        },
        required: [:object_slug, :title, :type, :chunk_index, :text, :audience_scope],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrainRecallResult do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainRecallResult",
        type: :object,
        properties: %{
          claims: %Schema{type: :array, items: BrainRecallClaim},
          chunks: %Schema{type: :array, items: BrainRecallChunk}
        },
        required: [:claims, :chunks],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrainSearchPreviewRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainSearchPreviewRequest",
        type: :object,
        properties: %{
          principal_uid: %Schema{type: :string},
          query: %Schema{type: :string},
          disclosure_mode: %Schema{type: :string, enum: ["strict", "relaxed"], nullable: true},
          asker_uid: %Schema{type: :string, nullable: true},
          present_uids: %Schema{type: :array, items: %Schema{type: :string}, nullable: true}
        },
        required: [:principal_uid, :query],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrainSearchPreviewResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainSearchPreviewResponse",
        type: :object,
        properties: %{
          result: BrainRecallResult
        },
        required: [:result],
        additionalProperties: false
      },
      struct?: false
    )
  end
end
