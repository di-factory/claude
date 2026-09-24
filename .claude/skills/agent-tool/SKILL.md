---
name: agent-tool
description: Add or change a tool that the grap-ia chat agent (Claude via the Anthropic Python SDK Tool Runner in apps/api) can call - listing creation/editing, search, status changes, saved demand, connecting brokers, leads, or any new broker action exposed to the agent. Use this whenever the task involves what the agent can do, how it extracts listing fields from Spanish broker messages, tool arguments or descriptions, tool authorization, or agent eval cases, even if phrased as a product request like "let brokers mark a property as rented from the chat" or "the bot should be able to show my leads".
---

# grap-ia agent tools

The grap-ia agent is Claude (`claude-opus-5`) running in the FastAPI service through the Anthropic Python SDK's Tool Runner. Tools are the only way the agent touches data. Every tool is a boundary where a mistake shows up as:

- a listing published before the broker confirmed it;
- one broker acting as another;
- an end-client's phone number ending up in a searchable description.

Keep tools thin, typed and authorized in code.

Read `CLAUDE.md` for the conventions and glossary, and `scope.md` §3-§5 for what each interaction must do. Load the built-in `claude-api` skill before changing anything about the runner itself (model, thinking/effort, caching, refusal handling, fallbacks). This skill covers the tools.

## Where things live

```
apps/api/app/agent/runner.py      client, model, system prompt, runner config (shared by all tools)
apps/api/app/agent/context.py     AgentContext: broker_id, is_verified, db session (under the broker's claims), request_id
apps/api/app/agent/tools/<domain>.py   tool factories, e.g. listings.py, search.py, demand.py, chat.py
apps/api/app/services/<domain>.py      business logic the tools call
apps/api/tests/                   pytest
apps/api/evals/agent/<tool>.jsonl eval cases for the agent
```

If a directory doesn't exist yet, create it in this shape.

## Design rules

**One tool per business action a broker would recognize.** Name it `verb_noun` (`search_listings`, `set_listing_status`, `save_demand`, `connect_brokers`). Prefer a few clear tools over one tool with a `mode` argument, because the model picks tools by their description.

**The tool is an adapter; the logic lives in a service.** The tool function validates arguments, calls `app/services/...` and formats the result. Tests and other callers (REST endpoints, jobs) use the service directly, which keeps behavior identical whether an action comes from chat or the UI.

**The docstring is the prompt.** The SDK sends the function's docstring as the tool description and the `Args:` section as parameter descriptions. State:
- what the tool does, when to use it and when not to;
- what it returns;
- the units of each argument.

Include the Spanish words brokers actually use ("renta", "recámaras", "colonia", "28 mil"), so the model maps "depa de 2 rec en la Roma" to the right arguments.

**Identity and permissions come from `AgentContext`, never from arguments.** Never add a `broker_id` parameter. Check `ctx.is_verified` for any tool that posts or searches (scope §2), and check ownership for mutations (scope §4). The DB session runs under the broker's JWT claims, so RLS backs up these checks; it doesn't replace them.

**Mutations need explicit confirmation (scope §3.1).** Use draft → confirm:
- `draft_listing` validates and saves a draft, and returns the normalized fields plus any missing mandatory ones;
- the agent shows the broker a summary;
- only after the broker says yes does it call `publish_listing(draft_id)`.

Apply the same pattern to deletions and status changes that hide a listing. Say in the docstring that the tool must only be called after the broker explicitly confirmed.

**Typed, normalized arguments.**
- Use `Literal[...]` for closed vocabularies (operation `rent`/`sale`, property types).
- Prices are numbers in whole currency units plus a currency code; convert to centavos inside the service.
- Colonia is free text from the broker, resolved by the service against the SEPOMEX catalog. On ambiguity, return the candidates so the agent can ask ("¿Roma Norte o Roma Sur?").
- Mandatory listing fields are listed in scope §5.

**Return what the model needs, nothing more.** Return compact JSON strings: IDs for follow-up calls, the normalized fields, short summaries. Never return another broker's contact details (the connection happens through `connect_brokers`) or any end-client data.

**Expected failures are results, not exceptions.** Return `{"error": "...", "missing_fields": [...]}` or `{"error": "...", "candidates": [...]}` so the agent can ask the broker a precise question. Let only unexpected exceptions propagate.

**Keep end-client data out (LFPDPPP, scope §11).** Brokers will write things like "para mi cliente Juan Pérez, 55 1234 5678, presupuesto 30 mil". Demand and listing records store requirements (budget, zone, bedrooms), never the client's identity. Descriptions that get embedded must not contain names or phone numbers. If a tool must handle such data, run the `privacy-review` skill.

**Stay fast.** Chat tools should return in about a second. Embeddings, photo tagging, duplicate checks and match notifications are Inngest jobs: have the service emit an event after the commit (see the `inngest-job` skill) instead of doing the work inline.

## Code shape

FastAPI is async, so use `@beta_async_tool` with `async def`. Tools are built per request by a factory, so they close over that request's `AgentContext`:

```python
from typing import Literal

from anthropic import beta_async_tool

from app.agent.context import AgentContext
from app.services import listings as listings_service


def build_listing_tools(ctx: AgentContext) -> list:
    @beta_async_tool
    async def set_listing_status(
        listing_id: str,
        status: Literal["available", "under_offer", "closed"],
    ) -> str:
        """Change the status of one of the broker's own listings.

        Use when the broker says a property was rented/sold ("ya se rentó",
        "ya se vendió"), is under offer ("tiene apartado", "en negociación"),
        or is available again. Closed listings drop out of other brokers'
        searches. Only call this after the broker has explicitly confirmed
        which listing and which new status.

        Args:
            listing_id: ID of the listing, as returned by earlier tool results.
            status: New status: available, under_offer or closed.
        """
        if not ctx.is_verified:
            return '{"error": "broker_not_verified"}'
        result = await listings_service.set_status(
            ctx.db, broker_id=ctx.broker_id, listing_id=listing_id, status=status
        )
        return result.model_dump_json()

    return [set_listing_status]
```

Register the factory's tools in `runner.py`, where the runner is created per request with `tools=[*build_listing_tools(ctx), ...]`. Don't create a separate runner or client per tool.

## Tests and evals

1. **Service tests (pytest):** the happy path, non-owner rejection, unverified-broker rejection, validation errors, and currency/area normalization.
2. **Adapter test:** at least one test that builds the tools with a fake `AgentContext` and checks the tool's result JSON for success and for an expected error.
3. **Eval cases:** add realistic Mexican Spanish broker messages to `apps/api/evals/agent/<tool>.jsonl`, one JSON object per line, with the expected tool and key arguments. Include slang, abbreviations and missing fields, e.g.:

```json
{"input": "tengo un depa en renta en la roma nte, 2 rec, 85m2, 28 mil + mantenimiento, 1 cajón", "expect_tool": "draft_listing", "expect_args": {"operation": "rent", "property_type": "apartment", "colonia": "Roma Norte", "bedrooms": 2, "built_m2": 85, "price": 28000, "currency": "MXN", "parking_spaces": 1}}
{"input": "ya se rentó el de Narvarte", "expect_tool": "set_listing_status", "expect_args": {"status": "closed"}, "note": "agent must first confirm which listing if the broker has several in Narvarte"}
{"input": "busco casa en venta en Coyoacán hasta 9 millones, mínimo 3 recámaras, para mi cliente Laura Gómez", "expect_tool": "search_listings", "expect_args": {"operation": "sale", "property_type": "house", "max_price": 9000000, "min_bedrooms": 3}, "forbid_in_args": ["Laura", "Gómez"]}
```

To build or run the eval harness, use the built-in `claude-api` skill's `build-eval` flow. Aim for at least 5 cases per tool, including one where the agent should ask a question instead of calling the tool.
