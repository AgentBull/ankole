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
	"content_sha256" text NOT NULL,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"enabled" boolean DEFAULT true NOT NULL,
	"version" text DEFAULT '1' NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone,
	CONSTRAINT "agent_library_entries_virtual_path_relative" CHECK ("agent_library_container_entries"."virtual_path" !~ '(^/|(^|/)..(/|$)|//)'),
	CONSTRAINT "agent_library_entries_kind_check" CHECK ("agent_library_container_entries"."entry_kind" in ('file', 'directory')),
	CONSTRAINT "agent_library_entries_source_check" CHECK ("agent_library_container_entries"."source_kind" in ('soul', 'skill_append', 'setting', 'memory', 'system', 'user', 'computer')),
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
	"content_sha256" text NOT NULL,
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
ALTER TABLE "agent_library_container_entries" ADD CONSTRAINT "agent_library_container_entries_agent_uid_agents_uid_fk" FOREIGN KEY ("agent_uid") REFERENCES "public"."agents"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "agent_skill_assignments" ADD CONSTRAINT "agent_skill_assignments_agent_uid_agents_uid_fk" FOREIGN KEY ("agent_uid") REFERENCES "public"."agents"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "agent_skill_assignments" ADD CONSTRAINT "agent_skill_assignments_skill_id_library_skills_id_fk" FOREIGN KEY ("skill_id") REFERENCES "public"."library_skills"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "library_skill_files" ADD CONSTRAINT "library_skill_files_skill_id_library_skills_id_fk" FOREIGN KEY ("skill_id") REFERENCES "public"."library_skills"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "agent_library_entries_active_path_index" ON "agent_library_container_entries" USING btree ("agent_uid","virtual_path") WHERE "agent_library_container_entries"."deleted_at" IS NULL;--> statement-breakpoint
CREATE INDEX "agent_library_entries_agent_index" ON "agent_library_container_entries" USING btree ("agent_uid","enabled","virtual_path");--> statement-breakpoint
CREATE INDEX "agent_skill_assignments_agent_index" ON "agent_skill_assignments" USING btree ("agent_uid");--> statement-breakpoint
CREATE UNIQUE INDEX "library_skill_files_skill_path_index" ON "library_skill_files" USING btree ("skill_id","virtual_path");--> statement-breakpoint
CREATE INDEX "library_skill_files_skill_index" ON "library_skill_files" USING btree ("skill_id");--> statement-breakpoint
CREATE UNIQUE INDEX "library_skills_name_index" ON "library_skills" USING btree ("name");--> statement-breakpoint
CREATE INDEX "library_skills_enabled_index" ON "library_skills" USING btree ("enabled","default_enabled");