# Grap-IA — Product & Technical Scope

## 1. Overview

Grap-IA is an agent-based chat product for the PropTech sector, supporting **real estate brokers** in Mexico City (CDMX) to trade rental and sale properties. Brokers interact with an AI agent (grap-ia) and with each other through chat. End clients (the broker's own customers) are **not** users of the platform — only real estate brokers are.

The two core interaction loops are:
1. **Supply**: a broker adds a property to grap-ia's database using natural language (plus photos).
2. **Demand**: a broker asks grap-ia for properties matching a client's needs, and grap-ia surfaces matches — including connecting the broker directly with the listing owner via in-app chat.

CDMX is the launch market. The data model (particularly geography) must be designed so expansion to other Mexican cities does not require rework.

## 2. Users

- **Sole user type**: real estate brokers. No end-client accounts.
- **Onboarding**: verified onboarding only. A broker must submit identifying/license information (e.g. AMPI registration or equivalent local credential) and be approved before they can post listings or query the database. This requires an admin review flow (manual or semi-automated) as part of the product.
- Out of scope for now: agency/team-level accounts — ownership is modeled per individual broker (see §4).

## 3. Core Interactions

### 3.1 Adding a property (supply)
A broker describes a property in natural language via chat, e.g.:
> "I want to add a rent property, it's an apartment with 100m², 2 bedrooms, in Roma Norte, $25,000/month..."

Grap-ia extracts structured fields from the message (see §5), asks follow-up questions for missing mandatory fields, and accepts photo uploads attached to the listing. The broker confirms before the listing is published.

### 3.2 Searching for a property (demand)
A broker describes what their client needs in natural language, e.g.:
> "I need a 2-bedroom apartment for rent in Roma Norte or Condesa, budget up to $30,000."

Grap-ia returns matching listings (structured filtering + semantic search over descriptions, see §7) and, for listings that look like a strong match, offers to connect the requesting broker with the listing owner.

### 3.3 Broker-to-broker chat
Once grap-ia matches a demand to a listing, it opens a **direct chat thread between the two brokers inside the product** (not just a contact-info handoff). This keeps discovery → connection → negotiation in one place. Grap-ia is not necessarily present in that thread as a participant, but the thread lives within the platform.

### 3.4 Proactive matching
Grap-ia stores open demand requests (saved searches) per broker. When a new or updated listing matches an open demand, the requesting broker is **proactively notified**. Symmetrically, when a broker posts demand that matches an existing listing, the listing owner is notified of the interested party. This requires:
- Persistent storage of demand/saved-search requests.
- A notification system (in-app at minimum; push/email as a later enhancement).

### 3.5 Visibility of interest
The listing owner can see which brokers have asked about or matched their property (a lead list). Interested brokers do not see each other unless/until a chat thread connects them directly.

## 4. Listing Ownership & Lifecycle

- **CRUD**: only the broker who created a listing (or an admin) can update or delete it.
- **Status**: a listing owner can mark a property's status — `available`, `under_offer`, `closed` — so it drops out of active search results without being deleted. This is the extent of deal-lifecycle tracking in this scope (see §9).
- **Deactivation**: if a broker deactivates their account, their listings are automatically **archived** (hidden from search, not deleted), preserving history and avoiding orphaned/stale data.
- **Duplicate listings**: when two brokers list what appears to be the same property (similarity on address/zone/price/description), grap-ia **flags it as a possible duplicate** for review (to an admin and/or both brokers) rather than auto-merging or blocking creation outright. This keeps human judgment in the loop for legitimate co-listings vs. true duplicates.

## 5. Property Data Model

Structured/mandatory fields for every listing:
- Operation type: rent or sale
- Property type: apartment, house, office, land, etc.
- Price + currency
- Zone / colonia (see §6 for geo model)
- m² built
- Bedrooms
- Bathrooms

Optional / best-effort fields, extracted from natural language where possible: parking spaces, furnished status, pet-friendly, amenities, building age, land size, availability date, exclusivity, and other free-text description content.

Photos:
- Standard upload flow, stored in object storage (S3-class), linked to the listing record (not embedded in the vector store).
- A vision model auto-tags room type (kitchen, bedroom, bathroom, facade, etc.) to enrich search/display; the broker can reorder or add captions manually.

## 6. Geography Model (multi-city readiness)

To support expansion beyond CDMX without a future data migration:
- **City** and **colonia/neighborhood** are stored as structured, cataloged fields (not free text) — the catalog is initially populated for CDMX but is extensible to other cities.
- **Latitude/longitude** are captured at listing creation (via geocoding the address/zone), enabling proximity search and precise city/zone boundaries from day one, even though only CDMX is live at launch.

## 7. Data Architecture

**Recommendation: hybrid structured + vector store, not a pure vector database.**

- **Structured store (relational, e.g. Postgres)**: holds all hard-filterable fields from §5 — price, m², bedrooms, bathrooms, operation type, property type, zone/city, coordinates, status, ownership, timestamps. This is what powers precise filtering ("2BR under $25k in Roma Norte") and standard CRUD.
- **Vector embeddings (e.g. pgvector alongside the same Postgres instance)**: the free-text description (and any additional natural-language color from the broker) is embedded and stored for semantic search — handling fuzzy/natural queries ("bright apartment near a park, pet-friendly building") that don't map cleanly to structured filters.
- **Photos**: stored in object storage, referenced by URL/metadata from the structured record; vision-model tags (see §5) are stored as structured attributes, not raw embeddings.
- **Retrieval flow**: a broker's natural-language query is parsed into (a) structured filters where confidently extractable, and (b) a residual semantic query embedded and matched via vector similarity against candidate listings (typically pre-filtered by the structured side for efficiency). This is a **RAG-style retrieval layer over a structured core**, not a vector-only database.
- **CRUD**: since core fields are relational rows, standard create/update/delete/soft-delete semantics apply directly; the corresponding embedding is regenerated on any description update.

This is expected to comfortably support the anticipated launch scale (§10) on a single Postgres+pgvector instance, with a documented path to a dedicated vector database (e.g. Pinecone, Weaviate) if semantic search volume outgrows it.

## 8. Channel & Language

- **Channel**: a custom web (and later mobile) chat interface built for grap-ia, giving full control over UX — structured listing cards, photo galleries, notifications, broker-to-broker threads. WhatsApp or other channels may be considered post-launch but are out of scope for v1.
- **Language**: Spanish-first. Architecture should not preclude adding English later, but no bilingual NLU work is in scope for v1.

## 9. Deal Lifecycle Scope

In scope: listing CRUD, search/matching, broker-to-broker chat, and status tracking (`available` / `under_offer` / `closed`).

Out of scope for this version: commission split agreements between co-brokers, contract generation/e-signature, and payment handling. These may be considered in a future phase once the discovery/matching product has traction.

## 10. Expected Scale (launch)

Architecture is sized for a **small launch scale**: low hundreds of brokers and low thousands of listings in CDMX, growing gradually. This comfortably fits a single Postgres+pgvector instance without need for a dedicated vector database or heavy distributed infrastructure at launch.

## 11. Data Privacy & Compliance

Brokers will frequently mention their end-clients' personal data in chat (name, phone number, budget, preferences) even though clients are not platform users. This data is treated as **regulated personal data under Mexico's LFPDPPP** from day one:
- Encryption at rest for chat content and extracted client-identifying fields.
- Access limited to the brokers directly involved in a given conversation/lead.
- A defined retention/deletion policy for chat and lead data.
- Extraction/storage logic should avoid persisting client PII beyond what's needed for the matching/lead use case.

## 12. Monetization (assumption for scope purposes)

**Subscription per broker** (flat monthly/annual fee for access to post and search) is assumed as the working business model for this scope document. It is independent of deal outcomes, which are not reliably trackable given the deal-lifecycle boundary in §9. This is a starting assumption, not a finalized pricing decision.

## 13. Out of Scope (v1)

- End-client-facing product or accounts.
- Agency/team-level listing ownership.
- Full deal lifecycle: commissions, contracts, payments.
- Non-CDMX city catalogs (though the data model supports adding them).
- Channels other than the custom web/app chat (e.g. WhatsApp).
- English-language support.

## 14. Open Items for Future Phases

- Formal LFPDPPP documentation (privacy notices, data processing agreements) beyond the technical safeguards in §11.
- Migration trigger/path from Postgres+pgvector to a dedicated vector database if scale exceeds §10 assumptions.
- Agency-level accounts, if broker feedback shows individual-only ownership is a blocker.
- Multi-city catalog rollout plan and prioritization (which city after CDMX).
