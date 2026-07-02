#!/usr/bin/env python3
"""
Challenge 2 Reference Test — Platform Bridge from OTel Blueprint.

Standalone validation (no EKS/K8s required) that proves:
  - OTel trace context propagates across an MCP boundary
  - gen_ai.* semantic conventions are used for LLM spans
  - ai_infra.* prefix is used for Tier 2 (tool/agent) attributes
  - Evidence packets contain hashes, never raw args/results
"""

from __future__ import annotations

import hashlib
import json
import sys
from datetime import datetime, timezone

from opentelemetry import context, trace
from opentelemetry.propagate import set_global_textmap
from opentelemetry.propagators.composite import CompositePropagator
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor, ConsoleSpanExporter


# ---------------------------------------------------------------------------
# 1. OTel SDK setup with console exporter
# ---------------------------------------------------------------------------

resource = Resource.create({
    "service.name": "ai-inference-agent",
    "k8s.namespace.name": "ml-team-a",
    "k8s.pod.name": "agent-pod-001",
    "k8s.pod.labels.team": "nlp",
})

provider = TracerProvider(resource=resource)
provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
trace.set_tracer_provider(provider)

propagator = CompositePropagator([TraceContextTextMapPropagator()])
set_global_textmap(propagator)

tracer = trace.get_tracer("challenge2.reference", "0.1.0")

# ---------------------------------------------------------------------------
# 2. Synthetic data
# ---------------------------------------------------------------------------

SYNTHETIC_ARGS = {"account_id": "ACCT-9182", "currency": "USD"}
SYNTHETIC_RESULT = {"balance": 14209.55, "as_of": "2026-06-30T00:00:00Z"}

args_hash = hashlib.sha256(json.dumps(SYNTHETIC_ARGS, sort_keys=True).encode()).hexdigest()
result_hash = hashlib.sha256(json.dumps(SYNTHETIC_RESULT, sort_keys=True).encode()).hexdigest()

# ---------------------------------------------------------------------------
# 3. Span creation — workflow → llm-call → mcp boundary → tool-call
# ---------------------------------------------------------------------------

collected_spans = {}

with tracer.start_as_current_span("agent.workflow", attributes={
    "ai_infra.agent.role": "supervisor",
}) as workflow_span:

    collected_spans["workflow"] = workflow_span

    # LLM call span (gen_ai.* semconv only)
    with tracer.start_as_current_span("gen_ai.invoke", attributes={
        "gen_ai.system": "aws.bedrock",
        "gen_ai.request.model": "anthropic.claude-haiku-4-5",
        "gen_ai.usage.input_tokens": 150,
        "gen_ai.usage.output_tokens": 45,
        "gen_ai.response.finish_reasons": "tool_calls",
    }) as llm_span:
        collected_spans["llm"] = llm_span

    # MCP boundary — inject traceparent into carrier, extract on other side
    carrier: dict[str, str] = {}
    propagator.inject(carrier)

    # Simulate receiving side: extract context from carrier
    extracted_ctx = propagator.extract(carrier)

    with trace.get_tracer("challenge2.reference").start_span(
        "mcp.tool_call",
        context=extracted_ctx,
    ) as mcp_span:
        collected_spans["mcp"] = mcp_span

        # Tool call span with ai_infra.* attributes
        with tracer.start_as_current_span("ai_infra.tool.execute", attributes={
            "ai_infra.tool.name": "get_account_balance",
            "ai_infra.tool.args_hash": args_hash,
            "ai_infra.tool.result_hash": result_hash,
            "ai_infra.tool.side_effect_class": "read-only",
            "ai_infra.agent.verdict": "MATCH",
        }, context=trace.set_span_in_context(mcp_span)) as tool_span:
            collected_spans["tool"] = tool_span

# ---------------------------------------------------------------------------
# 4. Evidence packet
# ---------------------------------------------------------------------------

workflow_ctx = workflow_span.get_span_context()
tool_ctx = tool_span.get_span_context()

evidence_packet = {
    "trace_id": format(workflow_ctx.trace_id, "032x"),
    "span_id": format(tool_ctx.span_id, "016x"),
    "tool_name": "get_account_balance",
    "args_hash": args_hash,
    "result_hash": result_hash,
    "side_effect_class": "read-only",
    "verdict": "MATCH",
    "raw_args": None,
    "raw_result": None,
    "timestamp": datetime.now(timezone.utc).isoformat(),
}

evidence_path = "evidence_packet.json"
with open(evidence_path, "w") as f:
    json.dump(evidence_packet, f, indent=2)

print(f"\n{'='*60}")
print("EVIDENCE PACKET written to:", evidence_path)
print(json.dumps(evidence_packet, indent=2))
print(f"{'='*60}\n")

# ---------------------------------------------------------------------------
# 5. Validator
# ---------------------------------------------------------------------------

checks: list[tuple[str, bool]] = []

# Check 1: Trace context propagated across MCP boundary (same trace_id)
mcp_trace_id = collected_spans["mcp"].get_span_context().trace_id
workflow_trace_id = workflow_ctx.trace_id
checks.append((
    "Trace context propagated across MCP boundary (same trace_id)",
    mcp_trace_id == workflow_trace_id,
))

# Check 2: gen_ai.* attributes present on LLM span
llm_attrs = dict(collected_spans["llm"].attributes)
gen_ai_keys = [k for k in llm_attrs if k.startswith("gen_ai.")]
checks.append((
    "gen_ai.* attributes present on LLM span (no custom semconv used)",
    len(gen_ai_keys) >= 4,
))

# Check 3: ai_infra.* prefix used for all Tier 2 attributes
tool_attrs = dict(collected_spans["tool"].attributes)
tier2_keys = [k for k in tool_attrs if not k.startswith(("otel.", "telemetry."))]
all_ai_infra = all(k.startswith("ai_infra.") for k in tier2_keys)
checks.append((
    "ai_infra.* prefix used for all Tier 2 attributes (not bare agent.*/tool.*)",
    all_ai_infra and len(tier2_keys) > 0,
))

# Check 4: No raw_args or raw_result in evidence packet
checks.append((
    "No raw_args or raw_result in evidence packet (null check)",
    evidence_packet["raw_args"] is None and evidence_packet["raw_result"] is None,
))

# Check 5: Evidence packet links to trace/span IDs with hashes present
checks.append((
    "Evidence packet links to trace/span IDs (hashes present)",
    bool(evidence_packet["trace_id"])
    and bool(evidence_packet["span_id"])
    and bool(evidence_packet["args_hash"])
    and bool(evidence_packet["result_hash"]),
))

# Check 6: k8s resource attributes present
resource_attrs = dict(provider.resource.attributes)
k8s_keys = [k for k in resource_attrs if k.startswith("k8s.")]
checks.append((
    "k8s resource attributes present (tenant context)",
    len(k8s_keys) >= 3,
))

# ---------------------------------------------------------------------------
# 6. Summary
# ---------------------------------------------------------------------------

print("VALIDATION RESULTS")
print("-" * 60)
passed = 0
for desc, result in checks:
    status = "PASS" if result else "FAIL"
    if result:
        passed += 1
    print(f"  [{status}] {desc}")

print("-" * 60)
print(f"Challenge 2 reference test: {passed}/6 checks passed")

causal = "VERIFIED" if passed == 6 else "NOT VERIFIED"
print(f"Causal path reconstruction: {causal}")

provider.shutdown()
sys.exit(0 if passed == 6 else 1)
