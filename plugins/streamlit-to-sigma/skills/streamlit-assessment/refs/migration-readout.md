# Migration readout

Readiness, complexity, delivery class, and migration disposition answer different
questions. Do not collapse them into one score:

- **Readiness** — can the current converter proceed (`direct`, `redesign`,
  `blocked`)?
- **Complexity** — how much application architecture must be replaced (`lite`,
  `medium`, `complex`)?
- **Delivery class** — mostly automated, engineer-led, or multi-specialist?
- **Disposition** — which implementation path applies?

## Ease-of-migration chart

| Complexity | Typical app | Migration path | Delivery class |
|---|---|---|---|
| Lite | SQL-backed dashboard with standard charts, tables, and filters | Mostly automated conversion plus parity review | Fast / easy |
| Medium | Multipage app with forms, moderate transforms, or simple writeback | Assisted conversion with targeted Sigma redesign | Engineer-led |
| Complex | Session state, callbacks, auth, custom Python, or transactional CRUD | Architecture-led redesign with explicit manual finish gates | Multi-specialist |

Do not hardcode calendar claims such as “minutes,” “one day,” or “one week.”
Source counts cannot prove elapsed delivery time. Credentials, warehouse changes,
security review, staffing, UI-only finishing, and parity requirements materially
change it. If an organization wants calendar ranges, calibrate them from its
observed migration telemetry and keep them configurable.

## Migration dispositions

| Disposition | Meaning |
|---|---|
| `spec-native` | Workbook/data-model code representation covers the required behavior. |
| `warehouse-backed` | Generate or reuse warehouse tables, views, procedures, and grants. |
| `python-element-candidate` | Reviewed Python/code-output path, gated by workspace and connection capabilities. |
| `workbook-agent-candidate` | Discover and validate an existing workbook agent for AI/chat behavior. |
| `manual-ui-finish` | Sigma supports the behavior, but the public spec API does not author or read it back. Name the exact UI step. |
| `plugin` | A client-side custom component is justified and hosting/registration is available. |
| `redesign` | Replace Streamlit runtime semantics with a different Sigma-native workflow. |
| `blocked` | Source ambiguity, unsafe dynamic SQL, security, or missing access prevents a reliable migration. |

A project can carry more than one disposition. The first is the primary delivery
path; the full list explains mixed architectures.

Keep statically discovered findings after conversion, but mark mechanically
lowered findings with `resolved: true` plus a concrete `resolution`. Readiness,
complexity, and disposition use unresolved findings only.

## Stateful-app decision order

1. Use controls, formulas, supported actions, overlays, and input tables when
   the behavior is public-spec authorable.
2. Use warehouse-backed views/tables/procedures for durable operational state.
3. Probe the live workbook spec API before claiming that an action host is
   automatable.
4. When the Sigma UI supports a behavior but GET omits it and POST/PUT rejects
   it, emit `manual-ui-finish`; never invent a code-representation shape.
5. Use a plugin only for client-side interaction/visualization, not as a default
   replacement for governance or persistence.

## Benefits of Sigma

- **Governance:** centralized permissions, row/column security, lineage, and
  auditability.
- **Production deployment path:** managed sharing and warehouse-backed
  execution after security and parity gates pass.
- **Warehouse-native operations:** durable input, writeback, and procedure
  patterns without a custom application server.
- **Reusable semantic layer:** governed data models, metrics, and relationships
  shared across workbooks.
- **Operational simplicity:** managed scheduling, exports, collaboration, and
  API-versioned workbook delivery.

“Production-ready” is a gated outcome, not an automatic migration claim. Security,
warehouse parity, interaction parity, and visual QA must pass first.
