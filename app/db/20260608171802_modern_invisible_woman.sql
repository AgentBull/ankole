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
ALTER TABLE "computer_agent_worker_bindings" ADD CONSTRAINT "computer_agent_worker_bindings_worker_id_computer_workers_worker_id_fk" FOREIGN KEY ("worker_id") REFERENCES "public"."computer_workers"("worker_id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "computer_agent_worker_pins" ADD CONSTRAINT "computer_agent_worker_pins_worker_id_computer_workers_worker_id_fk" FOREIGN KEY ("worker_id") REFERENCES "public"."computer_workers"("worker_id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "computer_agent_worker_bindings_worker_index" ON "computer_agent_worker_bindings" USING btree ("worker_id");