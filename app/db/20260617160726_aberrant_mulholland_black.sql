ALTER TABLE "llm_providers" RENAME COLUMN "pi_provider" TO "llm_provider";--> statement-breakpoint
ALTER TABLE "llm_providers" DROP CONSTRAINT "llm_providers_pi_provider_nonempty";--> statement-breakpoint
DROP INDEX "llm_providers_pi_provider_index";--> statement-breakpoint
CREATE INDEX "llm_providers_llm_provider_index" ON "llm_providers" USING btree ("llm_provider");--> statement-breakpoint
ALTER TABLE "llm_providers" ADD CONSTRAINT "llm_providers_llm_provider_nonempty" CHECK ("llm_providers"."llm_provider" <> '');--> statement-breakpoint
UPDATE "ai_agent_llm_turns"
SET "provider_metadata" =
  ("provider_metadata" - 'pi_provider') ||
  CASE
    WHEN "provider_metadata" ? 'llm_provider' THEN '{}'::jsonb
    ELSE jsonb_build_object('llm_provider', "provider_metadata" -> 'pi_provider')
  END
WHERE "provider_metadata" ? 'pi_provider';
