ALTER TABLE "ai_agent_llm_turns" ADD COLUMN "lease_id" text;
--> statement-breakpoint
ALTER TABLE "ai_agent_llm_turns" ADD COLUMN "call_index" integer;
--> statement-breakpoint
ALTER TABLE "ai_agent_llm_turns" ADD COLUMN "branch_id" text;
--> statement-breakpoint
ALTER TABLE "ai_agent_llm_turns" ADD COLUMN "parent_branch_id" text;
--> statement-breakpoint
ALTER TABLE "ai_agent_llm_turns" ADD COLUMN "request_refs" jsonb DEFAULT '[]'::jsonb NOT NULL;
--> statement-breakpoint
ALTER TABLE "ai_agent_llm_turns" ADD COLUMN "request_patches" jsonb DEFAULT '[]'::jsonb NOT NULL;
--> statement-breakpoint
ALTER TABLE "ai_agent_llm_turns" ADD COLUMN "tool_results" jsonb DEFAULT '[]'::jsonb NOT NULL;
--> statement-breakpoint
CREATE UNIQUE INDEX "ai_agent_llm_turns_lease_call_index" ON "ai_agent_llm_turns" USING btree ("conversation_id","lease_id","call_index") WHERE "lease_id" IS NOT NULL AND "call_index" IS NOT NULL;
--> statement-breakpoint
CREATE INDEX "ai_agent_llm_turns_branch_index" ON "ai_agent_llm_turns" USING btree ("conversation_id","branch_id");
--> statement-breakpoint
ALTER TABLE "ai_agent_llm_turns" ADD CONSTRAINT "ai_agent_llm_turns_call_index_nonnegative" CHECK ("ai_agent_llm_turns"."call_index" IS NULL OR "ai_agent_llm_turns"."call_index" >= 0);
--> statement-breakpoint
ALTER TABLE "ai_agent_llm_turns" ADD CONSTRAINT "ai_agent_llm_turns_request_refs_array" CHECK (jsonb_typeof("ai_agent_llm_turns"."request_refs") = 'array');
--> statement-breakpoint
ALTER TABLE "ai_agent_llm_turns" ADD CONSTRAINT "ai_agent_llm_turns_request_patches_array" CHECK (jsonb_typeof("ai_agent_llm_turns"."request_patches") = 'array');
--> statement-breakpoint
ALTER TABLE "ai_agent_llm_turns" ADD CONSTRAINT "ai_agent_llm_turns_tool_results_array" CHECK (jsonb_typeof("ai_agent_llm_turns"."tool_results") = 'array');
