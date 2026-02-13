# Golden Weekly Fixtures (Anonymized)

This document describes the golden weekly dataset used by the QA evaluation harness.

## Files

- Dataset: `tests/fixtures/golden_weeks_dataset_v1.json`
- Schema: `schemas/golden_weeks_dataset.schema.json`
- Harness validation: `tests/eval_harness.py`

## Provenance

- Source: historical weekly patterns from prior running-coach executions and synthetic edge-case augmentation.
- Goal: represent a realistic range of training load, recovery signals, and adherence outcomes.
- Coverage target: 5-10 weekly fixtures per dataset version.

## Anonymization Approach

- Remove all direct identifiers (name, email, phone, chat/user IDs, usernames, addresses).
- Replace athlete identity with synthetic persona labels (`persona-*`).
- Keep only training-relevant numeric/temporal signals.
- Manually review fixtures before merge.

## Update Policy

1. Create a new dataset version when fixture content changes materially.
2. Keep fixture count between 5 and 10 per version.
3. Ensure schema validation passes against `schemas/golden_weeks_dataset.schema.json`.
4. Ensure CI `Evaluation harness` passes and publishes fixture inventory/version in the job summary.
5. Record any major fixture changes in the PR description and Jira ticket.
