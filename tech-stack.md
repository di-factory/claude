# Grap-IA — Tech Stack

Approved technology choices for building Grap-IA as defined in [scope.md](scope.md). Each choice lists what it does in the system and why it was picked.

## 1. Architecture Overview

```
                ┌──────────────────────────────┐
  Broker ──────▶│  Web app (Next.js PWA)       │  Vercel
                └──────┬───────────────┬───────┘
                       │               │
        chat, auth,    │               │  agent messages, listing CRUD,
        realtime       │               │  search, matching
                       ▼               ▼
        ┌──────────────────┐   ┌───────────────────────────┐
        │ Supabase         │◀──│ API (Python FastAPI)      │  Google Cloud Run
        │ Postgres         │   │  - Grap-IA agent          │
        │  + pgvector      │   │    (Anthropic Tool Runner)│──▶ Claude API
        │  + PostGIS       │   │  - listings / search      │──▶ Voyage AI (embeddings)
        │ Auth · Storage   │   │  - matching               │──▶ Google Maps (geocoding)
        │ Realtime · RLS   │   └────────────┬──────────────┘
        └──────────────────┘                │ events
                ▲                           ▼
                │               ┌───────────────────────────┐
                └───────────────│ Background jobs (Inngest) │
                                │  embeddings, photo tags,  │
                                │  match detection, dupes   │
                                └───────────────────────────┘
```

- **Broker-to-broker chat** goes from the web app straight to Supabase (Realtime + Row-Level Security). No backend hop is needed.
- **Anything involving the Grap-IA agent or business logic** (creating and editing listings, search, demand, matching, connecting brokers) goes through the FastAPI service.
- **Slow or bulk work** (embeddings, photo tagging, match detection, duplicate detection) runs as Inngest background jobs so chat responses stay fast.

## 2. Frontend

| Choice | Role | Rationale |
|---|---|---|
| **Next.js (App Router), TypeScript** | Broker web app: chat UI, listing cards, photo galleries, lead lists, admin screens | Mature React framework with server rendering and a strong component ecosystem. |
| **Tailwind CSS + shadcn/ui** | Styling and UI components | Fast to build a polished, consistent chat UI. We own the component code. |
| **PWA (installable)** | Mobile experience | Brokers can install it on their phones without an app store. A native app (React Native/Expo, reusing TS code) can come later if needed. |
| **supabase-js** | Auth session, chat messages, realtime subscriptions | Direct, RLS-protected access for chat. TS types are generated from the database schema. |
| **Vercel** | Frontend hosting | Zero-config Next.js hosting with preview deployments per branch. |

## 3. Backend

| Choice | Role | Rationale |
|---|---|---|
| **Python + FastAPI** | API service: agent endpoint, listing CRUD, search, demand, matching, admin actions | Strong Python ecosystem for data and AI work. Pydantic gives typed request/response validation. |
| **Pydantic + SQLAlchemy 2** | Validation and database access | Typed models end to end. SQLAlchemy handles pgvector and PostGIS queries. |
| **Google Cloud Run** | API hosting | Autoscaling containers with long request timeouts that fit multi-step agent turns. Shares a Google Cloud account with Maps billing. Deployed in the region closest to the Supabase project. |
| **Inngest (Python SDK)** | Background jobs and event-driven workflows | Retries, scheduling and step functions without running our own queue. Used for embeddings, photo tagging, match detection and duplicate checks. |

## 4. Data Platform — Supabase

| Component | Role |
|---|---|
| **Postgres** | System of record: brokers, verification status, listings (structured fields from scope §5), listing status, demand/saved searches, leads, chat threads and messages, duplicate flags. |
| **pgvector** | Embeddings of listing descriptions (and demand text) for semantic search, next to the structured rows (scope §7). |
| **PostGIS** | Listing coordinates and colonia/city geometry for proximity and zone queries (scope §6). |
| **Auth** | Broker login (email/phone OTP). A custom `verification_status` (pending/approved/rejected) gates posting and searching until an admin approves (scope §2). |
| **Storage** | Listing photos (S3-compatible), with image transformations for thumbnails. |
| **Realtime** | Live broker-to-broker chat and in-app notifications. |
| **Row-Level Security** | Enforces owner-only listing edits (scope §4) and restricts chat and client-related data to the brokers involved (LFPDPPP, scope §11). |

**Schema management:** SQL migrations under `supabase/migrations`, run with the Supabase CLI, are the single source of truth for tables, indexes, RLS policies and extensions. The frontend's TypeScript types are generated from the schema. The backend's SQLAlchemy models mirror it.

**Scale:** a single Supabase Postgres instance fits the launch scale (scope §10). If semantic search outgrows pgvector, the retrieval layer can be moved to a dedicated vector database.

## 5. AI Layer

| Choice | Role | Rationale |
|---|---|---|
| **Anthropic Python SDK — Tool Runner** | The Grap-IA agent loop | The official SDK runs the tool-calling loop over our own typed tools. Our tools are plain DB/API calls, so no extra orchestration framework is needed. Per-turn hooks allow confirmations (e.g. "publish this listing?") and logging. |
| **Claude Opus 5** (`claude-opus-5`) | Broker-facing chat agent: NL listing extraction, follow-up questions, search-query understanding, tool use | Highest quality for Spanish natural-language extraction and reliable tool use. Cost is managed with prompt caching and the effort setting. |
| **Claude Haiku 4.5** (`claude-haiku-4-5`) | High-volume background jobs: photo room-type tagging (vision), duplicate-listing similarity checks | Lower cost for repetitive, well-defined tasks. |
| **Voyage AI (multilingual embeddings)** | Embeddings for listing descriptions and search queries | Anthropic's recommended embeddings partner (Anthropic offers no embeddings model), with strong Spanish retrieval quality. |

**Initial agent tools** (exact contracts to be defined during design):
- `create_listing` / `update_listing` / `set_listing_status` / `archive_listing`
- `search_listings` (structured filters + semantic query)
- `save_demand` (persistent saved search for proactive matching)
- `connect_brokers` (opens a broker-to-broker chat thread)
- `get_my_leads` (brokers interested in my listings)

**Retrieval flow:** the agent turns a broker's request into structured filters (SQL + PostGIS) plus a semantic query (Voyage embedding → pgvector similarity over the filtered candidates). It then ranks the results and presents them as listing cards.

**Pricing reference** (per 1M tokens, input / output): Opus 5 $5 / $25, Haiku 4.5 $1 / $5.

## 6. Geography

| Choice | Role |
|---|---|
| **Google Maps Platform** (Places Autocomplete + Geocoding) | Turns broker-provided addresses and zones into coordinates. Has the best address coverage in Mexico. |
| **SEPOMEX catalog** | Official Correos de México postal-code/colonia catalog, used as the structured city + colonia catalog. It covers every Mexican city, so multi-city expansion only needs data enabled, not new code. |
| **PostGIS** | Stores and queries coordinates and zone geometry (scope §6). |

## 7. Supporting Services

| Choice | Role | Notes |
|---|---|---|
| **Stripe Billing** | Per-broker subscriptions (scope §12) | Supports MXN, cards and OXXO, with a customer portal. CFDI invoicing (facturas) would need a separate Mexican provider later if required. |
| **Supabase Realtime** | In-app notifications (new matches, leads, chat messages) | v1 is **in-app only**, so brokers who aren't in the app see updates the next time they open it. Email and web push are the first candidate follow-ups. |
| **Sentry** | Error tracking for Next.js and FastAPI | |
| **Langfuse** | LLM tracing, prompt versions, token cost, and evals for the agent | Key to monitoring extraction quality and Claude spend. |
| **PostHog** | Product analytics and funnels (onboarding → listing created → match → chat) | |

## 8. Repository & Tooling

```
/
├── apps/
│   ├── web/          # Next.js PWA (TypeScript)
│   └── api/          # FastAPI service (Python)
├── supabase/
│   └── migrations/   # SQL schema, RLS policies, extensions
├── scope.md
└── tech-stack.md
```

| Area | TypeScript (web) | Python (api) |
|---|---|---|
| Package manager | pnpm | uv |
| Lint / format | ESLint + Prettier | ruff |
| Type checking | tsc | mypy |
| Tests | Vitest (unit), Playwright (end-to-end) | pytest |

- **CI:** GitHub Actions runs lint, type checks and tests for both apps, plus migration checks.
- **Deploy:** Vercel (web) and Cloud Run (api).
- **Secrets:** API keys (Anthropic, Voyage, Google Maps, Stripe, Supabase service role) live in each platform's secret manager and are never committed.

## 9. Compliance Notes (LFPDPPP)

- Supabase encrypts data at rest. Especially sensitive client-identifying fields get application-level column encryption on top of that.
- RLS policies restrict chat and lead data to the brokers directly involved.
- Retention and deletion jobs (Inngest scheduled functions) enforce the retention policy from scope §11.
- Prompts and extraction logic avoid persisting end-client PII beyond what matching needs.
- LLM traces in Langfuse must redact or minimize client PII.

## 10. Deferred / Future Options

- Email (Resend) and web push notifications for offline brokers.
- Native mobile app (React Native/Expo).
- CFDI invoicing provider alongside Stripe.
- A dedicated vector database if pgvector limits are reached.
- WhatsApp as an additional channel (out of scope for v1 per scope §8).
