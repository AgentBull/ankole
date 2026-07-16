# Final validation

Quality review belongs inside the lead Codex session. Use native subagents for an independent factual challenge and requirement review when useful, then decide which findings merit repair. Reviewer judgments are advisory and never become runtime pass scores.

Before submission, ensure `report/report.md` directly answers every research requirement and contains every conclusion, the material evidence needed to support it, source links or bibliographic locators, uncertainty, and limitations. It must not refer the reader to JSON, an evidence index, an archive, or a bundle for essential information.

Call `research_validate_delivery` only after that substantive review. It checks only that `report/report.md` exists and is non-empty. Passing this check is not approval of completeness or quality. It does not inspect or require JSON, evidence indexes, source archives, ACH work files, plans, logs, reviewer output, source counts, or fixed report sections.

If the check fails, repair only the Markdown report in this same session.
