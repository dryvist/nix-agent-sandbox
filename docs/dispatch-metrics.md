# Dispatcher metrics

The dispatcher result includes `tokens`, the native ZCode `usage.totalTokens`
for the completed run, or `null` when usage is unavailable. The fixed text
result appends `tokens: <count>` or `tokens: unknown`.

Headless ZCode runs use `--output-format json`. The final summary is read once
after the container stops. A continued job creates another run and uses that
run's summary; session projection totals are never added. Multi-turn workflow
summaries are reported as unknown because the CLI summary only describes the
initial turn. Interrupted runs without a complete summary are also unknown.

The host configuration `/etc/agent-dispatch/telemetry.json` contains an
`endpoint` string with the full OTLP HTTP metrics URL. Its path is selectable
with `AGENT_DISPATCH_TELEMETRY_CONFIG`.
Optional host settings are `AGENT_DISPATCH_OTLP_METRICS_ENDPOINT` (overrides
the configured URL) and `AGENT_DISPATCH_OTLP_HEADERS_FILE` (HTTP headers).
The dispatcher encodes OTLP protobuf gauges with the official OpenTelemetry
protobuf library and records successful delivery. A
`refresh` retries pending payloads with their original timestamps; pending
payloads are retained past normal job retention. `status` never sends metrics.

| Metric | Value |
| --- | --- |
| `agent_dispatch_runs` | 1 per completed run, including continued and failed runs |
| `agent_dispatch_duration_seconds` | Elapsed seconds for that run |
| `agent_dispatch_tokens` | Native reported total tokens, omitted when unknown |

Every point has `job`, `run`, `tool`, `repo`, and `outcome` attributes. Token
points also have `token_type=total`. One run has one fixed completion timestamp;
retries replay the same point rather than incrementing a counter. Daily queries
use `sum(max_over_time(metric[1d] offset 1ms))`, with a one-day step and calendar-day
alignment. The per-run maximum prevents duplicate delivery from adding spend;
the offset assigns exact-midnight timestamps to the following calendar day.
Token coverage is `count(max_over_time(agent_dispatch_tokens[1d] offset 1ms))` divided by completed
runs. Zero reported tokens are distinct from unknown usage. Cache-read tokens
are not added to the native total a second time.

The image must contain the ZCode CLI for native runs to execute. These metrics
cover dispatcher runs; independently started interactive sessions do not
produce dispatcher completion events.
