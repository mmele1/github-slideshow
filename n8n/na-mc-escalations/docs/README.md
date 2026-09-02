# NA Multi-Contact Escalation Insights — n8n workflow

Answers four questions for the NA Multi-Contact (MC) / CARE escalation team over
a trailing window (default 90 days):

1. **What kinds of escalations are coming in most?** — full wrap-coded population
2. **What journey are they?** — journey mix by volume, resolution rate and trend
3. **What are customers asking for?** — extracted from Level AI phone transcripts
4. **What are agents providing?** — and where the ask-vs-resolution gap sits

Output: an HTML email to the recipients on the form, plus two CSVs (full
escalation detail, per-call classifications).

---

## Files

| File | What it is |
|---|---|
| `NA_MC_Escalation_Insights.workflow.json` | Import this into n8n |
| `sql/00_discovery_labels.sql` | **Run first.** Confirms the literal strings the analysis depends on |
| `sql/10_escalation_detail.sql` | Readable copy of the quantitative query (workflow generates the same SQL) |
| `sql/20_escalation_transcript_sample.sql` | Readable copy of the transcript-sample query |
| `prompts/escalation_extraction.md` | Canonical copy of the extraction prompt + JSON output schema |

---

## Workflow shape

```
Escalation Insight Request (Form)
  → Normalize Request                  (validation + every default lives here)
  → Build Escalation SQL               (inlines literals into both queries)
  → GBQ: Escalation Detail             (one row per escalated contact)
  → Summarize Escalations              (volume, journey mix, queue, trend)
  → IF: Analyze Transcripts?
      ├─ yes → GBQ: Transcript Sample  (journey-stratified Level AI phone sample)
      │        → Batch Transcripts     (5 calls per LLM call)
      │        → Build Claude Request  (structured-output request)
      │        → Claude: Classify      (HTTP Request → Messages API)
      │        → Parse Classifications (validates; per-batch failures recorded)
      │        → Roll Up Insights      (triggers, asks, responses, cross-tab)
      │        → Build Report
      └─ no  → Build Report            (volume-only report)
  → Gmail: Send Insight Report
```

`GBQ: Persist Classifications (optional)` is included but **disabled** — enable it
to trend escalation drivers month over month.

---

## Setup (about 30 minutes)

### 1. Run the discovery SQL — do not skip

`sql/00_discovery_labels.sql` has four blocks. Each one confirms a string this
workflow filters on. Paste the real values into the `config` block of the
**Normalize Request** node:

| Block | Confirms | Config field |
|---|---|---|
| 1 | Escalation wrap Detailed Reason values | `escalationDetailPatterns` |
| 2 | Genesys queue names for MC / CARE | `queuePatterns` |
| 3 | How the NA MC team is labelled on the roster | `rosterTeamPatterns` |
| 4 | Level AI transcript coverage | sanity check on sample size |

If block 1 returns nothing, the escalation wrap convention in the SOP is not
landing in the wrap PDT the way the SOP describes — stop and resolve that before
running anything else, because the whole population definition rests on it.

### 2. Import and wire credentials

Import the JSON, then replace the three credential placeholders in the n8n UI:

| Node | Credential type | Notes |
|---|---|---|
| `GBQ: Escalation Detail`, `GBQ: Transcript Sample` | Google BigQuery (service account) | Needs `bigquery.jobs.create` in the billing project plus read on all five source tables (below) |
| `Claude: Classify Escalations` | Header Auth | Header name `x-api-key`, value = Claude API key |
| `Gmail: Send Insight Report` | Gmail OAuth2 | Sender must be allowed to email the recipients |

The BigQuery node bills to `wf-gcp-us-ae-gat-prod`. Change `projectId` on both
GBQ nodes if your service account bills elsewhere.

### 3. Validate the transcript join once

Run the commented VALIDATION block at the bottom of
`sql/20_escalation_transcript_sample.sql`. It proves that
`lai_pipeline_data.asr_log_id` shares an id space with the Level AI ASR log. If it
returns 0 rows, change the `transcripts` CTE to join through
`post_order_level_ai_import.level_phone_asrlog` on `provider_conversation_id`
instead. This is assumption **A5** below.

### 4. First run: keep it small

Submit the form with `Transcripts Per Journey = 2` and `Max Transcripts Total = 10`.
Check the email, then raise to the defaults (8 / 120).

---

## Source tables

All five are existing production tables — nothing new is created.

| Purpose | Table |
|---|---|
| Escalation wraps: journey, detail reason, resolution flag | `wf-gcp-us-service-data-prod.omnichannel_public.tbl_service_contact_wrap` |
| MC roster, manager, team, site | `wf-gcp-us-ae-gat-prod.ops_reporting_core.tbl_snapshot_dim_employee` |
| Genesys queue per contact | `wf-gcp-us-ae-gat-prod.ops_reporting.tbl_datamart_service_performance_metrics` |
| Contact → Level AI conversation + ASR log id | `wf-gcp-us-ae-cs-prod.gsat_reporting.lai_pipeline_data` |
| Phone transcript utterances | `wf-gcp-us-cust-conv-proc-prod.post_order_level_ai_import.conversation_speaker_utterances` |

Level AI review link pattern:
`https://wayfair.thelevel.ai/organizations/2/conversations/review/{banking_conversation_id}`

---

## How the population is defined

An "escalation handled by NA Multi-Contact" is:

> a **wrap** whose **Detailed Reason** matches an escalation marker
> (`escalated by agent`, `escalation resolved by supervisor`,
> `escalation transferred to tier…`), submitted by an agent on the **NA MC / SpS
> roster**, on a contact whose Genesys queue is MC or CARE (or has no queue
> mapping).

**Journey** is the wrap **Primary Reason** — the SOP instructs MC agents to select
"the customer journey that best represents why the customer escalated," which makes
Primary Reason the authoritative journey field rather than a derived one.

The transcript classification returns a second journey read (`journey_observed`)
from the call itself. Where the two disagree at scale, that is a wrap-coding
finding, not a modelling error — the CSV carries both columns so you can quantify it.

---

## Verified vs. assumed

**Verified against internal documentation** (Confluence SOPs, the Level AI /
Waycomm runbooks, DataHub column pages, and the existing *Manager Wrap Compliance
Report* n8n workflow this one reuses the pattern from):

- The five table names above, and the columns each query selects
- Escalation wrap convention: Primary Reason = journey, Detailed Reason =
  "Escalated by Agent"; outcome codes for supervisor-resolved and Tier II
- MC vs. CARE queue split, MC operating hours 8am–10pm ET, 3+ contact routing rule
- `lai_pipeline_data` fields (`ContactID`, `asr_log_id`, `banking_conversation_id`)
  and the Level AI review URL pattern
- The phone transcript join: `level_phone_asrlog` ↔ `conversation_speaker_utterances`
  on `asr_log_id`

**Assumptions that need one confirming query each** (all flagged in code):

| # | Assumption | How to confirm | If wrong |
|---|---|---|---|
| A1 | The escalation marker appears in `wrap_reason_detail` with the SOP wording | Block 1 | Update `escalationDetailPatterns` |
| A2 | NA MC agents are identifiable by `employee_working_team` / `employee_workgroup_name` | Block 3 | Update `rosterTeamPatterns`, or switch to a manager-based roster |
| A3 | `wrap_compliance_contact_id` joins to `customer_contact_id` | Compare a day of both | Queue split degrades to "Other / Unmapped"; volume and journey mix are unaffected |
| A4 | `wrap_datetime` is a TIMESTAMP | Check the schema | One-line swap to `DATETIME_SUB` (noted inline in both SQL files) |
| A5 | `lai_pipeline_data.asr_log_id` = Level AI ASR log id | VALIDATION block in `20_…sql` | Join through `level_phone_asrlog` instead |
| A6 | Nested field names inside the `wrap_compliance` array carry the `wrap_compliance_` prefix | Block 2b | Adjust the `queue_ctx` CTE |

**Not claimed:** no query in this repo has been executed. I have no BigQuery,
Level AI, or Genesys access from this session, so there are no real numbers here —
only the pipeline that will produce them.

---

## Known limits — state these in any readout

1. **Phone only.** Chat, email and SMS escalations are counted in the volume
   sections but not analyzed qualitatively. Level AI holds digital transcripts in
   `tbl_service_level_ai_{chat,email,sms}_transcript` — a follow-on branch could
   add them.
2. **The transcript sample is stratified, not proportional.** N per journey means
   small journeys are over-represented on purpose (so you get signal on them).
   Never quote sections 4–9 as volume shares; use section 2 for that.
3. **Escalations wrapped with a different Detailed Reason are invisible** to this
   method. The report prints the unclassified-journey share so you can see how much
   coding noise you are carrying.
4. **`is_customer_issue_resolved` is agent-asserted**, not verified against
   follow-on contacts. Treat "resolved in contact" as a claim, not an outcome. A
   true one-and-done rate needs a follow-on-contact join.
5. **ASR quality bounds everything qualitative.** The prompt tells the model to
   judge on meaning, and each classification carries a `confidence`; the report
   surfaces the count below 0.5.
6. **Automated wraps** are included and reported as a share — an automated wrap
   reflects what the system inferred, not what the agent selected.

---

## Cost and governance

**BigQuery.** The utterance scan is the only expensive part, and it is bounded by
the `IN (SELECT asr_log_id FROM sampled)` predicate — do not remove it. At the
defaults, a run reads a bounded slice of the wrap PDT plus ≤120 transcripts.

**Claude API.** At the defaults: ~120 transcripts ÷ 5 per call ≈ 24 requests,
roughly 3–4K input tokens each. Model `claude-opus-5` with adaptive thinking and
structured output. The system prompt is cached (`cache_control: ephemeral`), so
repeat runs on the same day pay less. Raise `Transcripts Per Journey` only when
you need more resolution on a specific journey.

**Data handling.** Transcripts are customer conversations. The prompt requires
[REDACTED] in place of names, addresses, phone numbers, emails, order numbers and
payment details in every free-text field and quote, and quotes are capped at 200
characters. The CSVs do contain contact IDs, order numbers and MC agent names —
they are internal-only; send them to the MC leadership distribution, not wider.
Before enabling the Claude node, confirm the endpoint you use is an approved path
for customer conversation content. **This is the one open item I could not close
from here** — see below.

**LLM endpoint options.** The workflow ships pointed at
`https://api.anthropic.com/v1/messages` with header auth. If Wayfair's approved
path for this data is Claude on Vertex AI (same GCP org as every table here),
change the `Claude: Classify Escalations` node to:

- URL: `https://{region}-aiplatform.googleapis.com/v1/projects/{project}/locations/{region}/publishers/anthropic/models/claude-opus-5:rawPredict`
- Auth: the same Google credential as the BigQuery nodes
- Body: drop `model`, add `"anthropic_version": "vertex-2023-10-16"` — everything
  else in the request body is identical (structured outputs are supported on Vertex)

**Agent-level data.** The report includes a top-15 agent volume table. That is
volume, not quality — escalation count reflects queue routing, not performance.
Delete that block from `Summarize Escalations` if you would rather it not travel.

---

## Open items for you

1. **Approve the LLM path** for customer transcript content (Anthropic API vs.
   Vertex AI in-org). Blocks the qualitative half only; the volume half runs today.
2. **Confirm the CARE queue name** — I have "US Multi Contact" and "Perigold CARE
   Escalations" documented, but not the exact NA CARE escalation queue string.
   Block 2 returns it.
3. **Decide the cadence.** Built as on-demand (form). For a standing weekly or
   monthly readout, swap the Form Trigger for a Schedule Trigger plus a Set node
   supplying the same field names — no other change needed.
