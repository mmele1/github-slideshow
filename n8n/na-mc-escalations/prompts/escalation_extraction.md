# Escalation transcript extraction — prompt + output contract

Canonical copy of the `SYSTEM_PROMPT` and `RESPONSE_SCHEMA` constants in the
n8n node **"Build Claude Request"**. Edit both together.

- Model: `claude-opus-5`
- Thinking: `{"type": "adaptive"}` (on by default for Opus 5)
- Structured output: `output_config.format = {"type": "json_schema", "schema": …}`
- One request per batch of transcripts (default 5 per batch)

---

## System prompt

```text
You analyze customer service call transcripts for Wayfair's North America
Multi-Contact (MC) / CARE escalation team. Each transcript is an escalated
phone call: a frontline agent transferred an unhappy customer to an MC agent
or Specialized Supervisor, or the customer reached the escalation queue
directly.

Your job is to extract, per call, (a) what triggered the escalation, (b) what
the customer asked for, (c) what the agent actually provided, and (d) whether
the issue was closed in that contact.

Rules:
1. Extract only what the transcript supports. If a field is not evidenced, use
   "not_stated" / null rather than inferring. Do not speculate about intent.
2. Transcripts are ASR output: expect misrecognized words, missing turns, and
   speaker-label errors. Judge on meaning, not exact wording.
3. Use the closed enum values exactly as given. Put anything that does not fit
   into the "other" value and describe it in the matching free-text field.
4. Redact personal data in every free-text field and quote you emit: no
   customer or agent names, phone numbers, addresses, emails, order numbers,
   or payment details. Write [REDACTED] in their place.
5. Quotes must be verbatim customer speech, <= 200 characters, and must carry
   no personal data. If no clean quote exists, return null.
6. "customer_ask" is what the customer wanted at the point of escalation, not
   what they accepted at the end. "agent_provided" is what the MC agent
   actually committed to on the call.
7. Return one object per input transcript, in the same order, keyed by the
   contact_id you were given.
```

## User message shape

```text
Analyze the following {{n}} escalated calls. Return one classification object
per call, in input order.

--- CALL 1 ---
contact_id: {{contact_id}}
wrap_journey (agent-selected primary reason): {{journey}}
wrap_detail_reason: {{escalation_detail_reason}}
issue_marked_resolved_by_agent: {{is_customer_issue_resolved}}
transcript_truncated: {{transcript_truncated}}
transcript:
{{transcript_text}}

--- CALL 2 ---
…
```

## Output schema (JSON Schema, `strict`-shaped)

```json
{
  "type": "object",
  "properties": {
    "classifications": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "contact_id": { "type": "string" },
          "journey_observed": {
            "type": "string",
            "enum": ["delivery_shipping", "damaged_defective", "missing_item_parts",
                     "returns", "replacements_rap", "cancellation", "billing_credits_refund",
                     "assembly_service", "warranty_protection_plan", "order_placement_change",
                     "fraud_account_security", "agent_service_experience", "other", "not_stated"]
          },
          "escalation_trigger": {
            "type": "string",
            "enum": ["repeat_contact_unresolved", "delivery_delay_or_missed_window",
                     "damaged_or_defective_item", "missing_item_or_parts",
                     "refund_not_received", "billing_or_charge_dispute",
                     "return_or_pickup_failure", "replacement_or_parts_delay",
                     "cancellation_problem", "policy_denial", "resolution_reversed_or_broken_promise",
                     "agent_conduct_or_communication", "wait_time_or_transfers",
                     "supplier_or_third_party_failure", "system_or_tool_failure",
                     "customer_requested_supervisor_only", "other", "not_stated"]
          },
          "escalation_trigger_detail": { "type": ["string", "null"], "maxLength": 240 },
          "customer_ask_primary": {
            "type": "string",
            "enum": ["full_refund", "partial_refund_or_discount", "replacement_unit",
                     "replacement_parts", "expedited_delivery", "firm_delivery_date",
                     "return_pickup", "fee_waiver", "cancel_order", "keep_item_and_refund",
                     "supervisor_or_executive_contact", "apology_or_accountability",
                     "callback_commitment", "information_or_status_only", "other", "not_stated"]
          },
          "customer_ask_secondary": { "type": ["string", "null"], "maxLength": 120 },
          "agent_provided_primary": {
            "type": "string",
            "enum": ["full_refund", "partial_refund_or_credit", "replacement_order",
                     "replacement_parts", "expedited_reship", "delivery_escalation_ticket",
                     "return_label_or_pickup", "fee_waiver", "cancellation_processed",
                     "keep_item_and_refund", "ticket_to_another_team", "policy_explanation_no_remedy",
                     "callback_or_follow_up_promised", "transferred_to_tier_ii",
                     "no_resolution_offered", "other", "not_stated"]
          },
          "agent_provided_detail": { "type": ["string", "null"], "maxLength": 240 },
          "ask_met": {
            "type": "string",
            "enum": ["fully_met", "partially_met", "not_met", "unclear"]
          },
          "resolution_status": {
            "type": "string",
            "enum": ["resolved_in_contact", "pending_follow_up", "transferred",
                     "unresolved", "customer_disconnected", "unclear"]
          },
          "concession_given": { "type": "boolean" },
          "repeat_contacts_mentioned": { "type": ["integer", "null"] },
          "blocker": {
            "type": "string",
            "enum": ["none", "policy_limit", "system_or_tool_limit", "wizard_no_resolution",
                     "supplier_or_carrier_dependency", "approval_or_authority_limit",
                     "prior_agent_error", "customer_expectation_gap", "other"]
          },
          "blocker_detail": { "type": ["string", "null"], "maxLength": 240 },
          "de_escalation_behaviors": {
            "type": "array",
            "items": {
              "type": "string",
              "enum": ["empathy_acknowledgment", "ownership_statement", "clear_next_steps",
                       "specific_timeline_given", "recap_confirmation", "none_observed"]
            }
          },
          "further_contact_risk": { "type": "string", "enum": ["low", "medium", "high"] },
          "further_contact_risk_reason": { "type": ["string", "null"], "maxLength": 240 },
          "customer_quote": { "type": ["string", "null"], "maxLength": 200 },
          "coaching_theme": { "type": ["string", "null"], "maxLength": 160 },
          "confidence": { "type": "number", "minimum": 0, "maximum": 1 }
        },
        "required": ["contact_id", "journey_observed", "escalation_trigger",
                     "customer_ask_primary", "agent_provided_primary", "ask_met",
                     "resolution_status", "concession_given", "blocker",
                     "de_escalation_behaviors", "further_contact_risk", "confidence"],
        "additionalProperties": false
      }
    }
  },
  "required": ["classifications"],
  "additionalProperties": false
}
```

## Why these fields

| Question from the request | Fields that answer it |
|---|---|
| What kinds of escalations are coming in mostly? | `escalation_trigger`, `escalation_trigger_detail`, plus wrap-based `journey` counts from `10_escalation_detail.sql` |
| Specifically to journey — what journey are they? | `journey` (agent-selected wrap Primary Reason, authoritative) vs `journey_observed` (transcript-derived; disagreement = wrap-coding gap) |
| What are customers asking for? | `customer_ask_primary`, `customer_ask_secondary`, `customer_quote` |
| What are agents providing? | `agent_provided_primary`, `agent_provided_detail`, `concession_given`, `ask_met` |
| Is it actually closing? | `resolution_status`, `further_contact_risk`, `blocker` |
