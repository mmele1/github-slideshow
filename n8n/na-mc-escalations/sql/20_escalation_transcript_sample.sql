-- =====================================================================
-- 20_escalation_transcript_sample.sql
-- PURPOSE: Pull a journey-stratified sample of Level AI PHONE transcripts
--          for escalated MC/CARE contacts, ready for LLM extraction of
--          "what the customer asked for" vs "what the agent provided".
-- GRAIN:   one row per sampled contact, with the full stitched transcript
-- WINDOW:  trailing @lookback_days (default 90)
-- COST NOTE: conversation_speaker_utterances is large but clustered on
--          asr_log_id; the IN-list from `sampled` is what keeps this cheap.
--          Do not remove that predicate.
-- =====================================================================
DECLARE lookback_days INT64 DEFAULT 90;
DECLARE per_journey_sample INT64 DEFAULT 8;      -- transcripts per journey
DECLARE max_total_sample INT64 DEFAULT 120;      -- hard cap on LLM volume
DECLARE max_transcript_chars INT64 DEFAULT 12000;-- truncation guard
DECLARE min_utterances INT64 DEFAULT 12;         -- drop near-empty calls
DECLARE roster_team_patterns ARRAY<STRING> DEFAULT ['%multi%contact%', '%specialized%supervisor%'];
DECLARE escalation_detail_patterns ARRAY<STRING> DEFAULT [
  '%escalated by agent%',
  '%escalation resolved by supervisor%',
  '%escalation transferred to tier%'
];

WITH
latest_employee AS (
  SELECT * EXCEPT(rn) FROM (
    SELECT
      e.employee_id, e.employee_name, e.employee_working_team,
      e.employee_workgroup_name, e.employee_working_region, e.employee_date,
      ROW_NUMBER() OVER (PARTITION BY e.employee_id ORDER BY e.employee_date DESC) AS rn
    FROM `wf-gcp-us-ae-gat-prod.ops_reporting_core.tbl_snapshot_dim_employee` e
    WHERE e.employee_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
      AND e.employee_is_in_customer_service_org_flag
  ) WHERE rn = 1
),
mc_roster AS (
  SELECT * FROM latest_employee
  WHERE EXISTS (SELECT 1 FROM UNNEST(roster_team_patterns) p
                WHERE LOWER(COALESCE(employee_working_team, '')) LIKE p)
     OR EXISTS (SELECT 1 FROM UNNEST(roster_team_patterns) p
                WHERE LOWER(COALESCE(employee_workgroup_name, '')) LIKE p)
),
esc_wraps AS (
  SELECT
    w.wrap_id,
    CAST(w.customer_contact_id AS STRING) AS contact_id,
    w.customer_order_id,
    w.wrap_datetime,
    COALESCE(NULLIF(TRIM(w.wrap_primary_reason), ''), 'Unclassified') AS journey,
    w.wrap_reason_detail AS escalation_detail_reason,
    w.is_customer_issue_resolved,
    w.wrap_agent_id
  FROM `wf-gcp-us-service-data-prod.omnichannel_public.tbl_service_contact_wrap` w
  -- If wrap_datetime is DATETIME rather than TIMESTAMP, use
  --   DATETIME_SUB(CURRENT_DATETIME(), INTERVAL lookback_days DAY) instead.
  WHERE w.wrap_datetime >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL lookback_days DAY)
    AND EXISTS (SELECT 1 FROM UNNEST(escalation_detail_patterns) p
                WHERE LOWER(COALESCE(w.wrap_reason_detail, '')) LIKE p)
),
lai AS (
  SELECT * EXCEPT(rn) FROM (
    SELECT
      CAST(l.ContactID AS STRING) AS contact_id,
      l.OrderNumber               AS lai_order_number,
      l.banking_conversation_id,
      CAST(l.asr_log_id AS STRING) AS asr_log_id,
      ROW_NUMBER() OVER (PARTITION BY CAST(l.ContactID AS STRING)
                         ORDER BY l.ContactDateTime DESC) AS rn
    FROM `wf-gcp-us-ae-cs-prod.gsat_reporting.lai_pipeline_data` l
    WHERE DATE(l.ContactDateTime) >= DATE_SUB(CURRENT_DATE(), INTERVAL lookback_days + 2 DAY)
      AND l.asr_log_id IS NOT NULL
  ) WHERE rn = 1
),
-- Escalations that actually have a transcript handle ------------------
eligible AS (
  SELECT
    e.wrap_id, e.contact_id, e.journey, e.escalation_detail_reason,
    e.wrap_datetime, e.is_customer_issue_resolved,
    r.employee_name AS mc_agent_name,
    COALESCE(CAST(e.customer_order_id AS STRING), l.lai_order_number) AS order_number,
    l.asr_log_id,
    l.banking_conversation_id
  FROM esc_wraps e
  JOIN mc_roster r ON r.employee_id = e.wrap_agent_id
  JOIN lai l       ON l.contact_id  = e.contact_id
),
-- Stratify: N per journey, newest-weighted random pick ----------------
sampled AS (
  SELECT * EXCEPT(rn_journey, rn_overall) FROM (
    SELECT
      eligible.*,
      ROW_NUMBER() OVER (PARTITION BY journey ORDER BY RAND()) AS rn_journey,
      ROW_NUMBER() OVER (ORDER BY RAND())                      AS rn_overall
    FROM eligible
  )
  WHERE rn_journey <= per_journey_sample
    AND rn_overall <= max_total_sample * 4   -- coarse pre-trim
),
-- Stitch utterances into a readable transcript ------------------------
transcripts AS (
  SELECT
    CAST(u.asr_log_id AS STRING) AS asr_log_id,
    COUNT(*) AS utterance_count,
    STRING_AGG(
      CONCAT(COALESCE(u.speaker, 'UNKNOWN'), ': ', u.transcript),
      '\n' ORDER BY u.start_time
    ) AS transcript_text
  FROM `wf-gcp-us-cust-conv-proc-prod.post_order_level_ai_import.conversation_speaker_utterances` u
  WHERE u.transcript IS NOT NULL
    AND LENGTH(u.transcript) > 0
    AND CAST(u.asr_log_id AS STRING) IN (SELECT asr_log_id FROM sampled)
  GROUP BY 1
)
SELECT
  s.contact_id,
  s.wrap_id,
  s.journey,
  s.escalation_detail_reason,
  s.wrap_datetime,
  s.is_customer_issue_resolved,
  s.mc_agent_name,
  s.order_number,
  s.asr_log_id,
  s.banking_conversation_id AS levelai_conversation_id,
  CASE WHEN s.banking_conversation_id IS NOT NULL
       THEN CONCAT('https://wayfair.thelevel.ai/organizations/2/conversations/review/',
                   CAST(s.banking_conversation_id AS STRING)) END AS levelai_url,
  t.utterance_count,
  LENGTH(t.transcript_text) > max_transcript_chars AS transcript_truncated,
  SUBSTR(t.transcript_text, 1, max_transcript_chars) AS transcript_text
FROM sampled s
JOIN transcripts t USING (asr_log_id)
WHERE t.utterance_count >= min_utterances
ORDER BY s.journey, s.wrap_datetime DESC
LIMIT max_total_sample;

-- ---------------------------------------------------------------------
-- VALIDATION (run once): confirm lai_pipeline_data.asr_log_id joins to
-- the Level AI ASR log, i.e. that the id space is shared. If this
-- returns 0 rows, switch the `transcripts` CTE to join through
-- level_phone_asrlog on provider_conversation_id instead.
-- ---------------------------------------------------------------------
-- SELECT COUNT(*) AS matched
-- FROM `wf-gcp-us-ae-cs-prod.gsat_reporting.lai_pipeline_data` l
-- JOIN `wf-gcp-us-cust-conv-proc-prod.post_order_level_ai_import.level_phone_asrlog` a
--   ON CAST(l.asr_log_id AS STRING) = CAST(a.asr_log_id AS STRING)
-- WHERE DATE(l.ContactDateTime) >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY);
