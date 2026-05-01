# Delivery Pipeline — Role-Based Agent Workflow

## Pipeline

```
Stage 1        Stage 2           Stage 3     Stage 4       Stage 5              Stage 6
───────        ───────           ───────     ───────       ───────              ───────
  PM    ──→  Architect + Dev  ──→   QA   ──→  CloudOps  ──→  Architect+QA+PM  ──→  Audit
(plan)       (design+build)     (test)     (deploy)       (review gate)        (compliance)
                                   │                           │
                                   └── reject → back to Dev    └── reject → back to responsible role
```

## Stages

| Stage | Role(s) | Gate Criteria | On Reject |
|---|---|---|---|
| 1. Plan | PM | Requirements + acceptance criteria complete | — |
| 2. Design + Build | Architect + Dev | Architecture doc + working code + unit tests | — |
| 3. Test | QA | All tests pass, no critical bugs, security OK | → Dev (Stage 2) |
| 4. Deploy | CloudOps | Stack deployed, health checks pass, monitoring live | → Dev or QA |
| 5. Review | Architect + QA + PM | Architecture compliance, test coverage, requirements met | → Stage 2, 3, or 4 |
| 6. Audit | Compliance Auditor | All compliance controls pass | → Responsible role |

## Handoff Protocol

Each stage handoff requires:
1. Output artifacts committed to workspace branch
2. Handoff checklist completed (defined in each role's config in `roles/`)
3. Next-stage agent @mentioned in Discord with summary

## Role-to-Stage Map

| Role | File | Active Stages |
|---|---|---|
| Project Manager | `roles/agent.PM.md` | 1, 5 |
| Architect | `roles/agent.Architect.md` | 2, 5 (lead) |
| Full-Stack Developer | `roles/agent.Full-stack-dev.md` | 2 |
| QA Engineer | `roles/agent.QA.md` | 3, 5 |
| CloudOps Engineer | `roles/agent.CloudOps.md` | 4 |
| Compliance Auditor | `roles/agent.Compliance-auditor.md` | 6 |
