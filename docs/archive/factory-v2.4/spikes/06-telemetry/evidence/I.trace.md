# Trace I: c3d2bfa8b7d476e3f68dde881b8acd99

item id: `spike6-I-20261022T082033Z`

## Waterfall (joined = same TraceId)

```text
warden-spike / warden.item  [Internal] 74e13b3b <- -  43513.9 ms  Ok
```

## Spans of this run's other hops that are NOT in this trace

|service|span|kind|trace8|parent|why it is elsewhere|
|-|-|-|-|-|-|
|gateway-stub-spike|mcp server/discover|Server|6c1d1090|-|gateway-stub request without a joined traceparent|
|gateway-stub-spike|mcp initialize|Server|e4a1dc9c|-|gateway-stub request without a joined traceparent|
|gateway-stub-spike|mcp notifications/initialized|Server|f625b3ae|-|gateway-stub request without a joined traceparent|
|gateway-stub-spike|mcp tools/list|Server|b81db483|-|gateway-stub request without a joined traceparent|
|claude-code|claude_code.interaction|Internal|05d46819|-|gateway-stub request without a joined traceparent|
|claude-code|claude_code.llm_request|Internal|05d46819|5736277f|gateway-stub request without a joined traceparent|
|claude-code|claude_code.llm_request|Internal|05d46819|5736277f|gateway-stub request without a joined traceparent|
|claude-code|claude_code.tool|Internal|05d46819|5736277f|gateway-stub request without a joined traceparent|
|claude-code|claude_code.tool.blocked_on_user|Internal|05d46819|e6928f3b|gateway-stub request without a joined traceparent|
|claude-code|claude_code.tool.execution|Internal|05d46819|e6928f3b|gateway-stub request without a joined traceparent|
|claude-code|claude_code.llm_request|Internal|05d46819|5736277f|gateway-stub request without a joined traceparent|
|claude-code|claude_code.tool|Internal|05d46819|5736277f|gateway-stub request without a joined traceparent|
|claude-code|claude_code.tool.blocked_on_user|Internal|05d46819|eb2dfdd8|gateway-stub request without a joined traceparent|
|claude-code|claude_code.tool.execution|Internal|05d46819|eb2dfdd8|gateway-stub request without a joined traceparent|
|claude-code|claude_code.llm_request|Internal|05d46819|5736277f|gateway-stub request without a joined traceparent|
|claude-code|claude_code.tool|Internal|05d46819|5736277f|gateway-stub request without a joined traceparent|
|claude-code|claude_code.tool.blocked_on_user|Internal|05d46819|534e1e84|gateway-stub request without a joined traceparent|
|claude-code|claude_code.tool.execution|Internal|05d46819|534e1e84|gateway-stub request without a joined traceparent|
|gateway-stub-spike|GET /health|Server|05d46819|89c900d2|gateway-stub request without a joined traceparent|
|claude-code|claude_code.llm_request|Internal|05d46819|5736277f|gateway-stub request without a joined traceparent|
|claude-code|claude_code.tool|Internal|05d46819|5736277f|gateway-stub request without a joined traceparent|
|claude-code|claude_code.tool.blocked_on_user|Internal|05d46819|92570ac3|gateway-stub request without a joined traceparent|
|claude-code|claude_code.tool.execution|Internal|05d46819|92570ac3|gateway-stub request without a joined traceparent|
|claude-code|claude_code.llm_request|Internal|05d46819|5736277f|gateway-stub request without a joined traceparent|
|claude-code|claude_code.tool|Internal|05d46819|5736277f|gateway-stub request without a joined traceparent|
|claude-code|claude_code.tool.blocked_on_user|Internal|05d46819|330956fd|gateway-stub request without a joined traceparent|
|claude-code|claude_code.tool.execution|Internal|05d46819|330956fd|gateway-stub request without a joined traceparent|
|gateway-stub-spike|mcp tools/call|Server|05d46819|c2ab7765|gateway-stub request without a joined traceparent|
|claude-code|claude_code.llm_request|Internal|05d46819|5736277f|gateway-stub request without a joined traceparent|

## Log records with this TraceId

|service|event|n|with SpanId|
|-|-|-|-|

## Join by resource attribute `warden.item.id`

|signal|service|rows|
|-|-|-|
|logs|claude-code|43|
|metrics_sum|claude-code|44|
|traces|claude-code|24|

## Span names and attribute keys

|service|span|count|attribute keys|
|-|-|-|-|
|warden-spike|warden.item|1|warden.item.id, warden.item.kind, warden.spike, warden.worker.exit_code|

## SQL used

```sql
SELECT toString(Timestamp) AS ts, ServiceName, SpanName, SpanKind, SpanId, ParentSpanId,
       Duration, StatusCode, SpanAttributes, ResourceAttributes
FROM default.otel_traces
WHERE TraceId = 'c3d2bfa8b7d476e3f68dde881b8acd99'
ORDER BY Timestamp, SpanId

SELECT toString(Timestamp) AS ts, ServiceName, SpanName, SpanKind, TraceId, substring(TraceId, 1, 8) AS trace8,
       SpanId, ParentSpanId, StatusCode
FROM default.otel_traces
WHERE TraceId IN ('6c1d1090846fefa0b152e50b9785b567', 'e4a1dc9cb3185be268b920a327183115', 'f625b3ae718a62b4771e314d955caf8b', 'b81db48393dd291df7e9b9e9d8a92199', '05d468195deee87ca69bbb3e14698410')
ORDER BY Timestamp

SELECT ServiceName, LogAttributes['event.name'] AS event, count() AS n, countIf(SpanId != '') AS with_span_id
FROM default.otel_logs
WHERE TraceId = 'c3d2bfa8b7d476e3f68dde881b8acd99'
GROUP BY ServiceName, event
ORDER BY ServiceName, event

SELECT * FROM (
  SELECT 'traces' AS signal, ServiceName, count() AS n FROM default.otel_traces
    WHERE ResourceAttributes['warden.item.id'] = 'spike6-I-20261022T082033Z' GROUP BY ServiceName
  UNION ALL SELECT 'logs', ServiceName, count() FROM default.otel_logs
    WHERE ResourceAttributes['warden.item.id'] = 'spike6-I-20261022T082033Z' GROUP BY ServiceName
  UNION ALL SELECT 'metrics_sum', ServiceName, count() FROM default.otel_metrics_sum
    WHERE ResourceAttributes['warden.item.id'] = 'spike6-I-20261022T082033Z' GROUP BY ServiceName
) ORDER BY signal, ServiceName
```
