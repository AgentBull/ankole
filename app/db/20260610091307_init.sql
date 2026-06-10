CREATE EXTENSION IF NOT EXISTS vector;--> statement-breakpoint
CREATE TYPE "public"."principal_group_kind" AS ENUM('static', 'computed');--> statement-breakpoint
CREATE TYPE "public"."agent_type" AS ENUM('llm_agentic_loop');--> statement-breakpoint
CREATE TYPE "public"."principal_external_identity_kind" AS ENUM('platform_subject', 'channel_actor', 'login_subject', 'outbound_actor');--> statement-breakpoint
CREATE TYPE "public"."principal_status" AS ENUM('active', 'disabled');--> statement-breakpoint
CREATE TYPE "public"."principal_type" AS ENUM('human', 'agent');--> statement-breakpoint
CREATE TABLE "app_configure" (
	"key" text NOT NULL,
	"value" jsonb NOT NULL,
	"created_at" timestamp DEFAULT CURRENT_TIMESTAMP NOT NULL,
	"updated_at" timestamp DEFAULT CURRENT_TIMESTAMP NOT NULL,
	CONSTRAINT "key_unique" UNIQUE("key"),
	CONSTRAINT "app_configure_value_envelope" CHECK (jsonb_typeof("app_configure"."value") = 'object' AND "app_configure"."value" ? 'type' AND "app_configure"."value" ? 'value')
);
--> statement-breakpoint
CREATE TABLE "permission_grants" (
	"id" uuid PRIMARY KEY NOT NULL,
	"principal_uid" text,
	"group_id" uuid,
	"resource_pattern" text NOT NULL,
	"action" text NOT NULL,
	"condition" text DEFAULT 'true' NOT NULL,
	"description" text,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"created_at" timestamp DEFAULT CURRENT_TIMESTAMP NOT NULL,
	"updated_at" timestamp DEFAULT CURRENT_TIMESTAMP NOT NULL,
	CONSTRAINT "permission_grants_principal_exclusive" CHECK (("permission_grants"."principal_uid" IS NOT NULL AND "permission_grants"."group_id" IS NULL) OR ("permission_grants"."principal_uid" IS NULL AND "permission_grants"."group_id" IS NOT NULL)),
	CONSTRAINT "permission_grants_action_no_colon" CHECK (position(':' in "permission_grants"."action") = 0),
	CONSTRAINT "permission_grants_resource_pattern_present" CHECK (length("permission_grants"."resource_pattern") > 0),
	CONSTRAINT "permission_grants_action_present" CHECK (length("permission_grants"."action") > 0),
	CONSTRAINT "permission_grants_metadata_object" CHECK (jsonb_typeof("permission_grants"."metadata") = 'object')
);
--> statement-breakpoint
CREATE TABLE "principal_group_external_bindings" (
	"provider" text NOT NULL,
	"external_id" text NOT NULL,
	"group_id" uuid NOT NULL,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"created_at" timestamp DEFAULT CURRENT_TIMESTAMP NOT NULL,
	"updated_at" timestamp DEFAULT CURRENT_TIMESTAMP NOT NULL,
	CONSTRAINT "principal_group_external_bindings_provider_external_id_pk" PRIMARY KEY("provider","external_id"),
	CONSTRAINT "principal_group_external_bindings_provider_present" CHECK (length(btrim("principal_group_external_bindings"."provider")) > 0),
	CONSTRAINT "principal_group_external_bindings_provider_format" CHECK ("principal_group_external_bindings"."provider" ~ '^[a-z][a-z0-9_-]*$'),
	CONSTRAINT "principal_group_external_bindings_external_id_present" CHECK (length(btrim("principal_group_external_bindings"."external_id")) > 0),
	CONSTRAINT "principal_group_external_bindings_metadata_object" CHECK (jsonb_typeof("principal_group_external_bindings"."metadata") = 'object')
);
--> statement-breakpoint
CREATE TABLE "principal_group_memberships" (
	"principal_uid" text NOT NULL,
	"group_id" uuid NOT NULL,
	"created_at" timestamp DEFAULT CURRENT_TIMESTAMP NOT NULL,
	"updated_at" timestamp DEFAULT CURRENT_TIMESTAMP NOT NULL,
	CONSTRAINT "principal_group_memberships_principal_uid_group_id_pk" PRIMARY KEY("principal_uid","group_id")
);
--> statement-breakpoint
CREATE TABLE "principal_groups" (
	"id" uuid PRIMARY KEY NOT NULL,
	"name" text NOT NULL,
	"kind" "principal_group_kind" DEFAULT 'static' NOT NULL,
	"description" text,
	"computed_condition" text,
	"built_in" boolean DEFAULT false NOT NULL,
	"created_at" timestamp DEFAULT CURRENT_TIMESTAMP NOT NULL,
	"updated_at" timestamp DEFAULT CURRENT_TIMESTAMP NOT NULL,
	CONSTRAINT "principal_groups_name_present" CHECK (length(btrim("principal_groups"."name")) > 0),
	CONSTRAINT "principal_groups_name_lowercase" CHECK ("principal_groups"."name" = lower("principal_groups"."name")),
	CONSTRAINT "principal_groups_computed_condition_by_kind" CHECK (("principal_groups"."kind" = 'static' AND "principal_groups"."computed_condition" IS NULL) OR ("principal_groups"."kind" = 'computed' AND length(btrim("principal_groups"."computed_condition")) > 0))
);
--> statement-breakpoint
CREATE TABLE "ai_agent_conversations" (
	"id" uuid PRIMARY KEY NOT NULL,
	"agent_uid" text NOT NULL,
	"conversation_key" text NOT NULL,
	"ended_at" timestamp with time zone,
	"generation" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "ai_agent_conversations_key_nonempty" CHECK ("ai_agent_conversations"."conversation_key" <> ''),
	CONSTRAINT "ai_agent_conversations_generation_object" CHECK (jsonb_typeof("ai_agent_conversations"."generation") = 'object'),
	CONSTRAINT "ai_agent_conversations_metadata_object" CHECK (jsonb_typeof("ai_agent_conversations"."metadata") = 'object')
);
--> statement-breakpoint
CREATE TABLE "ai_agent_llm_turns" (
	"id" uuid PRIMARY KEY NOT NULL,
	"agent_uid" text NOT NULL,
	"conversation_id" uuid NOT NULL,
	"kind" text NOT NULL,
	"status" text DEFAULT 'started' NOT NULL,
	"profile" text NOT NULL,
	"provider" text NOT NULL,
	"model" text NOT NULL,
	"reasoning" text,
	"temperature" numeric,
	"max_tokens" integer,
	"cache_retention" text,
	"lease_id" text,
	"call_index" integer,
	"branch_id" text,
	"parent_branch_id" text,
	"trigger_message_id" uuid,
	"trigger_event_id" text,
	"input_message_ids" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"input_summary_message_id" uuid,
	"request_context" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"request_refs" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"request_patches" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"response" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"tool_results" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"usage" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"provider_metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"started_at" timestamp with time zone DEFAULT now() NOT NULL,
	"completed_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "ai_agent_llm_turns_kind_check" CHECK ("ai_agent_llm_turns"."kind" in ('generation', 'retry_generation', 'scheduled_task', 'checkback_generation', 'compression', 'ambient_recognizer', 'overflow_retry')),
	CONSTRAINT "ai_agent_llm_turns_status_check" CHECK ("ai_agent_llm_turns"."status" in ('started', 'succeeded', 'failed', 'cancelled')),
	CONSTRAINT "ai_agent_llm_turns_profile_check" CHECK ("ai_agent_llm_turns"."profile" in ('primary', 'light', 'heavy')),
	CONSTRAINT "ai_agent_llm_turns_call_index_nonnegative" CHECK ("ai_agent_llm_turns"."call_index" IS NULL OR "ai_agent_llm_turns"."call_index" >= 0),
	CONSTRAINT "ai_agent_llm_turns_input_message_ids_array" CHECK (jsonb_typeof("ai_agent_llm_turns"."input_message_ids") = 'array'),
	CONSTRAINT "ai_agent_llm_turns_request_context_object" CHECK (jsonb_typeof("ai_agent_llm_turns"."request_context") = 'object'),
	CONSTRAINT "ai_agent_llm_turns_request_refs_array" CHECK (jsonb_typeof("ai_agent_llm_turns"."request_refs") = 'array'),
	CONSTRAINT "ai_agent_llm_turns_request_patches_array" CHECK (jsonb_typeof("ai_agent_llm_turns"."request_patches") = 'array'),
	CONSTRAINT "ai_agent_llm_turns_response_object" CHECK (jsonb_typeof("ai_agent_llm_turns"."response") = 'object'),
	CONSTRAINT "ai_agent_llm_turns_tool_results_array" CHECK (jsonb_typeof("ai_agent_llm_turns"."tool_results") = 'array'),
	CONSTRAINT "ai_agent_llm_turns_usage_object" CHECK (jsonb_typeof("ai_agent_llm_turns"."usage") = 'object'),
	CONSTRAINT "ai_agent_llm_turns_provider_metadata_object" CHECK (jsonb_typeof("ai_agent_llm_turns"."provider_metadata") = 'object')
);
--> statement-breakpoint
CREATE TABLE "ai_agent_messages" (
	"id" uuid PRIMARY KEY NOT NULL,
	"agent_uid" text NOT NULL,
	"conversation_id" uuid NOT NULL,
	"role" text NOT NULL,
	"kind" text DEFAULT 'normal' NOT NULL,
	"status" text DEFAULT 'complete' NOT NULL,
	"content" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"agent_message" jsonb,
	"covers_range" jsonb,
	"event_source" text,
	"event_id" text,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "ai_agent_messages_role_check" CHECK ("ai_agent_messages"."role" in ('user', 'assistant', 'tool', 'im_ambient')),
	CONSTRAINT "ai_agent_messages_kind_check" CHECK ("ai_agent_messages"."kind" in ('normal', 'summary', 'introspection', 'error')),
	CONSTRAINT "ai_agent_messages_status_check" CHECK ("ai_agent_messages"."status" in ('generating', 'complete')),
	CONSTRAINT "ai_agent_messages_content_array" CHECK (jsonb_typeof("ai_agent_messages"."content") = 'array'),
	CONSTRAINT "ai_agent_messages_metadata_object" CHECK (jsonb_typeof("ai_agent_messages"."metadata") = 'object')
);
--> statement-breakpoint
CREATE TABLE "chat_recall_embeddings" (
	"document_id" uuid NOT NULL,
	"profile_id" text NOT NULL,
	"provider_kind" text NOT NULL,
	"provider_id" text NOT NULL,
	"model" text NOT NULL,
	"dimensions" integer DEFAULT 0 NOT NULL,
	"embedding" vector,
	"content_hash" text NOT NULL,
	"status" text DEFAULT 'pending' NOT NULL,
	"attempt_count" integer DEFAULT 0 NOT NULL,
	"next_retry_at" timestamp with time zone DEFAULT now() NOT NULL,
	"locked_at" timestamp with time zone,
	"last_error" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "chat_recall_embeddings_pkey" PRIMARY KEY("document_id","profile_id"),
	CONSTRAINT "chat_recall_embeddings_dimensions_check" CHECK ("chat_recall_embeddings"."dimensions" >= 0),
	CONSTRAINT "chat_recall_embeddings_status_check" CHECK ("chat_recall_embeddings"."status" in ('pending', 'processing', 'synced', 'failed'))
);
--> statement-breakpoint
CREATE TABLE "external_agent_room_observations" (
	"agent_uid" text NOT NULL,
	"binding_name" text NOT NULL,
	"room_id" text NOT NULL,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"observed_at" timestamp with time zone DEFAULT now() NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "external_agent_room_observations_pkey" PRIMARY KEY("agent_uid","binding_name","room_id"),
	CONSTRAINT "external_agent_room_observations_metadata_object" CHECK (jsonb_typeof("external_agent_room_observations"."metadata") = 'object')
);
--> statement-breakpoint
CREATE UNLOGGED TABLE "external_gateway_agent_events" (
	"agent_uid" text NOT NULL,
	"binding_name" text NOT NULL,
	"provider_room_id" text NOT NULL,
	"provider_thread_id" text NOT NULL,
	"provider_event_id" text NOT NULL,
	"provider_message_id" text,
	"type" text NOT NULL,
	"delivery_mode" text NOT NULL,
	"batch_key" text,
	"actor_key" text,
	"payload" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"status" text DEFAULT 'pending' NOT NULL,
	"available_at" timestamp with time zone DEFAULT now() NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "external_gateway_agent_events_pkey" PRIMARY KEY("agent_uid","binding_name","provider_event_id"),
	CONSTRAINT "external_gateway_agent_events_payload_object" CHECK (jsonb_typeof("external_gateway_agent_events"."payload") = 'object'),
	CONSTRAINT "external_gateway_agent_events_status_check" CHECK ("external_gateway_agent_events"."status" in ('pending', 'done', 'failed')),
	CONSTRAINT "external_gateway_agent_events_delivery_mode_check" CHECK ("external_gateway_agent_events"."delivery_mode" in ('addressed', 'ambient', 'command', 'action', 'lifecycle'))
);
--> statement-breakpoint
CREATE UNLOGGED TABLE "external_gateway_input_tombstones" (
	"agent_uid" text NOT NULL,
	"binding_name" text NOT NULL,
	"provider_room_id" text NOT NULL,
	"provider_message_id" text NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "external_gateway_input_tombstones_pkey" PRIMARY KEY("agent_uid","binding_name","provider_room_id","provider_message_id")
);
--> statement-breakpoint
CREATE TABLE "external_gateway_outbox" (
	"agent_uid" text NOT NULL,
	"binding_name" text NOT NULL,
	"provider_room_id" text NOT NULL,
	"provider_thread_id" text NOT NULL,
	"outbound_key" text NOT NULL,
	"operation" text NOT NULL,
	"final_payload" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"status" text DEFAULT 'pending' NOT NULL,
	"provider_message_id" text,
	"idempotency_key" text,
	"retry_count" integer DEFAULT 0 NOT NULL,
	"last_attempt_at" timestamp with time zone,
	"last_error" text,
	"platform_send_started_at" timestamp with time zone,
	"recovery_state" text DEFAULT 'not_started' NOT NULL,
	"safe_error" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "external_gateway_outbox_pkey" PRIMARY KEY("agent_uid","binding_name","outbound_key"),
	CONSTRAINT "external_gateway_outbox_final_payload_object" CHECK (jsonb_typeof("external_gateway_outbox"."final_payload") = 'object'),
	CONSTRAINT "external_gateway_outbox_status_check" CHECK ("external_gateway_outbox"."status" in ('pending', 'sent', 'failed', 'unsupported')),
	CONSTRAINT "external_gateway_outbox_recovery_state_check" CHECK ("external_gateway_outbox"."recovery_state" in ('not_started', 'send_attempt_started', 'unknown_after_send')),
	CONSTRAINT "external_gateway_outbox_operation_check" CHECK ("external_gateway_outbox"."operation" in ('post', 'reply', 'edit', 'delete', 'reaction_add', 'reaction_remove', 'modal', 'card', 'divider'))
);
--> statement-breakpoint
CREATE TABLE "external_messages" (
	"document_id" uuid DEFAULT gen_random_uuid() NOT NULL,
	"room_id" text NOT NULL,
	"message_id" text NOT NULL,
	"author_id" text,
	"user_key" text,
	"author" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"mentions" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"text" text,
	"formatted" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"attachments" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"links" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"reactions" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"raw" jsonb,
	"search_text" text DEFAULT '' NOT NULL,
	"metadata_text" text DEFAULT '' NOT NULL,
	"content_hash" text DEFAULT '' NOT NULL,
	"sent_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "external_messages_pkey" PRIMARY KEY("room_id","message_id"),
	CONSTRAINT "external_messages_message_id_nonempty" CHECK ("external_messages"."message_id" <> ''),
	CONSTRAINT "external_messages_author_object" CHECK (jsonb_typeof("external_messages"."author") = 'object'),
	CONSTRAINT "external_messages_mentions_array" CHECK (jsonb_typeof("external_messages"."mentions") = 'array'),
	CONSTRAINT "external_messages_formatted_object" CHECK (jsonb_typeof("external_messages"."formatted") = 'object'),
	CONSTRAINT "external_messages_attachments_array" CHECK (jsonb_typeof("external_messages"."attachments") = 'array'),
	CONSTRAINT "external_messages_links_array" CHECK (jsonb_typeof("external_messages"."links") = 'array'),
	CONSTRAINT "external_messages_metadata_object" CHECK (jsonb_typeof("external_messages"."metadata") = 'object'),
	CONSTRAINT "external_messages_reactions_object" CHECK (jsonb_typeof("external_messages"."reactions") = 'object')
);
--> statement-breakpoint
CREATE TABLE "external_room_memberships" (
	"room_id" text NOT NULL,
	"principal_uid" text NOT NULL,
	"external_id" text,
	"source" text DEFAULT 'message_author' NOT NULL,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"observed_at" timestamp with time zone DEFAULT now() NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "external_room_memberships_pkey" PRIMARY KEY("room_id","principal_uid"),
	CONSTRAINT "external_room_memberships_metadata_object" CHECK (jsonb_typeof("external_room_memberships"."metadata") = 'object')
);
--> statement-breakpoint
CREATE TABLE "external_rooms" (
	"id" text PRIMARY KEY NOT NULL,
	"is_dm" boolean DEFAULT false NOT NULL,
	"room_visibility" text DEFAULT 'unknown' NOT NULL,
	"name" text,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"raw" jsonb,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "external_rooms_id_nonempty" CHECK ("external_rooms"."id" <> ''),
	CONSTRAINT "external_rooms_metadata_object" CHECK (jsonb_typeof("external_rooms"."metadata") = 'object')
);
--> statement-breakpoint
CREATE TABLE "agent_library_container_entries" (
	"id" uuid PRIMARY KEY NOT NULL,
	"agent_uid" text NOT NULL,
	"virtual_path" text NOT NULL,
	"entry_kind" text DEFAULT 'file' NOT NULL,
	"source_kind" text NOT NULL,
	"source_ref" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"content_text" text,
	"content_bytes" text,
	"content_media_type" text DEFAULT 'text/plain' NOT NULL,
	"content_blake3" text NOT NULL,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"enabled" boolean DEFAULT true NOT NULL,
	"version" text DEFAULT '1' NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone,
	CONSTRAINT "agent_library_entries_virtual_path_relative" CHECK ("agent_library_container_entries"."virtual_path" !~ '(^/|(^|/)..(/|$)|//)'),
	CONSTRAINT "agent_library_entries_kind_check" CHECK ("agent_library_container_entries"."entry_kind" in ('file', 'directory')),
	CONSTRAINT "agent_library_entries_source_check" CHECK ("agent_library_container_entries"."source_kind" in ('soul', 'mission', 'skill_append', 'setting', 'memory', 'system', 'user', 'computer')),
	CONSTRAINT "agent_library_entries_one_content" CHECK (not ("agent_library_container_entries"."content_text" is not null and "agent_library_container_entries"."content_bytes" is not null)),
	CONSTRAINT "agent_library_entries_metadata_object" CHECK (jsonb_typeof("agent_library_container_entries"."metadata") = 'object'),
	CONSTRAINT "agent_library_entries_source_ref_object" CHECK (jsonb_typeof("agent_library_container_entries"."source_ref") = 'object')
);
--> statement-breakpoint
CREATE TABLE "agent_skill_assignments" (
	"agent_uid" text NOT NULL,
	"skill_id" uuid NOT NULL,
	"enabled" boolean NOT NULL,
	"reason" text,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "agent_skill_assignments_agent_uid_skill_id_pk" PRIMARY KEY("agent_uid","skill_id"),
	CONSTRAINT "agent_skill_assignments_metadata_object" CHECK (jsonb_typeof("agent_skill_assignments"."metadata") = 'object')
);
--> statement-breakpoint
CREATE TABLE "library_builtin_sync_state" (
	"sync_key" text PRIMARY KEY NOT NULL,
	"content_hash" text NOT NULL,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"synced_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "library_skill_files" (
	"id" uuid PRIMARY KEY NOT NULL,
	"skill_id" uuid NOT NULL,
	"virtual_path" text NOT NULL,
	"content_text" text NOT NULL,
	"content_blake3" text NOT NULL,
	"content_media_type" text DEFAULT 'text/plain' NOT NULL,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "library_skill_files_virtual_path_relative" CHECK ("library_skill_files"."virtual_path" !~ '(^/|(^|/)..(/|$)|//)'),
	CONSTRAINT "library_skill_files_metadata_object" CHECK (jsonb_typeof("library_skill_files"."metadata") = 'object')
);
--> statement-breakpoint
CREATE TABLE "library_skills" (
	"id" uuid PRIMARY KEY NOT NULL,
	"name" text NOT NULL,
	"description" text NOT NULL,
	"default_enabled" boolean DEFAULT false NOT NULL,
	"enabled" boolean DEFAULT true NOT NULL,
	"source_kind" text DEFAULT 'builtin' NOT NULL,
	"source_hash" text,
	"root_path" text NOT NULL,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"archived_at" timestamp with time zone,
	CONSTRAINT "library_skills_name_format" CHECK ("library_skills"."name" ~ '^[a-z][a-z0-9_-]{0,63}$'),
	CONSTRAINT "library_skills_description_nonempty" CHECK (length(trim("library_skills"."description")) > 0),
	CONSTRAINT "library_skills_root_path_nonempty" CHECK (length(trim("library_skills"."root_path")) > 0),
	CONSTRAINT "library_skills_metadata_object" CHECK (jsonb_typeof("library_skills"."metadata") = 'object')
);
--> statement-breakpoint
CREATE TABLE "llm_providers" (
	"provider_id" text PRIMARY KEY NOT NULL,
	"pi_provider" text NOT NULL,
	"base_url" text,
	"encrypted_api_key" text,
	"provider_options" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "llm_providers_provider_id_format" CHECK ("llm_providers"."provider_id" ~ '^[a-z][a-z0-9_-]{0,62}$'),
	CONSTRAINT "llm_providers_pi_provider_nonempty" CHECK ("llm_providers"."pi_provider" <> ''),
	CONSTRAINT "llm_providers_base_url_nonempty" CHECK ("llm_providers"."base_url" IS NULL OR "llm_providers"."base_url" <> ''),
	CONSTRAINT "llm_providers_encrypted_api_key_nonempty" CHECK ("llm_providers"."encrypted_api_key" IS NULL OR "llm_providers"."encrypted_api_key" <> ''),
	CONSTRAINT "llm_providers_provider_options_object" CHECK (jsonb_typeof("llm_providers"."provider_options") = 'object')
);
--> statement-breakpoint
CREATE TABLE "agents" (
	"uid" text PRIMARY KEY NOT NULL,
	"type" "agent_type" DEFAULT 'llm_agentic_loop' NOT NULL,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"created_by_principal_uid" text,
	"created_at" timestamp DEFAULT CURRENT_TIMESTAMP NOT NULL,
	"updated_at" timestamp DEFAULT CURRENT_TIMESTAMP NOT NULL,
	CONSTRAINT "agents_metadata_object" CHECK (jsonb_typeof("agents"."metadata") = 'object')
);
--> statement-breakpoint
CREATE TABLE "human_users" (
	"principal_uid" text PRIMARY KEY NOT NULL,
	"email" text,
	"phone" text,
	"created_at" timestamp DEFAULT CURRENT_TIMESTAMP NOT NULL,
	"updated_at" timestamp DEFAULT CURRENT_TIMESTAMP NOT NULL
);
--> statement-breakpoint
CREATE TABLE "principal_external_identities" (
	"id" uuid PRIMARY KEY NOT NULL,
	"principal_uid" text NOT NULL,
	"kind" "principal_external_identity_kind" NOT NULL,
	"provider" text,
	"adapter" text,
	"channel_id" text,
	"external_id" text,
	"verified_at" timestamp,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"created_at" timestamp DEFAULT CURRENT_TIMESTAMP NOT NULL,
	"updated_at" timestamp DEFAULT CURRENT_TIMESTAMP NOT NULL,
	CONSTRAINT "principal_external_identities_channel_actor_required" CHECK (("principal_external_identities"."kind" <> 'channel_actor') OR ("principal_external_identities"."adapter" IS NOT NULL AND "principal_external_identities"."channel_id" IS NOT NULL AND "principal_external_identities"."external_id" IS NOT NULL)),
	CONSTRAINT "principal_external_identities_provider_subject_required" CHECK (("principal_external_identities"."kind" = 'channel_actor') OR ("principal_external_identities"."provider" IS NOT NULL AND "principal_external_identities"."external_id" IS NOT NULL AND "principal_external_identities"."adapter" IS NULL AND "principal_external_identities"."channel_id" IS NULL)),
	CONSTRAINT "principal_external_identities_provider_format" CHECK ("principal_external_identities"."provider" IS NULL OR "principal_external_identities"."provider" ~ '^[a-z][a-z0-9_-]*$'),
	CONSTRAINT "principal_external_identities_metadata_object" CHECK (jsonb_typeof("principal_external_identities"."metadata") = 'object')
);
--> statement-breakpoint
CREATE TABLE "principals" (
	"uid" text PRIMARY KEY NOT NULL,
	"type" "principal_type" NOT NULL,
	"status" "principal_status" DEFAULT 'active' NOT NULL,
	"display_name" text,
	"avatar_url" text,
	"created_at" timestamp DEFAULT CURRENT_TIMESTAMP NOT NULL,
	"updated_at" timestamp DEFAULT CURRENT_TIMESTAMP NOT NULL,
	CONSTRAINT "principals_uid_lowercase" CHECK ("principals"."uid" = lower("principals"."uid"))
);
--> statement-breakpoint
CREATE TABLE "computer_agent_worker_bindings" (
	"agent_uid" text PRIMARY KEY NOT NULL,
	"worker_id" text NOT NULL,
	"binding_kind" text NOT NULL,
	"binding_reason" text,
	"instance_id" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_resolved_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "computer_agent_worker_pins" (
	"agent_uid" text PRIMARY KEY NOT NULL,
	"worker_id" text NOT NULL,
	"reason" text,
	"created_by_principal_uid" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "computer_workers" (
	"worker_id" text PRIMARY KEY NOT NULL,
	"instance_id" text NOT NULL,
	"base_url" text NOT NULL,
	"status" text DEFAULT 'starting' NOT NULL,
	"version" text,
	"features" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"capacity" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"load" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"registered_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_heartbeat_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "ai_agent_checkbacks" (
	"id" uuid PRIMARY KEY NOT NULL,
	"agent_uid" text NOT NULL,
	"due_at" timestamp with time zone NOT NULL,
	"timezone" text NOT NULL,
	"status" text DEFAULT 'pending' NOT NULL,
	"reason" text NOT NULL,
	"check" text NOT NULL,
	"context_summary" text,
	"source" jsonb NOT NULL,
	"wake_message" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"conversation_id" uuid,
	"trigger_message_id" uuid,
	"completed_at" timestamp with time zone,
	"claimed_by" text,
	"claimed_at" timestamp with time zone,
	"lease_expires_at" timestamp with time zone,
	"error" text,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "ai_agent_checkbacks_status_check" CHECK ("ai_agent_checkbacks"."status" in ('pending', 'running', 'succeeded', 'failed', 'cancelled')),
	CONSTRAINT "ai_agent_checkbacks_timezone_nonempty" CHECK ("ai_agent_checkbacks"."timezone" <> ''),
	CONSTRAINT "ai_agent_checkbacks_reason_nonempty" CHECK ("ai_agent_checkbacks"."reason" <> ''),
	CONSTRAINT "ai_agent_checkbacks_check_nonempty" CHECK ("ai_agent_checkbacks"."check" <> ''),
	CONSTRAINT "ai_agent_checkbacks_source_object" CHECK (jsonb_typeof("ai_agent_checkbacks"."source") = 'object'),
	CONSTRAINT "ai_agent_checkbacks_wake_message_array" CHECK (jsonb_typeof("ai_agent_checkbacks"."wake_message") = 'array'),
	CONSTRAINT "ai_agent_checkbacks_metadata_object" CHECK (jsonb_typeof("ai_agent_checkbacks"."metadata") = 'object')
);
--> statement-breakpoint
CREATE TABLE "scheduled_task_runs" (
	"id" uuid PRIMARY KEY NOT NULL,
	"task_id" uuid NOT NULL,
	"agent_uid" text NOT NULL,
	"scheduled_for" timestamp with time zone NOT NULL,
	"started_at" timestamp with time zone DEFAULT now() NOT NULL,
	"finished_at" timestamp with time zone,
	"status" text DEFAULT 'running' NOT NULL,
	"trigger" text DEFAULT 'schedule' NOT NULL,
	"conversation_id" uuid,
	"trigger_message_id" uuid,
	"run_by_instance" text,
	"delivered" boolean DEFAULT false NOT NULL,
	"error" text,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "scheduled_task_runs_status_check" CHECK ("scheduled_task_runs"."status" in ('running', 'succeeded', 'failed', 'cancelled')),
	CONSTRAINT "scheduled_task_runs_trigger_check" CHECK ("scheduled_task_runs"."trigger" in ('schedule', 'manual', 'catchup')),
	CONSTRAINT "scheduled_task_runs_metadata_object" CHECK (jsonb_typeof("scheduled_task_runs"."metadata") = 'object')
);
--> statement-breakpoint
CREATE TABLE "scheduled_tasks" (
	"id" uuid PRIMARY KEY NOT NULL,
	"agent_uid" text NOT NULL,
	"name" text NOT NULL,
	"enabled" boolean DEFAULT true NOT NULL,
	"schedule" jsonb NOT NULL,
	"payload" jsonb NOT NULL,
	"delivery" jsonb,
	"next_run_at" timestamp with time zone,
	"last_run_at" timestamp with time zone,
	"previous_run_at" timestamp with time zone,
	"last_status" text,
	"last_run_id" uuid,
	"consecutive_failures" integer DEFAULT 0 NOT NULL,
	"last_alert_at" timestamp with time zone,
	"claimed_by" text,
	"claimed_at" timestamp with time zone,
	"lease_expires_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "scheduled_tasks_name_nonempty" CHECK ("scheduled_tasks"."name" <> ''),
	CONSTRAINT "scheduled_tasks_schedule_object" CHECK (jsonb_typeof("scheduled_tasks"."schedule") = 'object'),
	CONSTRAINT "scheduled_tasks_payload_object" CHECK (jsonb_typeof("scheduled_tasks"."payload") = 'object'),
	CONSTRAINT "scheduled_tasks_schedule_kind" CHECK ("scheduled_tasks"."schedule"->>'kind' in ('every', 'cron')),
	CONSTRAINT "scheduled_tasks_delivery_object" CHECK ("scheduled_tasks"."delivery" is null or jsonb_typeof("scheduled_tasks"."delivery") = 'object'),
	CONSTRAINT "scheduled_tasks_failures_nonnegative" CHECK ("scheduled_tasks"."consecutive_failures" >= 0),
	CONSTRAINT "scheduled_tasks_last_status_check" CHECK ("scheduled_tasks"."last_status" is null or "scheduled_tasks"."last_status" in ('succeeded', 'failed', 'cancelled'))
);
--> statement-breakpoint
CREATE TABLE "runtime_credentials" (
	"id" uuid PRIMARY KEY NOT NULL,
	"consumer_kind" text NOT NULL,
	"consumer_name" text NOT NULL,
	"credential_name" text NOT NULL,
	"scope_kind" text NOT NULL,
	"agent_uid" text,
	"encrypted_payload" text NOT NULL,
	"payload_media_type" text DEFAULT 'text/plain' NOT NULL,
	"payload_blake3" text NOT NULL,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"enabled" boolean DEFAULT true NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "runtime_credentials_consumer_kind_check" CHECK ("runtime_credentials"."consumer_kind" in ('skill', 'tool', 'runtime')),
	CONSTRAINT "runtime_credentials_scope_kind_check" CHECK ("runtime_credentials"."scope_kind" in ('default', 'agent')),
	CONSTRAINT "runtime_credentials_scope_agent_shape" CHECK (("runtime_credentials"."scope_kind" = 'default' AND "runtime_credentials"."agent_uid" IS NULL) OR ("runtime_credentials"."scope_kind" = 'agent' AND "runtime_credentials"."agent_uid" IS NOT NULL)),
	CONSTRAINT "runtime_credentials_consumer_name_format" CHECK ("runtime_credentials"."consumer_name" ~ '^[a-z][a-z0-9_-]{0,63}$'),
	CONSTRAINT "runtime_credentials_name_format" CHECK ("runtime_credentials"."credential_name" ~ '^[a-z][a-z0-9_-]{0,63}$'),
	CONSTRAINT "runtime_credentials_payload_nonempty" CHECK (length("runtime_credentials"."encrypted_payload") > 0),
	CONSTRAINT "runtime_credentials_payload_media_type_nonempty" CHECK (length(trim("runtime_credentials"."payload_media_type")) > 0),
	CONSTRAINT "runtime_credentials_metadata_object" CHECK (jsonb_typeof("runtime_credentials"."metadata") = 'object')
);
--> statement-breakpoint
ALTER TABLE "permission_grants" ADD CONSTRAINT "permission_grants_principal_uid_principals_uid_fk" FOREIGN KEY ("principal_uid") REFERENCES "public"."principals"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "permission_grants" ADD CONSTRAINT "permission_grants_group_id_principal_groups_id_fk" FOREIGN KEY ("group_id") REFERENCES "public"."principal_groups"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "principal_group_external_bindings" ADD CONSTRAINT "principal_group_external_bindings_group_id_principal_groups_id_fk" FOREIGN KEY ("group_id") REFERENCES "public"."principal_groups"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "principal_group_memberships" ADD CONSTRAINT "principal_group_memberships_principal_uid_principals_uid_fk" FOREIGN KEY ("principal_uid") REFERENCES "public"."principals"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "principal_group_memberships" ADD CONSTRAINT "principal_group_memberships_group_id_principal_groups_id_fk" FOREIGN KEY ("group_id") REFERENCES "public"."principal_groups"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ai_agent_conversations" ADD CONSTRAINT "ai_agent_conversations_agent_uid_agents_uid_fk" FOREIGN KEY ("agent_uid") REFERENCES "public"."agents"("uid") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ai_agent_llm_turns" ADD CONSTRAINT "ai_agent_llm_turns_conversation_id_ai_agent_conversations_id_fk" FOREIGN KEY ("conversation_id") REFERENCES "public"."ai_agent_conversations"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ai_agent_messages" ADD CONSTRAINT "ai_agent_messages_conversation_id_ai_agent_conversations_id_fk" FOREIGN KEY ("conversation_id") REFERENCES "public"."ai_agent_conversations"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "external_messages_document_id_index" ON "external_messages" USING btree ("document_id");--> statement-breakpoint
ALTER TABLE "chat_recall_embeddings" ADD CONSTRAINT "chat_recall_embeddings_document_id_external_messages_document_id_fk" FOREIGN KEY ("document_id") REFERENCES "public"."external_messages"("document_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "external_agent_room_observations" ADD CONSTRAINT "external_agent_room_observations_agent_uid_agents_uid_fk" FOREIGN KEY ("agent_uid") REFERENCES "public"."agents"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "external_agent_room_observations" ADD CONSTRAINT "external_agent_room_observations_room_id_external_rooms_id_fk" FOREIGN KEY ("room_id") REFERENCES "public"."external_rooms"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "external_messages" ADD CONSTRAINT "external_messages_room_id_external_rooms_id_fk" FOREIGN KEY ("room_id") REFERENCES "public"."external_rooms"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "external_room_memberships" ADD CONSTRAINT "external_room_memberships_room_id_external_rooms_id_fk" FOREIGN KEY ("room_id") REFERENCES "public"."external_rooms"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "external_room_memberships" ADD CONSTRAINT "external_room_memberships_principal_uid_principals_uid_fk" FOREIGN KEY ("principal_uid") REFERENCES "public"."principals"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "agent_library_container_entries" ADD CONSTRAINT "agent_library_container_entries_agent_uid_agents_uid_fk" FOREIGN KEY ("agent_uid") REFERENCES "public"."agents"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "agent_skill_assignments" ADD CONSTRAINT "agent_skill_assignments_agent_uid_agents_uid_fk" FOREIGN KEY ("agent_uid") REFERENCES "public"."agents"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "agent_skill_assignments" ADD CONSTRAINT "agent_skill_assignments_skill_id_library_skills_id_fk" FOREIGN KEY ("skill_id") REFERENCES "public"."library_skills"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "library_skill_files" ADD CONSTRAINT "library_skill_files_skill_id_library_skills_id_fk" FOREIGN KEY ("skill_id") REFERENCES "public"."library_skills"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "agents" ADD CONSTRAINT "agents_uid_principals_uid_fk" FOREIGN KEY ("uid") REFERENCES "public"."principals"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "agents" ADD CONSTRAINT "agents_created_by_principal_uid_principals_uid_fk" FOREIGN KEY ("created_by_principal_uid") REFERENCES "public"."principals"("uid") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "human_users" ADD CONSTRAINT "human_users_principal_uid_principals_uid_fk" FOREIGN KEY ("principal_uid") REFERENCES "public"."principals"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "principal_external_identities" ADD CONSTRAINT "principal_external_identities_principal_uid_principals_uid_fk" FOREIGN KEY ("principal_uid") REFERENCES "public"."principals"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "computer_agent_worker_bindings" ADD CONSTRAINT "computer_agent_worker_bindings_worker_id_computer_workers_worker_id_fk" FOREIGN KEY ("worker_id") REFERENCES "public"."computer_workers"("worker_id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "computer_agent_worker_pins" ADD CONSTRAINT "computer_agent_worker_pins_worker_id_computer_workers_worker_id_fk" FOREIGN KEY ("worker_id") REFERENCES "public"."computer_workers"("worker_id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ai_agent_checkbacks" ADD CONSTRAINT "ai_agent_checkbacks_agent_uid_agents_uid_fk" FOREIGN KEY ("agent_uid") REFERENCES "public"."agents"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ai_agent_checkbacks" ADD CONSTRAINT "ai_agent_checkbacks_conversation_id_ai_agent_conversations_id_fk" FOREIGN KEY ("conversation_id") REFERENCES "public"."ai_agent_conversations"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ai_agent_checkbacks" ADD CONSTRAINT "ai_agent_checkbacks_trigger_message_id_ai_agent_messages_id_fk" FOREIGN KEY ("trigger_message_id") REFERENCES "public"."ai_agent_messages"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "scheduled_task_runs" ADD CONSTRAINT "scheduled_task_runs_task_id_scheduled_tasks_id_fk" FOREIGN KEY ("task_id") REFERENCES "public"."scheduled_tasks"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "scheduled_task_runs" ADD CONSTRAINT "scheduled_task_runs_conversation_id_ai_agent_conversations_id_fk" FOREIGN KEY ("conversation_id") REFERENCES "public"."ai_agent_conversations"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "scheduled_task_runs" ADD CONSTRAINT "scheduled_task_runs_trigger_message_id_ai_agent_messages_id_fk" FOREIGN KEY ("trigger_message_id") REFERENCES "public"."ai_agent_messages"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "scheduled_tasks" ADD CONSTRAINT "scheduled_tasks_agent_uid_agents_uid_fk" FOREIGN KEY ("agent_uid") REFERENCES "public"."agents"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "runtime_credentials" ADD CONSTRAINT "runtime_credentials_agent_uid_agents_uid_fk" FOREIGN KEY ("agent_uid") REFERENCES "public"."agents"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "permission_grants_principal_uid_index" ON "permission_grants" USING btree ("principal_uid");--> statement-breakpoint
CREATE INDEX "permission_grants_group_id_index" ON "permission_grants" USING btree ("group_id");--> statement-breakpoint
CREATE INDEX "permission_grants_action_index" ON "permission_grants" USING btree ("action");--> statement-breakpoint
CREATE UNIQUE INDEX "permission_grants_principal_upsert_index" ON "permission_grants" USING btree ("principal_uid","resource_pattern","action","condition") WHERE "permission_grants"."principal_uid" IS NOT NULL;--> statement-breakpoint
CREATE UNIQUE INDEX "permission_grants_group_upsert_index" ON "permission_grants" USING btree ("group_id","resource_pattern","action","condition") WHERE "permission_grants"."group_id" IS NOT NULL;--> statement-breakpoint
CREATE INDEX "principal_group_external_bindings_group_id_index" ON "principal_group_external_bindings" USING btree ("group_id");--> statement-breakpoint
CREATE INDEX "principal_group_memberships_group_id_index" ON "principal_group_memberships" USING btree ("group_id");--> statement-breakpoint
CREATE UNIQUE INDEX "principal_groups_name_index" ON "principal_groups" USING btree ("name");--> statement-breakpoint
CREATE UNIQUE INDEX "ai_agent_conversations_active_key_index" ON "ai_agent_conversations" USING btree ("agent_uid","conversation_key") WHERE "ai_agent_conversations"."ended_at" IS NULL;--> statement-breakpoint
CREATE INDEX "ai_agent_conversations_stale_generation_index" ON "ai_agent_conversations" USING btree ("ended_at","updated_at");--> statement-breakpoint
CREATE INDEX "ai_agent_llm_turns_conversation_index" ON "ai_agent_llm_turns" USING btree ("conversation_id","started_at","id");--> statement-breakpoint
CREATE INDEX "ai_agent_llm_turns_trigger_index" ON "ai_agent_llm_turns" USING btree ("trigger_message_id");--> statement-breakpoint
CREATE UNIQUE INDEX "ai_agent_llm_turns_lease_call_index" ON "ai_agent_llm_turns" USING btree ("conversation_id","lease_id","call_index") WHERE "ai_agent_llm_turns"."lease_id" IS NOT NULL AND "ai_agent_llm_turns"."call_index" IS NOT NULL;--> statement-breakpoint
CREATE INDEX "ai_agent_llm_turns_branch_index" ON "ai_agent_llm_turns" USING btree ("conversation_id","branch_id");--> statement-breakpoint
CREATE INDEX "ai_agent_messages_conversation_order_index" ON "ai_agent_messages" USING btree ("conversation_id","created_at","id");--> statement-breakpoint
CREATE UNIQUE INDEX "ai_agent_messages_inbound_event_index" ON "ai_agent_messages" USING btree ("conversation_id","event_source","event_id") WHERE "ai_agent_messages"."role" in ('user', 'im_ambient') and "ai_agent_messages"."kind" = 'normal' and "ai_agent_messages"."event_source" is not null and "ai_agent_messages"."event_id" is not null;--> statement-breakpoint
CREATE INDEX "ai_agent_messages_summary_index" ON "ai_agent_messages" USING btree ("conversation_id","created_at","id") WHERE "ai_agent_messages"."kind" = 'summary' and "ai_agent_messages"."status" = 'complete';--> statement-breakpoint
CREATE INDEX "ai_agent_messages_assistant_index" ON "ai_agent_messages" USING btree ("conversation_id","created_at","id") WHERE "ai_agent_messages"."role" = 'assistant';--> statement-breakpoint
CREATE INDEX "ai_agent_messages_provider_message_ids_index" ON "ai_agent_messages" USING gin (("metadata"->'provider_refs'->'message_ids')) WHERE "ai_agent_messages"."role" in ('user', 'im_ambient') and "ai_agent_messages"."kind" = 'normal';--> statement-breakpoint
CREATE INDEX "chat_recall_embeddings_ready_idx" ON "chat_recall_embeddings" USING btree ("status","next_retry_at","updated_at");--> statement-breakpoint
CREATE INDEX "chat_recall_embeddings_profile_status_idx" ON "chat_recall_embeddings" USING btree ("profile_id","status","dimensions");--> statement-breakpoint
CREATE INDEX "external_agent_room_observations_room_id_index" ON "external_agent_room_observations" USING btree ("room_id");--> statement-breakpoint
CREATE INDEX "external_gateway_agent_events_ready_index" ON "external_gateway_agent_events" USING btree ("status","available_at");--> statement-breakpoint
CREATE INDEX "external_gateway_agent_events_batch_index" ON "external_gateway_agent_events" USING btree ("agent_uid","batch_key","status","created_at");--> statement-breakpoint
CREATE INDEX "external_gateway_input_tombstones_expires_at_index" ON "external_gateway_input_tombstones" USING btree ("expires_at");--> statement-breakpoint
CREATE INDEX "external_gateway_outbox_status_index" ON "external_gateway_outbox" USING btree ("status","created_at");--> statement-breakpoint
CREATE INDEX "external_gateway_outbox_binding_pending_index" ON "external_gateway_outbox" USING btree ("agent_uid","binding_name","status","created_at");--> statement-breakpoint
CREATE INDEX "external_messages_room_id_sent_at_index" ON "external_messages" USING btree ("room_id","sent_at");--> statement-breakpoint
CREATE INDEX "external_room_memberships_principal_uid_index" ON "external_room_memberships" USING btree ("principal_uid");--> statement-breakpoint
CREATE UNIQUE INDEX "agent_library_entries_active_path_index" ON "agent_library_container_entries" USING btree ("agent_uid","virtual_path") WHERE "agent_library_container_entries"."deleted_at" IS NULL;--> statement-breakpoint
CREATE INDEX "agent_library_entries_agent_index" ON "agent_library_container_entries" USING btree ("agent_uid","enabled","virtual_path");--> statement-breakpoint
CREATE INDEX "agent_skill_assignments_agent_index" ON "agent_skill_assignments" USING btree ("agent_uid");--> statement-breakpoint
CREATE UNIQUE INDEX "library_skill_files_skill_path_index" ON "library_skill_files" USING btree ("skill_id","virtual_path");--> statement-breakpoint
CREATE INDEX "library_skill_files_skill_index" ON "library_skill_files" USING btree ("skill_id");--> statement-breakpoint
CREATE UNIQUE INDEX "library_skills_name_index" ON "library_skills" USING btree ("name");--> statement-breakpoint
CREATE INDEX "library_skills_enabled_index" ON "library_skills" USING btree ("enabled","default_enabled");--> statement-breakpoint
CREATE INDEX "llm_providers_pi_provider_index" ON "llm_providers" USING btree ("pi_provider");--> statement-breakpoint
CREATE INDEX "agents_created_by_principal_uid_index" ON "agents" USING btree ("created_by_principal_uid");--> statement-breakpoint
CREATE UNIQUE INDEX "human_users_email_index" ON "human_users" USING btree ("email") WHERE "human_users"."email" IS NOT NULL;--> statement-breakpoint
CREATE UNIQUE INDEX "human_users_phone_index" ON "human_users" USING btree ("phone") WHERE "human_users"."phone" IS NOT NULL;--> statement-breakpoint
CREATE INDEX "principal_external_identities_principal_uid_index" ON "principal_external_identities" USING btree ("principal_uid");--> statement-breakpoint
CREATE UNIQUE INDEX "principal_external_identities_channel_actor_index" ON "principal_external_identities" USING btree ("adapter","channel_id","external_id") WHERE "principal_external_identities"."kind" = 'channel_actor';--> statement-breakpoint
CREATE UNIQUE INDEX "principal_external_identities_provider_identity_index" ON "principal_external_identities" USING btree ("kind","provider","external_id") WHERE "principal_external_identities"."provider" IS NOT NULL AND "principal_external_identities"."external_id" IS NOT NULL AND "principal_external_identities"."adapter" IS NULL AND "principal_external_identities"."channel_id" IS NULL;--> statement-breakpoint
CREATE UNIQUE INDEX "principal_external_identities_login_subject_index" ON "principal_external_identities" USING btree ("provider","external_id") WHERE "principal_external_identities"."kind" = 'login_subject';--> statement-breakpoint
CREATE UNIQUE INDEX "principal_external_identities_outbound_actor_index" ON "principal_external_identities" USING btree ("provider","external_id") WHERE "principal_external_identities"."kind" = 'outbound_actor';--> statement-breakpoint
CREATE INDEX "computer_agent_worker_bindings_worker_index" ON "computer_agent_worker_bindings" USING btree ("worker_id");--> statement-breakpoint
CREATE INDEX "computer_agent_worker_pins_worker_index" ON "computer_agent_worker_pins" USING btree ("worker_id");--> statement-breakpoint
CREATE INDEX "ai_agent_checkbacks_due_index" ON "ai_agent_checkbacks" USING btree ("status","due_at");--> statement-breakpoint
CREATE INDEX "ai_agent_checkbacks_agent_index" ON "ai_agent_checkbacks" USING btree ("agent_uid","created_at");--> statement-breakpoint
CREATE INDEX "ai_agent_checkbacks_conversation_index" ON "ai_agent_checkbacks" USING btree ("conversation_id");--> statement-breakpoint
CREATE INDEX "ai_agent_checkbacks_trigger_message_index" ON "ai_agent_checkbacks" USING btree ("trigger_message_id");--> statement-breakpoint
CREATE INDEX "ai_agent_checkbacks_lease_index" ON "ai_agent_checkbacks" USING btree ("lease_expires_at");--> statement-breakpoint
CREATE INDEX "scheduled_task_runs_task_index" ON "scheduled_task_runs" USING btree ("task_id","started_at");--> statement-breakpoint
CREATE INDEX "scheduled_task_runs_conversation_index" ON "scheduled_task_runs" USING btree ("conversation_id");--> statement-breakpoint
CREATE INDEX "scheduled_task_runs_trigger_message_index" ON "scheduled_task_runs" USING btree ("trigger_message_id");--> statement-breakpoint
CREATE UNIQUE INDEX "scheduled_tasks_agent_name_index" ON "scheduled_tasks" USING btree ("agent_uid","name");--> statement-breakpoint
CREATE INDEX "scheduled_tasks_due_index" ON "scheduled_tasks" USING btree ("enabled","next_run_at");--> statement-breakpoint
CREATE INDEX "scheduled_tasks_lease_index" ON "scheduled_tasks" USING btree ("lease_expires_at");--> statement-breakpoint
CREATE UNIQUE INDEX "runtime_credentials_default_index" ON "runtime_credentials" USING btree ("consumer_kind","consumer_name","credential_name") WHERE "runtime_credentials"."scope_kind" = 'default';--> statement-breakpoint
CREATE UNIQUE INDEX "runtime_credentials_agent_index" ON "runtime_credentials" USING btree ("consumer_kind","consumer_name","credential_name","agent_uid") WHERE "runtime_credentials"."scope_kind" = 'agent';--> statement-breakpoint
CREATE INDEX "runtime_credentials_lookup_index" ON "runtime_credentials" USING btree ("consumer_kind","consumer_name","credential_name","scope_kind","enabled");