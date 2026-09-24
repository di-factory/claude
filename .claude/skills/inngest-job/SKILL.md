---
name: inngest-job
description: Add or change grap-ia background work as Inngest functions in the Python FastAPI service - listing embeddings (Voyage), photo room-type tagging (Claude Haiku 4.5), duplicate-listing detection, proactive match detection and notifications, geocoding backfills, retention/deletion cleanup, and any scheduled (cron) task. Use this whenever work is slow, calls an external API in bulk, must retry, should run after a database change, or runs on a schedule - even if the user just says "when a listing is published, generate its embedding", "notify brokers about new matches", "clean up old chats nightly" or "this endpoint is too slow".
---

# Inngest background jobs for grap-ia

A chat reply should never wait on slow work (CLAUDE.md). The Inngest functions in `apps/api` handle anything that is:
- slow;
- rate-limited;
- retry-worthy;
- scheduled.

Inngest re-runs failed steps and memoizes completed ones. Correctness therefore depends on steps being deterministic and safe to repeat, and most of this skill is about that.

Read `CLAUDE.md` first, and `tech-stack.md` §3 and §5 for which models and services each job uses.

## Where things live

```
apps/api/app/jobs/client.py          the single inngest.Inngest(app_id="grapia") client
apps/api/app/jobs/events.py          event-name constants + typed send helpers (send_listing_published(...))
apps/api/app/jobs/<domain>.py        functions, e.g. listings.py, matching.py, retention.py
apps/api/app/jobs/__init__.py        ALL_FUNCTIONS list served at /api/inngest via inngest.fast_api.serve(...)
apps/api/app/services/<domain>.py    business logic the steps call (shared with the API and agent tools)
```

Add each new function to `ALL_FUNCTIONS`. An unregistered function never runs and fails silently. The SDK is pinned as `inngest>=0.5,<0.6` in `apps/api/pyproject.toml`; the patterns below are verified against 0.5.x.

## Events

**Names:** `<domain>/<entity>.<past_tense_verb>`, lowercase, defined once as constants in `events.py`.

| Event | When it's sent |
|---|---|
| `listing/published` | A draft becomes visible to other brokers (after the broker confirms). Drafts do **not** trigger matching or embeddings. |
| `listing/updated` | A published listing's searchable fields or description changed |
| `listing/status.changed` | available ↔ under_offer ↔ closed, or archived |
| `listing/photos.uploaded` | New photos are stored |
| `demand/saved` | A saved search becomes active |
| `broker/verified`, `thread/created` | As named |

Function IDs are kebab-case actions: `embed-listing`, `tag-listing-photos`, `detect-duplicates`, `match-new-listing`.

**Payloads carry IDs, not records:** `{"listing_id": "...", "broker_id": "..."}`. The job re-reads fresh data, which avoids acting on stale values and keeps personal data out of Inngest's history. Never put chat text, names or phone numbers in an event.

**Emit after commit, and plan for the gap.** Send the event only after the database transaction commits; otherwise the job can run before the row exists, or for a change that was rolled back. Even so, a crash between the commit and the send loses the event. Every derived-state job (embeddings, matching, photo tags) therefore needs a **reconcile cron** that finds rows whose job state is missing or stale and re-sends their events. Because the jobs are idempotent, re-sending is safe.

## Function rules

**Each side effect is its own step.** Wrap every external call and every write in `ctx.step.run("<name>", ...)`. Code outside steps re-runs on every retry, so keep it free of side effects. Step names must be stable and unique within a run, because Inngest matches them to memoize results. That means no timestamps, and inside loops the name includes the item's ID (e.g. `notify-{broker_id}`).

**Step results live in Inngest's run history.** Return IDs, counts, hashes and statuses from steps, not personal data. Listing text with contact details stripped is fine; chat text and client details never are.

**Every step is safe to repeat:**
- Writes are upserts or conditional updates.
- Embeddings store a hash of `(embedding model ID, embedded text)`; skip the step when the hash matches. Including the model ID means a model change naturally forces a re-embed.
- Notifications use a dedupe key derived from the **triggering event's ID** plus the recipient, e.g. unique `(recipient_broker_id, kind, source_event_id)`. A retry of the same event can never double-send, while a genuinely new event (a new matching demand, a relevant listing update) can still notify.

**Choose flow control deliberately:**
- `idempotency="event.data.listing_id"`: skip duplicate runs for the same entity within Inngest's idempotency window (use it for once-per-entity jobs such as the first match run).
- `concurrency=[inngest.Concurrency(limit=1, key="event.data.listing_id")]`: never process the same entity twice at once.
- Rate-limited APIs (Claude via `claude-haiku-4-5` for photo tagging and duplicate checks, Voyage, Google Maps): add a function-wide concurrency or throttle limit, so a bulk backfill can't exhaust rate limits for the live chat.
- Debounce only bursty triggers. Debounce `listing/updated` per `listing_id` so a broker editing several fields yields one run, but let `listing/published` run immediately so a new listing becomes searchable without delay. Put these in separate functions if they need different flow control.

**Large fan-out:** notifying many recipients from one run means many steps, and a single run has a step limit. When the recipient count can grow large, have one step send one event per recipient (or per batch) and let a separate function handle each.

**Privileged database access.** Jobs connect with a privileged role, so RLS does not apply. Scope every query by the IDs in the event, re-read ownership from the database (never trust the payload), and never let a job make data visible to brokers who shouldn't see it:
- match notifications go only to the broker who owns the saved demand;
- lead records are only created for the listing owner.

**Job state lives in its own table.** Store per-entity job status (`embedding_status`, `matching_status`, hashes, `last_error`) in job-owned tables such as `listing_embeddings` or `listing_job_state`, not in columns on `listings`. Otherwise every job write bumps the listing's `updated_at`, and the owner's RLS update policy would let brokers edit job state.

**Failure handling.** Set `retries=` explicitly, and add an `on_failure` handler that:
- records the failure in the job-state table so the product and admins can see it;
- reports to Sentry with IDs only.

Errors inside steps don't reach Sentry by themselves. A listing whose embedding silently never finishes never shows up in semantic search.

**Scheduled jobs** use a cron trigger with an explicit timezone, e.g. `TZ=America/Mexico_City 0 3 * * *`. Make them resumable by processing in batches, with one step per batch.

## Code shape (inngest 0.5.x)

```python
import inngest
import sentry_sdk

from app.jobs.client import inngest_client
from app.jobs.events import LISTING_PUBLISHED
from app.services import embeddings as embeddings_service


async def _on_embed_listing_failed(ctx: inngest.Context) -> None:
    # The failure event wraps the original event: ctx.event.data["event"]["data"]
    original = ctx.event.data.get("event") or {}
    listing_id = (original.get("data") or {}).get("listing_id")
    if isinstance(listing_id, str):
        await ctx.step.run(
            "mark-embedding-failed",
            lambda: embeddings_service.set_status(listing_id, "failed"),
        )
    sentry_sdk.capture_message(
        "embed-listing exhausted retries",
        level="error",
        extras={"listing_id": listing_id, "run_id": ctx.run_id},
    )


@inngest_client.create_function(
    fn_id="embed-listing",
    trigger=inngest.TriggerEvent(event=LISTING_PUBLISHED),
    concurrency=[inngest.Concurrency(limit=1, key="event.data.listing_id")],
    retries=4,
    on_failure=_on_embed_listing_failed,
)
async def embed_listing(ctx: inngest.Context) -> dict[str, object]:
    listing_id = str(ctx.event.data["listing_id"])

    plan = await ctx.step.run(
        "plan-embedding",  # returns {"skip": bool, "content_hash": str}, never the text
        lambda: embeddings_service.plan_listing_embedding(listing_id),
    )
    if plan["skip"]:
        return {"listing_id": listing_id, "skipped": True}

    await ctx.step.run(
        "embed-and-store",
        lambda: embeddings_service.embed_and_store(listing_id, plan["content_hash"]),
    )
    return {"listing_id": listing_id, "skipped": False}
```

A few things to follow in real code:

- **Embedding text** comes from listing fields only: type, colonia, amenities, and the description with phone numbers and emails stripped (see the `privacy-review` skill). It never comes from chat content.
- **`embed_and_store`** rebuilds that text, calls Voyage, and upserts vector, hash and status in a single step. That keeps the text out of the run history, and the step is safe to repeat because of the hash.
- **Wiring:** `apps/api/app/jobs/__init__.py` serves `ALL_FUNCTIONS` with `inngest.fast_api.serve(app, inngest_client, ALL_FUNCTIONS)`.

## Testing

1. **Service tests (pytest)** for the logic each step calls, including the "already done → skip" branch that makes the step safe to repeat.
2. **A function test** that runs the handler with a fake `ctx` whose `step.run` executes the callable and records step names. Assert which steps ran, and that a second run for the same event causes no duplicate side effects.
3. **A dev-server check:** start the API, run `npx inngest-cli@latest dev -u http://localhost:8000/api/inngest`, send the triggering event, and confirm each step ran once.
4. When the job sends notifications or creates leads, add a test proving that a broker who isn't the intended recipient gets nothing.
