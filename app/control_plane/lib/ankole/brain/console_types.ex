defmodule Ankole.Brain.ConsoleTypes.BrainModelStatus do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        configured: [type: :boolean, allow_nil?: false],
        model: [type: :string, allow_nil?: true],
        profile: [type: :string, allow_nil?: true],
        profile_error: [type: :string, allow_nil?: true],
        provider_available: [type: :boolean, allow_nil?: true],
        provider_error: [type: :string, allow_nil?: true],
        provider_id: [type: :string, allow_nil?: true]
      ],
      preserve_nil_values?: true
    ]
end

defmodule Ankole.Brain.ConsoleTypes.BrainHealth do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        channels_without_member_group: [type: {:array, :string}, allow_nil?: false],
        config: [type: :map, allow_nil?: false],
        context_pack: [
          type: :map,
          allow_nil?: false,
          constraints: [
            fields: [
              degraded: [type: :integer, allow_nil?: false],
              served: [type: :integer, allow_nil?: false]
            ],
            preserve_nil_values?: true
          ]
        ],
        embedding_signature: [type: Ankole.Ash.Types.JSONValue, allow_nil?: true],
        embeddings: [
          type: :map,
          allow_nil?: false,
          constraints: [
            fields: [
              failed_chunks: [type: :integer, allow_nil?: false],
              failed_claims: [type: :integer, allow_nil?: false],
              pending_chunks: [type: :integer, allow_nil?: false],
              recent_error: [type: :string, allow_nil?: true]
            ],
            preserve_nil_values?: true
          ]
        ],
        enabled: [type: :boolean, allow_nil?: false],
        search_indexes: [type: :string, allow_nil?: false],
        models: [
          type: :map,
          allow_nil?: false,
          constraints: [
            fields: [
              dreaming: [type: Ankole.Brain.ConsoleTypes.BrainModelStatus, allow_nil?: false],
              embedding: [type: Ankole.Brain.ConsoleTypes.BrainModelStatus, allow_nil?: false],
              extraction: [type: Ankole.Brain.ConsoleTypes.BrainModelStatus, allow_nil?: false],
              rerank: [type: Ankole.Brain.ConsoleTypes.BrainModelStatus, allow_nil?: false],
              web_fetch: [type: Ankole.Brain.ConsoleTypes.BrainModelStatus, allow_nil?: false]
            ],
            preserve_nil_values?: true
          ]
        ],
        signals: [
          type: :map,
          allow_nil?: false,
          constraints: [
            fields: [
              oldest_pending_age_seconds: [type: :integer, allow_nil?: true],
              pending_channels: [type: :integer, allow_nil?: false]
            ],
            preserve_nil_values?: true
          ]
        ],
        skill_lessons: [
          type: :map,
          allow_nil?: false,
          constraints: [
            fields: [
              active_per_agent: [type: :map, allow_nil?: true],
              added_last_7d: [type: :integer, allow_nil?: true],
              enabled: [type: :boolean, allow_nil?: true],
              oldest_active_days: [type: :integer, allow_nil?: true],
              retired_last_7d: [type: :map, allow_nil?: true]
            ],
            preserve_nil_values?: true
          ]
        ],
        grading: [type: :map, allow_nil?: true]
      ],
      preserve_nil_values?: true
    ]
end

defmodule Ankole.Brain.ConsoleTypes.BrainHealthResponse do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [health: [type: Ankole.Brain.ConsoleTypes.BrainHealth, allow_nil?: false]],
      preserve_nil_values?: true
    ]
end

defmodule Ankole.Brain.ConsoleTypes.BrainObjectCandidate do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        slug: [type: :string, allow_nil?: false],
        subtype: [type: :string, allow_nil?: true],
        title: [type: :string, allow_nil?: false],
        type: [type: :string, allow_nil?: false]
      ],
      preserve_nil_values?: true
    ]
end

defmodule Ankole.Brain.ConsoleTypes.BrainObjectPage do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        page_id: [type: Ankole.Ash.Types.UUIDv7, allow_nil?: false],
        slug: [type: :string, allow_nil?: false],
        title: [type: :string, allow_nil?: false],
        type: [type: :string, allow_nil?: false],
        summary: [type: :string, allow_nil?: false],
        revision: [type: :integer, allow_nil?: false],
        pod_url: [type: :string, allow_nil?: false]
      ]
    ]
end

defmodule Ankole.Brain.ConsoleTypes.BrainObjectShowResponse do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        candidates: [
          type: {:array, Ankole.Brain.ConsoleTypes.BrainObjectCandidate},
          allow_nil?: true
        ],
        object: [type: Ankole.Brain.ConsoleTypes.BrainObjectPage, allow_nil?: true]
      ],
      preserve_nil_values?: true
    ]
end

defmodule Ankole.Brain.ConsoleTypes.BrainObjectTypesResponse do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [types: [type: {:array, :string}, allow_nil?: false]],
      preserve_nil_values?: true
    ]
end

defmodule Ankole.Brain.ConsoleTypes.BrainDreamResponse do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        result: [
          type: :map,
          allow_nil?: false,
          constraints: [
            fields: [status: [type: :string, allow_nil?: false]],
            preserve_nil_values?: true
          ]
        ]
      ],
      preserve_nil_values?: true
    ]
end

defmodule Ankole.Brain.ConsoleTypes.BrainRecallChunk do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        source_node_id: [type: :string, allow_nil?: false],
        chunk_index: [type: :integer, allow_nil?: false],
        content_kind: [type: :string, allow_nil?: true],
        subject_page_id: [type: :string, allow_nil?: true],
        text: [type: :string, allow_nil?: false],
        title: [type: :string, allow_nil?: false],
        type: [type: :string, allow_nil?: false]
      ],
      preserve_nil_values?: true
    ]
end

defmodule Ankole.Brain.ConsoleTypes.BrainRecallClaim do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        source_node_id: [type: :string, allow_nil?: false],
        claim: [type: :string, allow_nil?: false],
        claim_type: [type: :string, allow_nil?: false],
        confidence: [type: :float, allow_nil?: true],
        conversation_id: [type: :string, allow_nil?: true],
        holder: [type: :string, allow_nil?: true],
        id: [type: :string, allow_nil?: false],
        kind: [type: :string, allow_nil?: true],
        notability: [type: :string, allow_nil?: true],
        subject_page_id: [type: :string, allow_nil?: true],
        provenance: [type: :string, allow_nil?: true],
        since_date: [type: :string, allow_nil?: true],
        until_date: [type: :string, allow_nil?: true],
        valid_from: [type: :string, allow_nil?: true],
        valid_until: [type: :string, allow_nil?: true],
        weight: [type: :float, allow_nil?: true]
      ],
      preserve_nil_values?: true
    ]
end

defmodule Ankole.Brain.ConsoleTypes.BrainRecallResult do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        chunks: [type: {:array, Ankole.Brain.ConsoleTypes.BrainRecallChunk}, allow_nil?: false],
        claims: [type: {:array, Ankole.Brain.ConsoleTypes.BrainRecallClaim}, allow_nil?: false]
      ],
      preserve_nil_values?: true
    ]
end

defmodule Ankole.Brain.ConsoleTypes.BrainSearchPreviewResponse do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [result: [type: Ankole.Brain.ConsoleTypes.BrainRecallResult, allow_nil?: false]],
      preserve_nil_values?: true
    ]
end

defmodule Ankole.Brain.ConsoleTypes.BrainClaim do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        active: [type: :boolean, allow_nil?: true],
        source_node_id: [type: :string, allow_nil?: false],
        author: [type: Ankole.Ash.Types.ActorRef, allow_nil?: true],
        claim: [type: :string, allow_nil?: false],
        claim_type: [type: :string, allow_nil?: false],
        confidence: [type: :float, allow_nil?: true],
        conversation_id: [type: :string, allow_nil?: true],
        created_at: [type: :string, allow_nil?: false],
        expired_at: [type: :string, allow_nil?: true],
        graded_by: [type: :string, allow_nil?: true],
        resolved_by: [type: :string, allow_nil?: true],
        graded_confidence: [type: :float, allow_nil?: true],
        graded_quality: [type: :string, allow_nil?: true],
        holder: [type: :string, allow_nil?: true],
        id: [type: :string, allow_nil?: false],
        kind: [type: :string, allow_nil?: true],
        notability: [type: :string, allow_nil?: true],
        subject_page_id: [type: :string, allow_nil?: true],
        provenance: [type: :string, allow_nil?: true],
        resolved_at: [type: :string, allow_nil?: true],
        resolved_outcome: [type: :boolean, allow_nil?: true],
        resolved_quality: [type: :string, allow_nil?: true],
        since_date: [type: :string, allow_nil?: true],
        superseded_by: [type: :string, allow_nil?: true],
        until_date: [type: :string, allow_nil?: true],
        valid_from: [type: :string, allow_nil?: true],
        valid_until: [type: :string, allow_nil?: true],
        weight: [type: :float, allow_nil?: true]
      ],
      preserve_nil_values?: true
    ]
end

defmodule Ankole.Brain.ConsoleTypes.BrainClaimListResponse do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [claims: [type: {:array, Ankole.Brain.ConsoleTypes.BrainClaim}, allow_nil?: false]],
      preserve_nil_values?: true
    ]
end
