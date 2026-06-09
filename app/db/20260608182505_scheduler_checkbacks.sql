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
ALTER TABLE "ai_agent_llm_turns" DROP CONSTRAINT "ai_agent_llm_turns_kind_check";--> statement-breakpoint
ALTER TABLE "ai_agent_checkbacks" ADD CONSTRAINT "ai_agent_checkbacks_agent_uid_agents_uid_fk" FOREIGN KEY ("agent_uid") REFERENCES "public"."agents"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ai_agent_checkbacks" ADD CONSTRAINT "ai_agent_checkbacks_conversation_id_ai_agent_conversations_id_fk" FOREIGN KEY ("conversation_id") REFERENCES "public"."ai_agent_conversations"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ai_agent_checkbacks" ADD CONSTRAINT "ai_agent_checkbacks_trigger_message_id_ai_agent_messages_id_fk" FOREIGN KEY ("trigger_message_id") REFERENCES "public"."ai_agent_messages"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "scheduled_task_runs" ADD CONSTRAINT "scheduled_task_runs_task_id_scheduled_tasks_id_fk" FOREIGN KEY ("task_id") REFERENCES "public"."scheduled_tasks"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "scheduled_task_runs" ADD CONSTRAINT "scheduled_task_runs_conversation_id_ai_agent_conversations_id_fk" FOREIGN KEY ("conversation_id") REFERENCES "public"."ai_agent_conversations"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "scheduled_task_runs" ADD CONSTRAINT "scheduled_task_runs_trigger_message_id_ai_agent_messages_id_fk" FOREIGN KEY ("trigger_message_id") REFERENCES "public"."ai_agent_messages"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "scheduled_tasks" ADD CONSTRAINT "scheduled_tasks_agent_uid_agents_uid_fk" FOREIGN KEY ("agent_uid") REFERENCES "public"."agents"("uid") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "ai_agent_checkbacks_due_index" ON "ai_agent_checkbacks" USING btree ("status","due_at");--> statement-breakpoint
CREATE INDEX "ai_agent_checkbacks_agent_index" ON "ai_agent_checkbacks" USING btree ("agent_uid","created_at");--> statement-breakpoint
CREATE INDEX "ai_agent_checkbacks_lease_index" ON "ai_agent_checkbacks" USING btree ("lease_expires_at");--> statement-breakpoint
CREATE INDEX "scheduled_task_runs_task_index" ON "scheduled_task_runs" USING btree ("task_id","started_at");--> statement-breakpoint
CREATE UNIQUE INDEX "scheduled_tasks_agent_name_index" ON "scheduled_tasks" USING btree ("agent_uid","name");--> statement-breakpoint
CREATE INDEX "scheduled_tasks_due_index" ON "scheduled_tasks" USING btree ("enabled","next_run_at");--> statement-breakpoint
CREATE INDEX "scheduled_tasks_lease_index" ON "scheduled_tasks" USING btree ("lease_expires_at");--> statement-breakpoint
ALTER TABLE "ai_agent_llm_turns" ADD CONSTRAINT "ai_agent_llm_turns_kind_check" CHECK ("ai_agent_llm_turns"."kind" in ('generation', 'retry_generation', 'scheduled_task', 'checkback_generation', 'compression', 'ambient_recognizer', 'overflow_retry'));