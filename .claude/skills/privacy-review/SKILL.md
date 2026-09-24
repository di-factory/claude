---
name: privacy-review
description: Review grap-ia code changes or design proposals for personal-data handling under Mexico's data protection law (LFPDPPP) - end-client data brokers mention in chat, broker identity and verification documents, property-owner details, logging, Sentry, Langfuse LLM traces, PostHog analytics, embeddings, Inngest event/step history, third-party processors (Anthropic, Voyage, Google Maps, Stripe), retention and deletion. Use this whenever a change or idea stores, sends, logs, traces, embeds, exports or deletes data about a person, adds a new external service, touches chat/leads/demand/broker-verification code, or when the user asks "is this OK privacy-wise", "can we log this", or "what about LFPDPPP". Complements the built-in security-review; run both on data-related changes.
---

# Privacy review (LFPDPPP) for grap-ia

grap-ia treats personal data as regulated from day one (scope §11). The riskiest data isn't our users' data. It's data about **people who are not users**:

- the brokers' clients ("para mi cliente Juan, 55 1234 5678, gana 80 mil al mes");
- property owners ("el dueño es el Sr. Ramírez").

Those people never accepted our privacy notice, so we should collect as little as possible and keep it contained.

This skill produces an engineering review, not legal advice. In 2025 Mexico published a new LFPDPPP that replaced the 2010 law, and oversight moved away from the former regulator (INAI). When a finding depends on the exact legal requirement (legal basis or consent, notice wording, processor contracts, cross-border transfers), flag it **for counsel** instead of guessing.

**Division of labor with `security-review`:** this skill asks where personal data goes and whether it should. `security-review` asks whether an attacker can get to it (injection, authentication bugs). Some findings, like identity taken from the request body, belong to both. Report them here when they expose personal data.

## Two modes

- **Code review:** the input is a diff, a branch or files. Cite findings as `path/to/file.py:LINE`, using the line number in the new version of the file. For migrations, cite the SQL file.
- **Design review:** the input is an idea or proposal ("what if we embed all chats…"). Cite the part of the proposal each finding concerns, and add a **Safer alternative** for every blocker, so the answer is "no, but here's how".

If a question needs code that doesn't exist yet (e.g. "is retention covered?" when there's no retention job), say so as a finding rather than assuming either way.

## Data classes in grap-ia

| Class | Examples | Default handling |
|---|---|---|
| Broker account | name, email, phone, agency | Needed to run the product. Protected by RLS; minimal in logs (use the broker UUID, not the name or email). |
| Broker verification | AMPI/licence number, ID document images | Private storage bucket readable only by admins. Retention defined. Never sent to LLMs or analytics. |
| End-client data | client names, phones, emails, income/budget linked to a person, personal situation | Avoid storing. Only in chat messages between participating brokers. Never in listings, demand records, embeddings, analytics, logs, event/step history, or unmasked traces. |
| Property-owner data | owner name/phone, exact unit number when not public | Treat like end-client data. |
| Sensitive data | health, religion, ethnicity, sexual orientation, etc. | Must not be collected or extracted. If a broker mentions it, don't store it in structured fields. |
| Listing data | price, m², colonia, amenities, photos | Not personal by itself. Watch for faces, documents or license plates in photos, and for owner details in descriptions. |
| Demand (saved search) | operation, budget, colonias, bedrooms | Not personal as long as it stores requirements only. Can be embedded only as text generated from its structured fields, never the broker's raw message. |

## Review checklist

Go through the change with these questions. Only report findings that apply.

**1. Collection and minimization**
- Does the change collect a new personal field? Is it actually needed for the feature, and did scope.md or the user decide it?
- Do extraction prompts, tool schemas and API models avoid pulling client identity into structured records? A `body: dict` that gets persisted accepts anything, so require typed request models.
- Are columns that can hold personal data marked with a `PII:` column comment (the `supabase-migration` convention)?

**2. Storage and access**
- RLS: is personal data readable only by the participants (chat, leads) or the owner (own profile, own saved searches)? Is admin access limited to specific roles?
- Is identity taken from the session, never from request bodies or LLM output?
- Is especially sensitive client-identifying data encrypted at the application level on top of Supabase's at-rest encryption? Are the keys outside the database and the repo?
- Storage buckets: are verification documents and photos in the right bucket with the right policies? Are files served through signed URLs rather than public URLs?

**3. Third parties (processors)**
- What personal data now goes to Anthropic, Voyage, Google Maps, Stripe, Inngest, Sentry, Langfuse or PostHog? Send the minimum, e.g.:
  - Google Maps gets an address, not the owner's name;
  - Voyage embeds listing descriptions or generated demand text, never chat transcripts or raw broker messages.
- Is this a **new** processor or a new data category for an existing one? Then it needs an entry in the processor inventory and privacy notice, and a data-processing agreement. Flag it **for counsel**.
- Cross-border: Supabase, Cloud Run, Anthropic and others process data outside Mexico. A new flow means the transfer disclosures need an update. Flag it **for counsel**.
- Is the data used for a new purpose (e.g. analytics or model improvement on chat content)? That's a purpose change: a blocker until counsel confirms it's covered.

**4. Observability and job history**
- **Logs:** no message bodies, request bodies, names, phones or emails. Log IDs and event types.
- **Sentry (Python):** `send_default_pii=False` **and** `include_local_variables=False`, or a `before_send` that scrubs frame locals, since stack traces otherwise capture local variables such as request bodies. **Sentry (JS):** no `sendDefaultPii`, and breadcrumbs don't capture message text.
- **Langfuse:** agent traces contain chat text by nature. Production traces must be masked before export. Unmasked client contact data in production traces is a **blocker**. Trace retention must match the data retention policy.
- **PostHog:** event properties hold IDs, enums and bucketed numbers only, never message text or contact data. Session replay (if ever enabled) masks all inputs.
- **Inngest:** event payloads and step return values are stored in run history. Both must hold IDs and statuses, not personal data.

**Masking approach** (for traces, embeddings, anything derived from free text):
- **Structured data:** don't extract identities in the first place.
- **Free text:** regex-mask Mexican phone numbers (10 digits, optional `+52`/`52`/`044`/`045` prefix, spaces or dashes between groups) and emails, and replace them with `[TEL]` / `[EMAIL]`.
- **Names can't be caught reliably with regex.** Where names matter (trace export, anything embedded), run a small redaction pass with `claude-haiku-4-5`, or avoid exporting that text at all.
- Treat masking as defense in depth, not permission to store raw text.

**5. Retention, deletion and data-subject rights (ARCO)**
- Does the new data have a defined retention period, and is it covered by the scheduled cleanup job? The retention schedule lives in `docs/retention.md`. If that file doesn't exist yet or doesn't cover this data, report it as **Should fix** (and **for counsel** for the periods themselves). Don't invent periods.
- When a broker deletes a conversation or account, or a data subject asks for deletion, do the cascades reach everything? That includes rows, storage objects, embeddings, search indexes, and traces or analytics where feasible.
- Could we find all data about a given person for an access (acceso) or deletion (cancelación) request? New storage locations must be searchable by the relevant identifiers. Anonymous vectors derived from personal text fail this test.

**6. LLM-specific risks**
- Could the agent echo one broker's client data to another broker? For example, a search result that includes another broker's lead note, retrieval over other brokers' chats, or a tool result with contact details.
- Could prompt injection in a listing description (written by another broker) make the agent reveal data or call a tool on someone's behalf? Tool authorization must come from `AgentContext`, not the conversation.

## Output format

```
## Privacy review: <change or proposal name>

**Mode:** code | design
**Data touched:** <data classes and where they flow>

### Blockers
- <path:line or proposal part> — <what's wrong> → <concrete fix>
  (design mode) **Safer alternative:** <what to do instead>

### Should fix
- <path:line or proposal part> — <issue> → <fix>

### For counsel
- <question that depends on the legal requirement, with the relevant facts>

### OK
- <short list of the checks that passed, so reviewers know they were considered>
```

- A **blocker** is personal data that is:
  - exposed to someone who shouldn't see it;
  - sent to a processor that doesn't need it, or used for a new purpose;
  - stored unmasked in logs, traces, analytics or job history;
  - stored somewhere it can't be found or deleted.
- Empty sections are fine. Don't invent findings to fill them.
