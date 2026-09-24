---
name: privacy-review
description: Review grap-ia changes for personal-data handling under Mexico's data protection law (LFPDPPP) - end-client data brokers mention in chat, broker identity and verification documents, property-owner details, logging, Sentry, Langfuse LLM traces, PostHog analytics, embeddings, third-party processors (Anthropic, Voyage, Google Maps, Stripe), retention and deletion. Use this whenever a change stores, sends, logs, traces, embeds, exports or deletes data about a person, adds a new external service, touches chat/leads/demand/broker-verification code, or when the user asks "is this OK privacy-wise", "can we log this", or "what about LFPDPPP". Complements the built-in security-review; run both on data-related changes.
---

# Privacy review (LFPDPPP) for grap-ia

grap-ia treats personal data as regulated from day one (scope §11). The riskiest data isn't our users' data. It's data about **people who are not users**:

- the brokers' clients ("para mi cliente Juan, 55 1234 5678, gana 80 mil al mes");
- property owners ("el dueño es el Sr. Ramírez").

Those people never accepted our privacy notice, so we should collect as little as possible and keep it contained.

This skill produces an engineering review, not legal advice. Mexico replaced its LFPDPPP with a new law in 2025, and the supervising authority changed with it. When a finding depends on the exact legal requirement (consent basis, notice wording, cross-border transfer terms), flag it **for counsel** instead of guessing.

## Data classes in grap-ia

| Class | Examples | Default handling |
|---|---|---|
| Broker account | name, email, phone, agency | Needed to run the product. Protected by RLS; minimal in logs (use the broker UUID, not the name). |
| Broker verification | AMPI/licence number, ID document images | Private storage bucket readable only by admins. Retention defined. Never sent to LLMs or analytics. |
| End-client data | client names, phones, emails, income/budget linked to a person, personal situation | Avoid storing. Only in chat messages between participating brokers. Never in listings, demand records, embeddings, analytics or traces. |
| Property-owner data | owner name/phone, exact unit number when not public | Treat like end-client data. |
| Sensitive data | health, religion, ethnicity, sexual orientation, etc. | Must not be collected or extracted. If a broker mentions it, don't store it in structured fields. |
| Listing data | price, m², colonia, amenities, photos | Not personal by itself. Watch for faces, documents or license plates in photos, and for owner details in descriptions. |

## Review checklist

Go through the diff (and related code paths) with these questions. Only report findings that apply.

**1. Collection and minimization**
- Does the change collect a new personal field? Is it actually needed for the feature, and did scope.md or the user decide it?
- Do extraction prompts and tool schemas avoid pulling client identity into structured records? Demand stores requirements, not people.
- Are columns that can hold personal data marked with a `PII:` column comment (the `supabase-migration` convention)?

**2. Storage and access**
- RLS: is personal data readable only by the participants (chat, leads) or the owner (own profile)? Is admin access limited to specific roles?
- Is especially sensitive client-identifying data encrypted at the application level on top of Supabase's at-rest encryption? Are the keys outside the database and the repo?
- Storage buckets: are verification documents and photos in the right bucket with the right policies? Are files served through signed URLs rather than public URLs?

**3. Third parties (processors)**
- What personal data now goes to Anthropic, Voyage, Google Maps, Stripe, Inngest, Sentry, Langfuse or PostHog? Send the minimum, e.g.:
  - Google Maps gets an address, not the owner's name;
  - Voyage embeds listing descriptions, never chat transcripts.
- Is this a **new** processor or a new data category for an existing one? Then it needs an entry in the processor inventory and privacy notice, and a data-processing agreement. Flag it **for counsel**.
- Cross-border: Supabase, Cloud Run, Anthropic and others process data outside Mexico. A new flow means the transfer disclosures need an update. Flag it **for counsel**.

**4. Observability**
- Logs: no message bodies, names, phones or emails. Log IDs and event types.
- Sentry: `send_default_pii=False` (Python) / no PII in `sendDefaultPii` (JS). Request bodies with chat content are scrubbed. Breadcrumbs don't capture message text.
- Langfuse: agent traces contain chat text by nature. Is masking/redaction applied to phone numbers, emails and names before export? Does trace retention match the data retention policy?
- PostHog: event properties hold IDs and enums only, never message text, prices tied to a named client, or contact data. Session replay (if ever enabled) masks all inputs.

**5. Retention, deletion and data-subject rights (ARCO)**
- Does the new data have a defined retention period, and is it covered by the scheduled cleanup job?
- When a broker deletes a conversation or account, or a data subject asks for deletion, do the cascades reach everything? That includes rows, storage objects, embeddings, search indexes, and traces or analytics where feasible.
- Could we find all data about a given person for an access (acceso) or deletion (cancelación) request? New storage locations must be searchable by the relevant identifiers.

**6. LLM-specific risks**
- Could the agent echo one broker's client data to another broker? For example, a search result that includes another broker's lead note, or a tool result with contact details.
- Could prompt injection in a listing description (written by another broker) make the agent reveal data or call a tool on someone's behalf? Tool authorization must come from `AgentContext`, not the conversation.

## Output format

Report the review in this structure:

```
## Privacy review: <change name>

**Data touched:** <data classes and where they flow>

### Blockers
- <file:line> — <what's wrong> → <concrete fix>

### Should fix
- <file:line> — <issue> → <fix>

### For counsel
- <question that depends on the legal requirement, with the relevant facts>

### OK
- <short list of the checks that passed, so reviewers know they were considered>
```

- A **blocker** is personal data exposed to someone who shouldn't see it, sent to a processor that doesn't need it, or stored where it can't be deleted.
- Empty sections are fine. Don't invent findings to fill them.
