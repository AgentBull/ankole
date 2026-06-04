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
	CONSTRAINT "key_unique" UNIQUE("key")
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
CREATE TABLE "chat_channels" (
	"id" text PRIMARY KEY NOT NULL,
	"is_dm" boolean DEFAULT false NOT NULL,
	"channel_visibility" text DEFAULT 'unknown' NOT NULL,
	"name" text,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"raw" jsonb,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "chat_channels_id_nonempty" CHECK ("chat_channels"."id" <> ''),
	CONSTRAINT "chat_channels_metadata_object" CHECK (jsonb_typeof("chat_channels"."metadata") = 'object')
);
--> statement-breakpoint
CREATE TABLE "chat_messages" (
	"id" uuid PRIMARY KEY NOT NULL,
	"channel_id" text NOT NULL,
	"thread_id" text NOT NULL,
	"message_id" text NOT NULL,
	"author_id" text,
	"user_key" text,
	"author" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"is_mention" boolean DEFAULT false NOT NULL,
	"text" text,
	"formatted" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"attachments" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"links" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"reactions" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"raw" jsonb,
	"sent_at" timestamp with time zone,
	"edited_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "chat_messages_thread_id_nonempty" CHECK ("chat_messages"."thread_id" <> ''),
	CONSTRAINT "chat_messages_message_id_nonempty" CHECK ("chat_messages"."message_id" <> ''),
	CONSTRAINT "chat_messages_author_object" CHECK (jsonb_typeof("chat_messages"."author") = 'object'),
	CONSTRAINT "chat_messages_formatted_object" CHECK (jsonb_typeof("chat_messages"."formatted") = 'object'),
	CONSTRAINT "chat_messages_attachments_array" CHECK (jsonb_typeof("chat_messages"."attachments") = 'array'),
	CONSTRAINT "chat_messages_links_array" CHECK (jsonb_typeof("chat_messages"."links") = 'array'),
	CONSTRAINT "chat_messages_metadata_object" CHECK (jsonb_typeof("chat_messages"."metadata") = 'object'),
	CONSTRAINT "chat_messages_reactions_object" CHECK (jsonb_typeof("chat_messages"."reactions") = 'object')
);
--> statement-breakpoint
CREATE TABLE "chat_state_cache" (
	"key_prefix" text NOT NULL,
	"cache_key" text NOT NULL,
	"value" text NOT NULL,
	"expires_at" timestamp with time zone,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "chat_state_cache_key_prefix_cache_key_pk" PRIMARY KEY("key_prefix","cache_key")
);
--> statement-breakpoint
CREATE TABLE "chat_state_lists" (
	"key_prefix" text NOT NULL,
	"list_key" text NOT NULL,
	"seq" bigserial NOT NULL,
	"value" text NOT NULL,
	"expires_at" timestamp with time zone,
	CONSTRAINT "chat_state_lists_key_prefix_list_key_seq_pk" PRIMARY KEY("key_prefix","list_key","seq")
);
--> statement-breakpoint
CREATE TABLE "chat_state_locks" (
	"key_prefix" text NOT NULL,
	"thread_id" text NOT NULL,
	"token" text NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "chat_state_locks_key_prefix_thread_id_pk" PRIMARY KEY("key_prefix","thread_id")
);
--> statement-breakpoint
CREATE TABLE "chat_state_queues" (
	"key_prefix" text NOT NULL,
	"thread_id" text NOT NULL,
	"seq" bigserial NOT NULL,
	"value" text NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	CONSTRAINT "chat_state_queues_key_prefix_thread_id_seq_pk" PRIMARY KEY("key_prefix","thread_id","seq")
);
--> statement-breakpoint
CREATE TABLE "chat_state_subscriptions" (
	"key_prefix" text NOT NULL,
	"thread_id" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "chat_state_subscriptions_key_prefix_thread_id_pk" PRIMARY KEY("key_prefix","thread_id")
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
	"id" uuid PRIMARY KEY NOT NULL,
	"uid" text NOT NULL,
	"type" "principal_type" NOT NULL,
	"status" "principal_status" DEFAULT 'active' NOT NULL,
	"display_name" text,
	"avatar_url" text,
	"created_at" timestamp DEFAULT CURRENT_TIMESTAMP NOT NULL,
	"updated_at" timestamp DEFAULT CURRENT_TIMESTAMP NOT NULL,
	CONSTRAINT "principals_uid_unique" UNIQUE("uid"),
	CONSTRAINT "principals_uid_lowercase" CHECK ("principals"."uid" = lower("principals"."uid"))
);
--> statement-breakpoint
ALTER TABLE "permission_grants" ADD CONSTRAINT "permission_grants_principal_uid_principals_uid_fk" FOREIGN KEY ("principal_uid") REFERENCES "public"."principals"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "permission_grants" ADD CONSTRAINT "permission_grants_group_id_principal_groups_id_fk" FOREIGN KEY ("group_id") REFERENCES "public"."principal_groups"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "principal_group_external_bindings" ADD CONSTRAINT "principal_group_external_bindings_group_id_principal_groups_id_fk" FOREIGN KEY ("group_id") REFERENCES "public"."principal_groups"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "principal_group_memberships" ADD CONSTRAINT "principal_group_memberships_principal_uid_principals_uid_fk" FOREIGN KEY ("principal_uid") REFERENCES "public"."principals"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "principal_group_memberships" ADD CONSTRAINT "principal_group_memberships_group_id_principal_groups_id_fk" FOREIGN KEY ("group_id") REFERENCES "public"."principal_groups"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "chat_messages" ADD CONSTRAINT "chat_messages_channel_id_chat_channels_id_fk" FOREIGN KEY ("channel_id") REFERENCES "public"."chat_channels"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "agents" ADD CONSTRAINT "agents_uid_principals_uid_fk" FOREIGN KEY ("uid") REFERENCES "public"."principals"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "agents" ADD CONSTRAINT "agents_created_by_principal_uid_principals_uid_fk" FOREIGN KEY ("created_by_principal_uid") REFERENCES "public"."principals"("uid") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "human_users" ADD CONSTRAINT "human_users_principal_uid_principals_uid_fk" FOREIGN KEY ("principal_uid") REFERENCES "public"."principals"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "principal_external_identities" ADD CONSTRAINT "principal_external_identities_principal_uid_principals_uid_fk" FOREIGN KEY ("principal_uid") REFERENCES "public"."principals"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "permission_grants_principal_uid_index" ON "permission_grants" USING btree ("principal_uid");--> statement-breakpoint
CREATE INDEX "permission_grants_group_id_index" ON "permission_grants" USING btree ("group_id");--> statement-breakpoint
CREATE INDEX "permission_grants_action_index" ON "permission_grants" USING btree ("action");--> statement-breakpoint
CREATE UNIQUE INDEX "permission_grants_principal_upsert_index" ON "permission_grants" USING btree ("principal_uid","resource_pattern","action","condition") WHERE "permission_grants"."principal_uid" IS NOT NULL;--> statement-breakpoint
CREATE UNIQUE INDEX "permission_grants_group_upsert_index" ON "permission_grants" USING btree ("group_id","resource_pattern","action","condition") WHERE "permission_grants"."group_id" IS NOT NULL;--> statement-breakpoint
CREATE INDEX "principal_group_external_bindings_group_id_index" ON "principal_group_external_bindings" USING btree ("group_id");--> statement-breakpoint
CREATE INDEX "principal_group_memberships_group_id_index" ON "principal_group_memberships" USING btree ("group_id");--> statement-breakpoint
CREATE UNIQUE INDEX "principal_groups_name_index" ON "principal_groups" USING btree ("name");--> statement-breakpoint
CREATE UNIQUE INDEX "chat_messages_channel_id_message_id_index" ON "chat_messages" USING btree ("channel_id","message_id");--> statement-breakpoint
CREATE INDEX "chat_messages_channel_id_thread_id_sent_at_index" ON "chat_messages" USING btree ("channel_id","thread_id","sent_at");--> statement-breakpoint
CREATE INDEX "chat_state_cache_expires_idx" ON "chat_state_cache" USING btree ("expires_at");--> statement-breakpoint
CREATE INDEX "chat_state_lists_expires_idx" ON "chat_state_lists" USING btree ("expires_at");--> statement-breakpoint
CREATE INDEX "chat_state_locks_expires_idx" ON "chat_state_locks" USING btree ("expires_at");--> statement-breakpoint
CREATE INDEX "chat_state_queues_expires_idx" ON "chat_state_queues" USING btree ("expires_at");--> statement-breakpoint
CREATE INDEX "agents_created_by_principal_uid_index" ON "agents" USING btree ("created_by_principal_uid");--> statement-breakpoint
CREATE UNIQUE INDEX "human_users_email_index" ON "human_users" USING btree ("email") WHERE "human_users"."email" IS NOT NULL;--> statement-breakpoint
CREATE UNIQUE INDEX "human_users_phone_index" ON "human_users" USING btree ("phone") WHERE "human_users"."phone" IS NOT NULL;--> statement-breakpoint
CREATE INDEX "principal_external_identities_principal_uid_index" ON "principal_external_identities" USING btree ("principal_uid");--> statement-breakpoint
CREATE UNIQUE INDEX "principal_external_identities_channel_actor_index" ON "principal_external_identities" USING btree ("adapter","channel_id","external_id") WHERE "principal_external_identities"."kind" = 'channel_actor';--> statement-breakpoint
CREATE UNIQUE INDEX "principal_external_identities_provider_identity_index" ON "principal_external_identities" USING btree ("kind","provider","external_id") WHERE "principal_external_identities"."provider" IS NOT NULL AND "principal_external_identities"."external_id" IS NOT NULL AND "principal_external_identities"."adapter" IS NULL AND "principal_external_identities"."channel_id" IS NULL;--> statement-breakpoint
CREATE UNIQUE INDEX "principal_external_identities_login_subject_index" ON "principal_external_identities" USING btree ("provider","external_id") WHERE "principal_external_identities"."kind" = 'login_subject';--> statement-breakpoint
CREATE UNIQUE INDEX "principal_external_identities_outbound_actor_index" ON "principal_external_identities" USING btree ("provider","external_id") WHERE "principal_external_identities"."kind" = 'outbound_actor';