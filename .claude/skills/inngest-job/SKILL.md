---
name: inngest-job
description: Add or change grap-ia background work as Inngest functions in the Python FastAPI service - listing embeddings (Voyage), photo room-type tagging (Claude Haiku 4.5), duplicate-listing detection, proactive match detection and notifications, geocoding backfills, retention/deletion cleanup, and any scheduled (cron) task. Use this whenever work is slow, calls an external API in bulk, must retry, should run after a database change, or runs on a schedule - even if the user just says "when a listing is created, generate its embedding", "notify brokers about new matches", "clean up old chats nightly" or "this endpoint is too slow".
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
apps/api/app/jobs/<domain>.py        functions, e.g. listings.py, matching.py, retention.py
apps/api/app/jobs/__init__.py        ALL_FUNCTIONS list served at /api/inngest via inngest.fast_api.serve(...)
apps/api/app/services/<domain>.py    business logic the steps call (shared with the API and agent tools)
```

Add each new function to `ALL_FUNCTIONS`. An unregistered function never runs and fails silently.

## Conventions

**Event names:** `<domain>/<entity>.<past_tense_verb>` in lowercase, e.g.
- `listing/created`, `listing/updated`, `listing/status.changed`, `listing/photos.uploaded`;
- `demand/saved`, `thread/created`, `broker/verified`.

Function IDs are kebab-case actions: `embed-listing`, `tag-listing-photos`, `detect-duplicates`, `match-new-listing`.

**Payloads carry IDs, not records:** `{"listing_id": "...", "broker_id": "..."}`. The job re-reads fresh data, which avoids acting on stale values and keeps personal data out of Inngest's event history (LFPDPPP, see the `privacy-review` skill). Never put chat text, names or phone numbers in an event.

**Emit after commit.** Send the event only after the database transaction commits. Otherwise the job can run before the row exists, or for a change that was rolled back.

**Each side effect is its own step.** Wrap every external call and every write in `step.run("<stable-name>", ...)`. Step names must be stable and unique within a run, because Inngest matches them to memoize results. That means no timestamps, and inside loops the name includes the item's ID (e.g. `notify-{broker_id}`). Code outside steps re-runs on every retry, so keep it free of side effects.

**Every step is safe to repeat:**
- Writes are upserts or conditional updates.
- Embeddings store a content hash; skip the step when the hash matches.
- Notifications use a unique `(broker_id, listing_id, kind)` key so a retry never sends twice.

Use Inngest's debounce for bursty triggers, such as `listing/updated` while a broker edits several fields. Debounce per `listing_id` so only the final version is processed.

**Protect rate-limited APIs.** Put concurrency and/or throttle limits on functions that call Claude (photo tagging and duplicate checks use `claude-haiku-4-5`), Voyage or Google Maps, so a bulk backfill can't exhaust rate limits for the live chat.

**Privileged database access.** Jobs connect with a privileged role, so RLS does not apply. Scope every query by the IDs in the event, and never let a job make data visible to brokers who shouldn't see it:
- match notifications go only to the broker who owns the saved demand;
- lead records are only created for the listing owner.

**Record failure state.** After retries are exhausted, record it where the product can see it (e.g. `listings.embedding_status = 'failed'`) and let the error reach Sentry. A listing that silently never gets an embedding never shows up in semantic search.

**Scheduled jobs** use a cron trigger with an explicit timezone, e.g. `TZ=America/Mexico_City 0 3 * * *`. Make them resumable, e.g. process in batches with one step per batch.

## Code shape

The Inngest Python SDK changed its handler signature between versions (newer versions expose steps as `ctx.step`; older ones pass a separate `step` argument). Check the installed `inngest` version and follow the pattern already used in `apps/api/app/jobs/`, or the SDK docs for that version. The structure below is what matters:

```python
import inngest

from app.jobs.client import inngest_client
from app.services import embeddings as embeddings_service


@inngest_client.create_function(
    fn_id="embed-listing",
    trigger=inngest.TriggerEvent(event="listing/created"),
    # plus: debounce per listing_id for listing/updated, concurrency limit for Voyage
)
async def embed_listing(ctx: inngest.Context) -> dict:
    listing_id = ctx.event.data["listing_id"]

    text = await ctx.step.run(
        "build-embedding-text",
        lambda: embeddings_service.build_listing_text(listing_id),
    )
    vector = await ctx.step.run(
        "call-voyage",
        lambda: embeddings_service.embed(text),
    )
    await ctx.step.run(
        "store-embedding",
        lambda: embeddings_service.upsert_listing_embedding(listing_id, vector, text),
    )
    return {"listing_id": listing_id}
```

`build_listing_text` uses only listing fields: type, colonia, amenities and the description with any names or phone numbers stripped. It never uses chat content.

## Testing

1. **Service tests (pytest)** for the logic each step calls, including the "already done → skip" branch that makes the step safe to repeat.
2. **A function-level test**, or a documented manual run: start the API, run `npx inngest-cli@latest dev -u http://localhost:8000/api/inngest`, send the triggering event from the dev server UI, and confirm each step ran once. Then retry the run and confirm no duplicate side effects.
3. When the job sends notifications or creates leads, add a test proving that a broker who isn't the intended recipient gets nothing.
