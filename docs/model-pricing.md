# Model pricing metadata

CodexBar has an additive models.dev pricing pipeline for future cost lookup work. Existing hardcoded pricing remains unchanged for now.

## Source and cache

- Source API: `https://models.dev/api.json`
- No API key is required.
- Local cache: `~/Library/Caches/CodexBar/model-pricing/models-dev-v1.json`
- TTL: 24 hours

The pipeline lets future scanner code read the last valid cache synchronously with `ModelsDevPricingPipeline.lookup` and refresh stale metadata separately with `ModelsDevPricingPipeline.refreshIfNeeded`. If a refresh fails, the last valid cache remains usable.

## Lookup rules

Pricing is scoped by provider id and model id. This prevents two providers with the same model id or display name from sharing pricing accidentally.

Planned local source mapping:

- Codex/OpenAI logs: models.dev provider id `openai`
- Claude logs: models.dev provider id `anthropic`
- Vertex AI Claude logs: models.dev provider id `google-vertex-anthropic`

Codex, Claude, and z.ai cost scans now look up models.dev first and fall back to the built-in tables.
models.dev publishes only one cache-write rate (5-minute), so Claude one-hour writes are always derived as 2x input.
Anthropic-specific modifiers (fast mode, US-only inference, web search) come from the built-in rules in
`CostUsagePricing+Claude.swift`; see [Claude](claude.md#cost-usage-local-log-scan).

## Units

models.dev publishes costs as USD per 1M tokens. CodexBar converts those to USD per token in the metadata layer:

```text
perToken = modelsDevCost / 1_000_000
```

When models.dev includes `cost.context_over_200k`, CodexBar parses those values as the above-200k-token pricing lane and converts them with the same per-1M-token rule.
