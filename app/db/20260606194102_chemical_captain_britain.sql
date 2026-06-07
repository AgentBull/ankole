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
CREATE INDEX "llm_providers_pi_provider_index" ON "llm_providers" USING btree ("pi_provider");