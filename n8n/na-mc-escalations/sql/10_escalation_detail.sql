-- =====================================================================
-- 10_escalation_detail.sql
-- PURPOSE: One row per escalated contact handled by the NA Multi-Contact
--          (MC) / CARE team in the trailing window. This is the
--          QUANTITATIVE base: escalation volume, journey mix, outcome mix.
--          The n8n node "Build Escalation SQL" generates this same query
--          with the parameters below inlined as literals.
-- GRAIN:   wrap_id (one wrap = one agent's documented handling of a contact)
-- WINDOW:  trailing @lookback_days (default 90)
-- =====================================================================
-- PARAMETERS (declared for console runs; n8n inlines them):
DECLARE lookback_days INT64 DEFAULT 90;
DECLARE roster_team_patterns ARRAY<STRING> DEFAULT ['%multi%contact%', '%specialized%supervisor%'];
DECLARE escalation_detail_patterns ARRAY<STRING> DEFAULT [
  '%escalated by agent%',      -- SOP: Detailed Reason for a CARE/MC escalation
  '%escalation resolved by supervisor%',
  '%escalation transferred to tier%'
];
DECLARE queue_patterns ARRAY<STRING> DEFAULT ['%multi contact%', '%care%'];
DECLARE max_rows INT64 DEFAULT 50000;

WITH
-- 1) Latest roster snapshot per employee -------------------------------
latest_employee AS (
  SELECT * EXCEPT(rn) FROM (
    SELECT
      e.employee_id,
      e.employee_name,
      e.employee_email,
      e.employee_manager_name,
      e.employee_workgroup_name,
      e.employee_working_region,
      e.employee_working_team,
      e.employee_working_site,
      e.employee_date,
      ROW_NUMBER() OVER (PARTITION BY e.employee_id ORDER BY e.employee_date DESC) AS rn
    FROM `wf-gcp-us-ae-gat-prod.ops_reporting_core.tbl_snapshot_dim_employee` e
    WHERE e.employee_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
      AND e.employee_is_in_customer_service_org_flag
  ) WHERE rn = 1
),

-- 2) NA Multi-Contact / CARE roster ------------------------------------
mc_roster AS (
  SELECT *
  FROM latest_employee
  WHERE (
      EXISTS (SELECT 1 FROM UNNEST(roster_team_patterns) p
              WHERE LOWER(COALESCE(employee_working_team, '')) LIKE p)
   OR EXISTS (SELECT 1 FROM UNNEST(roster_team_patterns) p
              WHERE LOWER(COALESCE(employee_workgroup_name, '')) LIKE p)
  )
  -- Region guard: NA only. Adjust after BLOCK 3 of 00_discovery_labels.sql.
  AND (employee_working_region IS NULL
       OR LOWER(employee_working_region) LIKE '%north america%'
       OR LOWER(employee_working_region) IN ('na', 'us', 'usa', 'canada'))
),

-- 3) Escalation wraps by those agents ----------------------------------
--    Journey = wrap_primary_reason (SOP: "Primary Reason: select the
--    customer journey that best represents why the customer escalated").
esc_wraps AS (
  SELECT
    w.wrap_id,
    w.customer_contact_id,
    w.customer_order_id,
    w.wrap_agent_id,
    w.wrap_datetime,
    DATE(w.wrap_datetime)                        AS wrap_date,
    DATE_TRUNC(DATE(w.wrap_datetime), WEEK(MONDAY)) AS wrap_week,
    DATE_TRUNC(DATE(w.wrap_datetime), MONTH)     AS wrap_month,
    w.wrap_primary_reason                        AS journey,
    w.wrap_reason_detail                         AS escalation_detail_reason,
    w.wrap_contact_channel,
    w.wrap_type,
    w.is_automated_wrap,
    w.is_customer_issue_resolved,
    w.wrap_contacted_by_agent_id                 AS escalated_by_agent_id
  FROM `wf-gcp-us-service-data-prod.omnichannel_public.tbl_service_contact_wrap` w
  -- If wrap_datetime is DATETIME rather than TIMESTAMP, use
  --   DATETIME_SUB(CURRENT_DATETIME(), INTERVAL lookback_days DAY) instead.
  WHERE w.wrap_datetime >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL lookback_days DAY)
    AND EXISTS (
      SELECT 1 FROM UNNEST(escalation_detail_patterns) p
      WHERE LOWER(COALESCE(w.wrap_reason_detail, '')) LIKE p
    )
),

-- 4) Queue context from the service performance datamart ---------------
--    Supplies the Genesys queue the contact was handled in (MC vs CARE).
queue_ctx AS (
  SELECT * EXCEPT(rn) FROM (
    SELECT
      CAST(wc.wrap_compliance_contact_id AS STRING) AS contact_id,
      wc.wrap_compliance_contact_queue_name        AS queue_name,
      wc.wrap_compliance_entry_type                AS entry_type,
      wc.wrap_compliance_event_datetime            AS contact_datetime,
      ROW_NUMBER() OVER (
        PARTITION BY CAST(wc.wrap_compliance_contact_id AS STRING)
        ORDER BY wc.wrap_compliance_event_datetime DESC
      ) AS rn
    FROM `wf-gcp-us-ae-gat-prod.ops_reporting.tbl_datamart_service_performance_metrics` t,
      UNNEST(t.wrap_compliance) AS wc
    WHERE t.employee_date >= DATE_SUB(CURRENT_DATE(), INTERVAL lookback_days + 2 DAY)
      AND wc.wrap_compliance_contact_id IS NOT NULL
  ) WHERE rn = 1
),

-- 5) Level AI linkage (gives us the transcript handles) -----------------
lai AS (
  SELECT * EXCEPT(rn) FROM (
    SELECT
      CAST(l.ContactID AS STRING)  AS contact_id,
      l.OrderNumber                AS lai_order_number,
      l.ContactDateTime            AS lai_contact_datetime,
      l.banking_conversation_id,
      l.asr_log_id,
      ROW_NUMBER() OVER (
        PARTITION BY CAST(l.ContactID AS STRING)
        ORDER BY l.ContactDateTime DESC
      ) AS rn
    FROM `wf-gcp-us-ae-cs-prod.gsat_reporting.lai_pipeline_data` l
    WHERE DATE(l.ContactDateTime) >= DATE_SUB(CURRENT_DATE(), INTERVAL lookback_days + 2 DAY)
  ) WHERE rn = 1
)

SELECT
  e.wrap_id,
  CAST(e.customer_contact_id AS STRING)        AS contact_id,
  e.customer_order_id                          AS order_id,
  e.wrap_datetime,
  e.wrap_date,
  e.wrap_week,
  e.wrap_month,
  COALESCE(NULLIF(TRIM(e.journey), ''), 'Unclassified') AS journey,
  e.escalation_detail_reason,
  e.wrap_contact_channel,
  e.is_customer_issue_resolved,
  e.is_automated_wrap,
  r.employee_id                                AS mc_agent_id,
  r.employee_name                              AS mc_agent_name,
  r.employee_email                             AS mc_agent_email,
  r.employee_manager_name                      AS mc_manager_name,
  r.employee_working_team                       AS mc_team,
  r.employee_working_site                       AS mc_site,
  q.queue_name,
  CASE
    WHEN LOWER(COALESCE(q.queue_name, '')) LIKE '%care%'  THEN 'CARE'
    WHEN LOWER(COALESCE(q.queue_name, '')) LIKE '%multi%' THEN 'Multi-Contact'
    ELSE 'Other / Unmapped'
  END                                          AS queue_group,
  COALESCE(CAST(e.customer_order_id AS STRING), l.lai_order_number) AS order_number_final,
  l.banking_conversation_id                    AS levelai_conversation_id,
  l.asr_log_id                                 AS asr_log_id,
  CASE
    WHEN l.banking_conversation_id IS NOT NULL
    THEN CONCAT('https://wayfair.thelevel.ai/organizations/2/conversations/review/',
                CAST(l.banking_conversation_id AS STRING))
  END                                          AS levelai_url,
  (l.asr_log_id IS NOT NULL)                   AS has_transcript_handle
FROM esc_wraps e
JOIN mc_roster r
  ON r.employee_id = e.wrap_agent_id
LEFT JOIN queue_ctx q
  ON q.contact_id = CAST(e.customer_contact_id AS STRING)
LEFT JOIN lai l
  ON l.contact_id = CAST(e.customer_contact_id AS STRING)
-- Keep MC/CARE-queue traffic when a queue is known; keep unknown-queue
-- rows too, since queue linkage is best-effort (see docs, Assumption A3).
WHERE q.queue_name IS NULL
   OR EXISTS (SELECT 1 FROM UNNEST(queue_patterns) p
              WHERE LOWER(q.queue_name) LIKE p)
ORDER BY e.wrap_datetime DESC
LIMIT max_rows;
