---
name: supabase-migration
description: Write grap-ia database changes as Supabase SQL migrations with Row-Level Security policies, pgvector/PostGIS indexes, pgTAP RLS tests, regenerated TypeScript types and matching SQLAlchemy models. Use this whenever the task changes the database in any way - a new table, column, enum, index, constraint, RLS policy, SQL function, trigger, extension or storage bucket policy - even if the user just says "add a field for parking spaces", "store saved searches", "brokers need to see their leads" or "fix the listings query permissions". Also use it when reviewing or debugging RLS behavior.
---

# Supabase migrations for grap-ia

The SQL files in `supabase/migrations/` are the single source of truth for the schema. Row-Level Security (RLS) is grap-ia's main control for two product rules:

- only a listing's owner can change it;
- only the brokers in a conversation can see its chat and lead data, which is regulated personal data under Mexico's LFPDPPP.

A migration without correct policies is a data leak, so every change ships with its policies and with tests proving them.

Read `CLAUDE.md` for the project conventions (money, location, identity). The scope decisions behind the rules below are in `scope.md` §4-§7 and §11.

## Workflow

1. **Create the file.** Run `supabase migration new <snake_case_description>` (e.g. `add_listing_parking_spaces`). If the CLI isn't available, create `supabase/migrations/<YYYYMMDDHHMMSS>_<name>.sql` yourself. Never edit a migration that has already been applied or merged; write a new one that alters it.
2. **Write the SQL** following the checklist below.
3. **Apply locally** with `supabase db reset` (replays every migration, which also catches ordering bugs).
4. **Write or extend pgTAP tests** in `supabase/tests/` for every policy you added or changed, then run `supabase test db`.
5. **Regenerate TypeScript types:** `supabase gen types typescript --local > apps/web/src/lib/database.types.ts`.
6. **Update the SQLAlchemy models** in `apps/api/app/db/models/` so they mirror the new schema. There is no Alembic: SQLAlchemy never generates or runs migrations here.
7. **Check advisors.** Use the Supabase MCP `get_advisors` tool if it is connected, otherwise `supabase db lint`. Fix security warnings (tables without RLS, mutable `search_path`) before finishing.
8. **Summarize** the change for the PR. List the policies added and any destructive steps.

If the Supabase stack can't run (no CLI, or Docker can't pull its images), fall back to a throwaway Postgres with the `postgis`, `vector` and `pgtap` extensions:
1. Stub what Supabase provides: the `auth` schema with `auth.users`, the `auth.uid()` function reading `request.jwt.claims`, and the `anon`, `authenticated` and `service_role` roles.
2. Apply the migrations in order.
3. Run the tests with `pg_prove`.

If even that isn't possible, still write the migration and tests, then say clearly which steps you couldn't run.

## SQL checklist

### Tables and columns
- `id uuid primary key default gen_random_uuid()`, `created_at timestamptz not null default now()`, `updated_at timestamptz not null default now()` maintained by the shared `set_updated_at()` trigger. Create that trigger function in the first migration that needs it.
- Brokers are 1:1 with `auth.users`. `public.brokers.id` references `auth.users(id)`, so `broker_id` columns compare directly to `auth.uid()`.
- Money: `<name>_cents bigint check (<name>_cents >= 0)` plus `currency char(3) check (currency in ('MXN','USD'))`. Add `not null` when the value is mandatory (a listing's price, scope §5). Leave it nullable when it's optional (a saved search's budget), with a check that the currency is set whenever the amount is.
- Areas: `numeric(10,2)`, in m².
- Location of a listing: `location extensions.geography(Point, 4326)` plus `colonia_id` referencing the SEPOMEX catalog table, and `city_id`.
- Location of a search or preference (e.g. "Condesa o Roma Norte"): a join table such as `demand_colonias(demand_id, colonia_id)`, not an array or free text, so it can be indexed and joined.
- Never use free-text zone columns as the filter source.
- Job-owned state (embedding status, content hashes, matching status, last errors) goes in its own table, such as `listing_embeddings` or `listing_job_state`. On the owner's table, every job write would bump `updated_at`, and the owner's update policy would let brokers edit it. Brokers get `select` on these tables at most.
- Closed vocabularies (operation type, property type, listing status) are Postgres enums or check constraints. Values are lowercase English identifiers (`rent`, `sale`, `apartment`); the UI maps them to Spanish.
- Mark columns that may hold personal data with a column comment starting `PII:`, e.g. `comment on column public.leads.note is 'PII: may contain end-client details'`. When you add such a column, also run the `privacy-review` skill on the change. Prefer not adding it at all: saved searches store requirements, never the client's name or phone.

### Row-Level Security
- Enable RLS in the same migration that creates the table: `alter table public.x enable row level security;`. A table without RLS is exposed through the Data API to every logged-in user.
- Write one policy per command (`select`, `insert`, `update`, `delete`) and target `to authenticated`.
- Supabase grants table privileges to `anon` by default. Add `revoke all on table public.x from anon;` so a missing policy can't expose data to logged-out requests. The scope has no public data today.
- Wrap auth calls in a subselect, `(select auth.uid())`, so Postgres evaluates them once per query instead of once per row.
- Verified-broker gate: posting and searching require an approved broker (scope §2). Use the helper `public.is_verified_broker()`, a `stable` `security definer` function with `set search_path = ''` that checks `public.brokers.verification_status = 'approved'` for `auth.uid()`. Create it in the first migration that needs it; don't copy its logic into every policy.
- Ownership (scope §4): `update` and `delete` on listings use `using (broker_id = (select auth.uid()))`, and `update` also has `with check (broker_id = (select auth.uid()))` so ownership can't be transferred.
- Visibility: other brokers see only `available` / `under_offer` listings. Owners also see their own `closed` and `archived` rows.
- Conversations and leads (scope §3.3, §3.5, §11): visible only to participants, via `exists (select 1 from public.thread_participants p where p.thread_id = <table>.thread_id and p.broker_id = (select auth.uid()))`.
- Storage buckets need their own policies on `storage.objects`. Listing photos: the owner writes under a `<broker_id>/<listing_id>/` prefix; verified brokers can read.

### Indexes
- Index every foreign key and every column used in a policy predicate. Policies run on every query, so a missing index here slows down everything.
- Embeddings: `create index ... using hnsw (embedding extensions.vector_cosine_ops);`. The vector dimension must match the configured Voyage model. Changing the embedding model means a new column plus an Inngest backfill job, never an in-place `alter`.
- Coordinates: `create index ... using gist (location);`.
- Common filters (operation, property type, status, colonia, price) usually get a composite B-tree index that matches the search query order.

### Functions and extensions
- Extensions go in the `extensions` schema: `create extension if not exists vector with schema extensions;` (the same for `postgis`).
- Functions are `security invoker` by default. When `security definer` is truly needed, set `set search_path = ''`, fully qualify every name, and `revoke execute ... from public` before granting to the roles that need it.

### Destructive changes
Dropping or renaming columns and tables, or narrowing types, breaks the API and web app while they still use the old shape. Use expand/contract: add the new column → backfill → switch the code → drop the old column in a later migration. Point this out explicitly in your summary.

## pgTAP test template

RLS updates by a non-owner don't raise errors; they silently affect zero rows. So tests switch back to the superuser and confirm the data is unchanged. Inserts that violate a policy do raise SQLSTATE `42501`.

Put one file per table in `supabase/tests/`, named `<table>_rls.test.sql`. The pgTAP extension must exist before the tests run; create it in the first test file (or in a `000_setup.test.sql`) with `create extension if not exists pgtap with schema extensions;`.

```sql
begin;
select plan(3);

-- Fixtures (run as the postgres superuser)
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'owner@test.mx'),
  ('00000000-0000-0000-0000-00000000000b', 'other@test.mx');
insert into public.brokers (id, verification_status) values
  ('00000000-0000-0000-0000-00000000000a', 'approved'),
  ('00000000-0000-0000-0000-00000000000b', 'approved');
insert into public.listings (id, broker_id, status, price_cents, currency /*, ...other required columns */) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000a', 'available', 2800000, 'MXN'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-00000000000a', 'archived',  3000000, 'MXN');

-- Act as the non-owner
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated"}';

select is(
  (select count(*)::int from public.listings where broker_id = '00000000-0000-0000-0000-00000000000a'),
  1,
  'non-owner sees the available listing but not the archived one'
);

update public.listings set price_cents = 1 where id = '00000000-0000-0000-0000-0000000000f1';

select throws_ok(
  $$ insert into public.listings (broker_id, price_cents, currency) values ('00000000-0000-0000-0000-00000000000a', 1, 'MXN') $$,
  '42501', null, 'cannot create a listing on behalf of another broker'
);

reset role;
select is(
  (select price_cents from public.listings where id = '00000000-0000-0000-0000-0000000000f1'),
  2800000::bigint,
  'non-owner update has no effect'
);

select * from finish();
rollback;
```

Cover at least:
- the owner can do what they should;
- a non-owner cannot;
- an unverified broker is blocked where the verification gate applies;
- for participant-scoped tables, a non-participant sees nothing.
