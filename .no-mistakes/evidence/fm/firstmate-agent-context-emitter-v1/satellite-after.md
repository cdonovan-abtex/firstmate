# Operator prose above

<!-- AGENT-CONTEXT:BEGIN -->
## Agent context (generated - do not hand-edit)

### Repository shape
- Repository: `satellite-copy`
- Current branch: `main`
- Default branch: `main`
- Origin: `https://<redacted>@example.test/org/repo.git`
- Graph: unbuilt
- Entrypoints: `npm run start` - node server.js
- Also present: `README.md`

### Domain contract
- Context state: validated
- External system: Fixture ERP (ERP)
- Integration surface: REST
- Operator persona: operator
- Responsibilities: reconcile
- Domain summary: Disposable satellite domain
- Entities: Order (source of truth: ERP; sensitivity: HIGH)
- Events: order.changed: order changed
- MCP tools: search_orders (read): search orders
- Tier: 1 - fixture
- Standalone faces: execution=worker; decision=operator
- Write posture: phase_1_pull_only; approved entities=none
- Operator-owned fields: none
- Canonical fields: id
- Tenants: primary=primary; secondary or sandbox=sandbox
- Access model: users=operator; roles=reader; entitlements=orders.read
- Operator decision: proceed by operator on 2026-09-10; fixture

<!-- AGENT-CONTEXT:END -->




# Operator prose below
