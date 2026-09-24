---
name: agent-tool
description: Add or change a tool that the grap-ia chat agent (Claude via the Anthropic Python SDK Tool Runner in apps/api) can call - listing drafting/publishing/editing, search, status changes, saved demand, connecting brokers, leads, or any new broker action exposed to the agent. Use this whenever the task involves what the agent can do, how it extracts listing fields from Spanish broker messages, tool arguments or descriptions, tool authorization, or agent eval cases, even if phrased as a product request like "let brokers mark a property as rented from the chat" or "the bot should be able to show my leads".
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
apps/api/app/agent/runner.py           client, model, system prompt, runner config (shared by all tools)
apps/api/app/agent/context.py          AgentContext: broker_id, is_verified, db session (under the broker's claims), request_id
apps/api/app/agent/tools/<domain>.py   tool factories, e.g. listings.py, search.py, demand.py, chat.py
apps/api/app/services/<domain>.py      business logic the tools call
apps/api/tests/                        pytest
apps/api/evals/agent/<tool>.jsonl      eval cases for the agent
```

If a directory doesn't exist yet, create it in this shape.

If the tool needs new tables or columns, write the migration with the `supabase-migration` skill first. Services and tools are written against the schema, not the other way around.

## Design rules

**One tool per business action a broker would recognize.** Name it `verb_noun` (`search_listings`, `set_listing_status`, `save_demand`, `connect_brokers`). Prefer a few clear tools over one tool with a `mode` argument, because the model picks tools by their description.

**Give the agent a way to find what it acts on.** A tool that takes an ID is useless unless another tool returns that ID. Brokers say "el depa de Narvarte", not a UUID. Pair every action on an existing entity with a lookup the agent can call first, e.g. `list_my_listings(colonia=..., operation=..., status=...)` before `set_listing_status`. When the lookup returns several candidates, the agent asks which one.

**The tool is an adapter; the logic lives in a service.** The tool function maps arguments, calls `app/services/...` and formats the result. Authorization lives in the service, so every caller gets the same rules:
- the verified-broker check (scope §2);
- ownership checks (scope §4).

Callers include the agent, REST endpoints and jobs. The DB session runs under the broker's JWT claims, so RLS backs this up without replacing it. The tool itself doesn't re-implement the checks.

**The docstring is the prompt.** The SDK sends the function's docstring as the tool description and the `Args:` section as parameter descriptions. State:
- what the tool does, when to use it and when not to;
- what it returns;
- the units of each argument.

Include the Spanish words brokers actually use ("renta", "recámaras", "colonia", "28 mil"), so the model maps "depa de 2 rec en la Roma" to the right arguments.

**Identity comes from `AgentContext`, never from arguments.** Never add a `broker_id` parameter. The broker is always `ctx.broker_id`.

**Confirmation is enforced in code for actions that affect others or can't be easily undone:**
- publishing a listing;
- changing a listing's status (it disappears from or reappears in other brokers' searches);
- archiving/deleting;
- `connect_brokers` (it contacts another broker).

Use draft → confirm with server-side state:
1. The first tool (`draft_listing`, `propose_status_change`) validates, saves a pending record and returns a normalized summary plus a `pending_id`.
2. The agent shows the summary and asks.
3. Only the confirm tool (`publish_listing(pending_id)`, `confirm_status_change(pending_id)`) performs the change. The service rejects a pending record that is unknown, expired or belongs to another broker.

The docstring still says to call the confirm tool only after an explicit "sí", but the rule lives in code, not only in the prompt.

**Private, easily reversible actions** like saving a broker's own search (`save_demand`) can run directly, but the tool result must include a summary the agent reads back to the broker ("Guardé tu búsqueda: renta en Condesa, hasta $30,000, 2 recámaras").

**Typed, normalized arguments.**
- Use `Literal[...]` for closed vocabularies (operation `rent`/`sale`, property types).
- Prices are numbers in whole currency units plus a currency code; the service converts to centavos.
- Colonias are free text from the broker, resolved by the service against the SEPOMEX catalog. An exact or unambiguous match proceeds. A near match or several candidates ("Condesa" → Hipódromo Condesa, Condesa; "la Roma" → Roma Norte, Roma Sur) returns `candidates` and saves nothing, so the agent asks.
- Mandatory listing fields are listed in scope §5.

**Return what the model needs, nothing more.** Return compact JSON strings: IDs for follow-up calls, the normalized fields, short summaries. Never return another broker's contact details (the connection happens through `connect_brokers`) or any end-client data.

**Expected failures are results, not exceptions.** Return `{"error": "<code>", ...}` with what the agent needs to ask the next question: `missing_fields`, `candidates`, `broker_not_verified`, `pending_expired`. For an entity that doesn't exist and one owned by someone else, return the same `not_found`, so the tool never reveals other brokers' listings. Let only unexpected exceptions propagate.

**Keep end-client data out (LFPDPPP, scope §11).** Brokers will write things like "para mi cliente Juan Pérez, 55 1234 5678, presupuesto 30 mil".
- Demand and listing records store requirements (budget, zone, bedrooms), never the client's identity. Tool schemas have no fields for client names or contacts.
- The docstring tells the model to leave those details out.
- An eval case checks that they never appear in arguments.

If a tool must handle such data, run the `privacy-review` skill.

**Stay fast.** Chat tools should return in about a second. Embeddings, photo tagging, duplicate checks and match notifications are Inngest jobs: have the service emit the event after commit (e.g. `listing/published`, see the `inngest-job` skill) instead of doing the work inline.

## Code shape

FastAPI is async, so use `@beta_async_tool` with `async def`. Tools are built per request by a factory, so they close over that request's `AgentContext`:

```python
from typing import Literal

from anthropic import beta_async_tool

from app.agent.context import AgentContext
from app.services import listings as listings_service


def build_listing_tools(ctx: AgentContext) -> list:
    @beta_async_tool
    async def propose_status_change(
        listing_id: str,
        status: Literal["available", "under_offer", "closed"],
    ) -> str:
        """Prepare a status change for one of the broker's own listings; nothing changes yet.

        Use when the broker says a property was rented/sold ("ya se rentó",
        "ya se vendió"), is under offer ("tiene apartado", "en negociación"),
        or is available again. Get listing_id from list_my_listings first.
        Returns a summary and a pending_id: show the summary, and only call
        confirm_status_change after the broker explicitly agrees.

        Args:
            listing_id: ID of the listing, from list_my_listings.
            status: New status: available, under_offer or closed.
        """
        result = await listings_service.propose_status_change(
            ctx.db, broker_id=ctx.broker_id, listing_id=listing_id, status=status
        )
        return result.model_dump_json()

    return [propose_status_change]  # plus list_my_listings, confirm_status_change, ...
```

Register the factory's tools in `runner.py`, where the runner is created per request with `tools=[*build_listing_tools(ctx), ...]`. Don't create a separate runner or client per tool.

## Tests and evals

1. **Service tests (pytest)** against a test database: the happy path, a non-owner getting `not_found`, an unverified broker being rejected, validation errors, colonia ambiguity, currency/area normalization, and a pending record that is expired, reused or foreign.
2. **Adapter test:** build the tools with a fake `AgentContext` (stub the service) and check the tool's result JSON for success and for one expected error.
3. **Eval cases** in `apps/api/evals/agent/<tool>.jsonl`, one JSON object per line:
   - `history` holds earlier turns for multi-turn flows;
   - `expect_tool: null` marks cases where the agent should ask a question instead of calling a tool;
   - `forbid_in_args` lists strings that must never appear in tool arguments.

   Use realistic Mexican Spanish with slang, abbreviations and missing fields:

```json
{"input": "tengo un depa en renta en la roma nte, 2 rec, 85m2, 28 mil + mantenimiento, 1 cajón", "expect_tool": "draft_listing", "expect_args": {"operation": "rent", "property_type": "apartment", "colonia": "Roma Norte", "bedrooms": 2, "built_m2": 85, "price": 28000, "currency": "MXN", "parking_spaces": 1}}
{"input": "ya se rentó el de Narvarte", "expect_tool": "list_my_listings", "expect_args": {"colonia": "Narvarte"}}
{"history": [{"role": "user", "content": "ya se rentó el de Narvarte"}, {"role": "assistant", "content": "Encontré tu depa en Narvarte Poniente de $18,000. ¿Lo marco como rentado?"}], "input": "sí", "expect_tool": "confirm_status_change"}
{"input": "cámbiale el precio al de la Roma", "expect_tool": null, "note": "must ask for the new price (and which listing, if several)"}
{"input": "busco casa en venta en Coyoacán hasta 9 millones, mínimo 3 recámaras, para mi cliente Laura Gómez", "expect_tool": "search_listings", "expect_args": {"operation": "sale", "property_type": "house", "max_price": 9000000, "min_bedrooms": 3}, "forbid_in_args": ["Laura", "Gómez"]}
```

To build or run the eval harness (including how to replay `history`), use the built-in `claude-api` skill's `build-eval` flow. Aim for at least 5 cases per tool, including one where the agent should ask instead of acting.
