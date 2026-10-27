-- warden job-signal metrics, read-only. Window: last 14 days.
WITH it AS (
  SELECT t.event_id, e.source, t.signature, t.state, t.close_reason, t.failure_class,
         t.created_at, t.redrives, t.strikes,
         (SELECT min(at) FROM item_transitions x WHERE x.event_id = t.event_id AND x.to_state = 'fixed') AS fixed_at
  FROM triage_items t JOIN events e ON e.id = t.event_id
  WHERE t.created_at >= strftime('%Y-%m-%dT%H:%M:%S', 'now', '-14 days')
)
SELECT source,
  count(*)                                              AS opened,
  sum(fixed_at IS NOT NULL)                             AS fixed,
  sum(state = 'needs_decision')                         AS needs_decision,
  sum(state = 'failed')                                 AS failed,
  sum(state = 'quiet')                                  AS quiet,
  sum(state = 'closed' AND close_reason = 'ignored')    AS false_pos,
  sum(state = 'closed' AND close_reason = 'duplicate')  AS dup,
  round(avg(CASE WHEN fixed_at IS NOT NULL THEN (julianday(fixed_at) - julianday(created_at)) * 24 END), 1) AS avg_h_to_fix,
  round(max(CASE WHEN fixed_at IS NOT NULL THEN (julianday(fixed_at) - julianday(created_at)) * 24 END), 1) AS max_h_to_fix,
  sum(redrives)                                         AS redrives
FROM it GROUP BY source ORDER BY opened DESC;
-- reopened / chronic: same signature opened more than once in the window
SELECT signature, count(*) AS items, max(created_at) AS last
FROM triage_items WHERE created_at >= strftime('%Y-%m-%dT%H:%M:%S', 'now', '-14 days')
GROUP BY signature HAVING count(*) > 1 ORDER BY items DESC LIMIT 20;
-- alert noise: raw events vs items per source
SELECT e.source, count(*) AS events, count(t.event_id) AS became_items
FROM events e LEFT JOIN triage_items t ON t.event_id = e.id
WHERE e.first_seen >= strftime('%Y-%m-%dT%H:%M:%S', 'now', '-14 days')
GROUP BY e.source ORDER BY events DESC;
