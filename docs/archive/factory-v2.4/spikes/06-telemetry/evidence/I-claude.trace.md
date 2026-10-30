# Trace I-claude: 05d468195deee87ca69bbb3e14698410

item id: `spike6-I-20261022T082033Z`

## Waterfall (joined = same TraceId)

```text
claude-code / claude_code.interaction  [Internal] 5736277f <- -  35950.2 ms  Unset
  claude-code / claude_code.llm_request  [Internal] e58d2748 <- 5736277f  3033.9 ms  Unset
  claude-code / claude_code.llm_request  [Internal] 567805cf <- 5736277f  7763.2 ms  Unset
  claude-code / claude_code.tool  [Internal] e6928f3b <- 5736277f  432.2 ms  Unset
    claude-code / claude_code.tool.blocked_on_user  [Internal] 708e8a4f <- e6928f3b  5.0 ms  Unset
    claude-code / claude_code.tool.execution  [Internal] 33a86a7b <- e6928f3b  427.0 ms  Unset
  claude-code / claude_code.llm_request  [Internal] 6e61470b <- 5736277f  5973.0 ms  Unset
  claude-code / claude_code.tool  [Internal] eb2dfdd8 <- 5736277f  99.8 ms  Unset
    claude-code / claude_code.tool.blocked_on_user  [Internal] e49333f9 <- eb2dfdd8  6.2 ms  Unset
    claude-code / claude_code.tool.execution  [Internal] c6680f23 <- eb2dfdd8  93.3 ms  Unset
  claude-code / claude_code.llm_request  [Internal] f1d17709 <- 5736277f  5347.9 ms  Unset
  claude-code / claude_code.tool  [Internal] 534e1e84 <- 5736277f  138.8 ms  Unset
    claude-code / claude_code.tool.blocked_on_user  [Internal] 67133541 <- 534e1e84  4.7 ms  Unset
    claude-code / claude_code.tool.execution  [Internal] 89c900d2 <- 534e1e84  133.9 ms  Unset
      gateway-stub-spike / GET /health  [Server] b087079a <- 89c900d2  1.8 ms  Ok
  claude-code / claude_code.llm_request  [Internal] 7f246a56 <- 5736277f  5205.6 ms  Unset
  claude-code / claude_code.tool  [Internal] 92570ac3 <- 5736277f  7.0 ms  Unset
    claude-code / claude_code.tool.blocked_on_user  [Internal] 82a6a791 <- 92570ac3  2.7 ms  Unset
    claude-code / claude_code.tool.execution  [Internal] eb597c23 <- 92570ac3  2.6 ms  Unset
  claude-code / claude_code.llm_request  [Internal] 2a3fc1d7 <- 5736277f  4934.6 ms  Unset
  claude-code / claude_code.tool  [Internal] 330956fd <- 5736277f  55.3 ms  Unset
    claude-code / claude_code.tool.blocked_on_user  [Internal] 6b9ac9a6 <- 330956fd  3.4 ms  Unset
    claude-code / claude_code.tool.execution  [Internal] c2ab7765 <- 330956fd  51.7 ms  Unset
      gateway-stub-spike / mcp tools/call  [Server] 58ac7277 <- c2ab7765  0.6 ms  Ok
  claude-code / claude_code.llm_request  [Internal] 430620ed <- 5736277f  5014.9 ms  Unset
```

## Spans of this run's other hops that are NOT in this trace

|service|span|kind|trace8|parent|why it is elsewhere|
|-|-|-|-|-|-|
|gateway-stub-spike|mcp server/discover|Server|6c1d1090|-|gateway-stub request without a joined traceparent|
|gateway-stub-spike|mcp initialize|Server|e4a1dc9c|-|gateway-stub request without a joined traceparent|
|gateway-stub-spike|mcp notifications/initialized|Server|f625b3ae|-|gateway-stub request without a joined traceparent|
|gateway-stub-spike|mcp tools/list|Server|b81db483|-|gateway-stub request without a joined traceparent|

## Log records with this TraceId

|service|event|n|with SpanId|
|-|-|-|-|
|claude-code|api_request|7|7|
|claude-code|assistant_response|2|2|
|claude-code|hook_execution_complete|3|3|
|claude-code|hook_execution_start|3|3|
|claude-code|hook_registered|7|7|
|claude-code|plugin_loaded|5|5|
|claude-code|tool_decision|5|5|
|claude-code|tool_result|5|5|
|claude-code|user_prompt|1|1|

## Join by resource attribute `warden.item.id`

|signal|service|rows|
|-|-|-|
|logs|claude-code|43|
|metrics_sum|claude-code|44|
|traces|claude-code|24|

## Span names and attribute keys

|service|span|count|attribute keys|
|-|-|-|-|
|claude-code|claude_code.interaction|1|gen_ai.conversation.id, gen_ai.operation.name, gen_ai.provider.name, interaction.duration_ms, interaction.sequence, parent.source, queued_sends, session.id, span.type, terminal.type, user.id, user_prompt, user_prompt_length, warden.item.id, warden.spike|
|claude-code|claude_code.llm_request|7|attempt, cache_creation_tokens, cache_read_tokens, duration_ms, effort, first_content_ms, gen_ai.conversation.id, gen_ai.provider.name, gen_ai.request.model, gen_ai.response.finish_reasons, gen_ai.response.id, gen_ai.system, input_tokens, llm_request.context, model, output_tokens, query_source_safe, request_id, session.id, span.type, speed, stop_reason, success, terminal.type, ttft_ms, user.id, warden.item.id, warden.spike|
|claude-code|claude_code.tool|5|anthropic.mcp.server.name, bash_argv0, bash_command_class, duration_ms, full_command, gen_ai.conversation.id, gen_ai.operation.name, gen_ai.provider.name, gen_ai.tool.call.id, gen_ai.tool.name, session.id, span.type, terminal.type, tool_name, tool_name_safe, tool_use_id, user.id, warden.item.id, warden.spike|
|claude-code|claude_code.tool.blocked_on_user|5|decision, duration_ms, gen_ai.conversation.id, gen_ai.provider.name, session.id, source, span.type, terminal.type, user.id, warden.item.id, warden.spike|
|claude-code|claude_code.tool.execution|5|duration_ms, gen_ai.conversation.id, gen_ai.provider.name, gen_ai.tool.call.id, session.id, span.type, success, terminal.type, tool_use_id, user.id, warden.item.id, warden.spike|
|gateway-stub-spike|GET /health|1|http.request.method, http.response.status_code, traceparent.present, url.path|
|gateway-stub-spike|mcp tools/call|1|http.request.method, http.response.status_code, rpc.method, traceparent.present, url.path|

## SQL used

```sql
SELECT toString(Timestamp) AS ts, ServiceName, SpanName, SpanKind, SpanId, ParentSpanId,
       Duration, StatusCode, SpanAttributes, ResourceAttributes
FROM default.otel_traces
WHERE TraceId = '05d468195deee87ca69bbb3e14698410'
ORDER BY Timestamp, SpanId

SELECT toString(Timestamp) AS ts, ServiceName, SpanName, SpanKind, TraceId, substring(TraceId, 1, 8) AS trace8,
       SpanId, ParentSpanId, StatusCode
FROM default.otel_traces
WHERE TraceId IN ('6c1d1090846fefa0b152e50b9785b567', 'e4a1dc9cb3185be268b920a327183115', 'f625b3ae718a62b4771e314d955caf8b', 'b81db48393dd291df7e9b9e9d8a92199')
ORDER BY Timestamp

SELECT ServiceName, LogAttributes['event.name'] AS event, count() AS n, countIf(SpanId != '') AS with_span_id
FROM default.otel_logs
WHERE TraceId = '05d468195deee87ca69bbb3e14698410'
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
