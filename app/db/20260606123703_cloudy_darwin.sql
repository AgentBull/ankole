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
	"trigger_message_id" uuid,
	"trigger_event_id" text,
	"input_message_ids" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"input_summary_message_id" uuid,
	"request_context" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"response" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"usage" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"provider_metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"started_at" timestamp with time zone DEFAULT now() NOT NULL,
	"completed_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "ai_agent_llm_turns_kind_check" CHECK ("ai_agent_llm_turns"."kind" in ('generation', 'retry_generation', 'compression', 'ambient_recognizer', 'overflow_retry')),
	CONSTRAINT "ai_agent_llm_turns_status_check" CHECK ("ai_agent_llm_turns"."status" in ('started', 'succeeded', 'failed', 'cancelled')),
	CONSTRAINT "ai_agent_llm_turns_profile_check" CHECK ("ai_agent_llm_turns"."profile" in ('primary', 'light', 'heavy')),
	CONSTRAINT "ai_agent_llm_turns_input_message_ids_array" CHECK (jsonb_typeof("ai_agent_llm_turns"."input_message_ids") = 'array'),
	CONSTRAINT "ai_agent_llm_turns_request_context_object" CHECK (jsonb_typeof("ai_agent_llm_turns"."request_context") = 'object'),
	CONSTRAINT "ai_agent_llm_turns_response_object" CHECK (jsonb_typeof("ai_agent_llm_turns"."response") = 'object'),
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
ALTER TABLE "external_gateway_outbox" DROP CONSTRAINT "external_gateway_outbox_operation_check";--> statement-breakpoint
ALTER TABLE "external_gateway_outbox" ADD COLUMN "idempotency_key" text;--> statement-breakpoint
ALTER TABLE "external_gateway_outbox" ADD COLUMN "retry_count" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "external_gateway_outbox" ADD COLUMN "last_attempt_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "external_gateway_outbox" ADD COLUMN "last_error" text;--> statement-breakpoint
ALTER TABLE "external_gateway_outbox" ADD COLUMN "platform_send_started_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "external_gateway_outbox" ADD COLUMN "recovery_state" text DEFAULT 'not_started' NOT NULL;--> statement-breakpoint
ALTER TABLE "ai_agent_conversations" ADD CONSTRAINT "ai_agent_conversations_agent_uid_agents_uid_fk" FOREIGN KEY ("agent_uid") REFERENCES "public"."agents"("uid") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ai_agent_llm_turns" ADD CONSTRAINT "ai_agent_llm_turns_conversation_id_ai_agent_conversations_id_fk" FOREIGN KEY ("conversation_id") REFERENCES "public"."ai_agent_conversations"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ai_agent_messages" ADD CONSTRAINT "ai_agent_messages_conversation_id_ai_agent_conversations_id_fk" FOREIGN KEY ("conversation_id") REFERENCES "public"."ai_agent_conversations"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "ai_agent_conversations_active_key_index" ON "ai_agent_conversations" USING btree ("agent_uid","conversation_key") WHERE "ai_agent_conversations"."ended_at" IS NULL;--> statement-breakpoint
CREATE INDEX "ai_agent_conversations_stale_generation_index" ON "ai_agent_conversations" USING btree ("ended_at","updated_at");--> statement-breakpoint
CREATE INDEX "ai_agent_llm_turns_conversation_index" ON "ai_agent_llm_turns" USING btree ("conversation_id","started_at","id");--> statement-breakpoint
CREATE INDEX "ai_agent_llm_turns_trigger_index" ON "ai_agent_llm_turns" USING btree ("trigger_message_id");--> statement-breakpoint
CREATE INDEX "ai_agent_messages_conversation_order_index" ON "ai_agent_messages" USING btree ("conversation_id","created_at","id");--> statement-breakpoint
CREATE UNIQUE INDEX "ai_agent_messages_inbound_event_index" ON "ai_agent_messages" USING btree ("conversation_id","event_source","event_id") WHERE "ai_agent_messages"."role" in ('user', 'im_ambient') and "ai_agent_messages"."kind" = 'normal' and "ai_agent_messages"."event_source" is not null and "ai_agent_messages"."event_id" is not null;--> statement-breakpoint
CREATE INDEX "ai_agent_messages_summary_index" ON "ai_agent_messages" USING btree ("conversation_id","created_at","id") WHERE "ai_agent_messages"."kind" = 'summary' and "ai_agent_messages"."status" = 'complete';--> statement-breakpoint
CREATE INDEX "ai_agent_messages_assistant_index" ON "ai_agent_messages" USING btree ("conversation_id","created_at","id") WHERE "ai_agent_messages"."role" = 'assistant';--> statement-breakpoint
CREATE INDEX "ai_agent_messages_provider_message_ids_index" ON "ai_agent_messages" USING gin (("metadata"->'provider_refs'->'message_ids')) WHERE "ai_agent_messages"."role" in ('user', 'im_ambient') and "ai_agent_messages"."kind" = 'normal';--> statement-breakpoint
CREATE INDEX "external_gateway_outbox_binding_pending_index" ON "external_gateway_outbox" USING btree ("agent_uid","binding_name","status","created_at");--> statement-breakpoint
ALTER TABLE "external_gateway_outbox" ADD CONSTRAINT "external_gateway_outbox_recovery_state_check" CHECK ("external_gateway_outbox"."recovery_state" in ('not_started', 'send_attempt_started', 'unknown_after_send'));--> statement-breakpoint
ALTER TABLE "external_gateway_outbox" ADD CONSTRAINT "external_gateway_outbox_operation_check" CHECK ("external_gateway_outbox"."operation" in ('post', 'reply', 'edit', 'delete', 'reaction_add', 'reaction_remove', 'modal', 'card', 'divider'));
