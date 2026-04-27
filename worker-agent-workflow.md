# Worker Agent Workflow — Git Repos, Local Directories & Memory Strategy

> Created by SpongeBob — 2026-04-27 | Generalized for all worker agents

## Overview

Each worker agent runs as a pod in OpenAB-EKS. Pods are **ephemeral** — they can be rotated, restarted, or rescheduled at any time. All persistent state lives in **three Git repositories**. The agent's local filesystem is a transient working copy that gets rebuilt from Git on every session start.

---

## 1. Three Git Repositories

```mermaid
graph LR
    subgraph "GitHub — juntinyeh-worker"
        MEM["📝 agent-memory<br/><i>Per-agent branch</i><br/>Persistent knowledge"]
        WS["🔧 agent-workspaces<br/><i>Per-task branch</i><br/>Working deliverables"]
        OUT["📤 agent-outbound<br/><i>Shared</i><br/>External/public output"]
    end

    subgraph "Agent Pod (ephemeral)"
        LOCAL_MEM["/home/agent/agent-memory"]
        LOCAL_WS["/home/agent/agent-workspaces"]
        LOCAL_OUT["/home/agent/agent-outbound"]
    end

    MEM <-->|"git pull / push"| LOCAL_MEM
    WS <-->|"git pull / push"| LOCAL_WS
    OUT <-->|"git pull / push"| LOCAL_OUT
```

| Repository | Branch Strategy | Purpose | Survives Pod Restart? |
|---|---|---|---|
| **agent-memory** | One branch per agent (e.g., `<AGENT-NAME>`) | Task summaries, decisions, learnings, TODO pool | ✅ Yes (in Git) |
| **agent-workspaces** | One branch per task (e.g., `<agent-name>-20260427-feature-x`) | Code, configs, deliverables for active tasks | ✅ Yes (in Git) |
| **agent-outbound** | Shared `main` branch | Documents/materials for external/public sharing | ✅ Yes (in Git) |

---

## 2. Local Directory ↔ Git Relationship

```mermaid
graph TB
    subgraph POD["Agent Pod — Ephemeral Container"]
        subgraph LOCAL["/home/agent/"]
            LM["/agent-memory<br/><i>Branch: &lt;AGENT-NAME&gt;</i><br/>Local working copy"]
            LW["/agent-workspaces<br/><i>Branch: per-task</i><br/>Local working copy"]
            LO["/agent-outbound<br/><i>Branch: main</i><br/>Local working copy"]
        end
    end

    subgraph GIT["GitHub (Persistent)"]
        GM["agent-memory<br/>branch: &lt;AGENT-NAME&gt;"]
        GW["agent-workspaces<br/>branch: &lt;agent-name&gt;-*"]
        GO["agent-outbound<br/>branch: main"]
    end

    LM -->|"git push<br/>(after every task)"| GM
    GM -->|"git clone + pull<br/>(session start)"| LM

    LW -->|"git push<br/>(frequent commits)"| GW
    GW -->|"git clone + checkout<br/>(session start)"| LW

    LO -->|"git push<br/>(when sharing)"| GO
    GO -->|"git clone + pull<br/>(session start)"| LO

    RESTART["⚠️ Pod Restart / Rotation"] -.->|"wipes local dirs"| LOCAL
    RESTART -.->|"Git repos survive"| GIT

    style RESTART fill:#fee,stroke:#c33
    style GIT fill:#e8f5e9,stroke:#388e3c
```

**Key principle:** Local directories are disposable clones. Git is the source of truth. Every meaningful change must be committed and pushed before it's considered "saved."

---

## 3. Session Startup Flow

Every time an agent starts (new pod, restart, or new session), it follows this bootstrap sequence:

```mermaid
flowchart TD
    START["🟢 Session Start"] --> CLONE_MEM["Clone/pull agent-memory<br/>checkout own branch"]
    CLONE_MEM --> CLONE_WS["Clone/pull agent-workspaces<br/>fetch all branches"]
    CLONE_WS --> CLONE_OUT["Clone/pull agent-outbound"]
    CLONE_OUT --> CHECK_TODO["Read TODO.md<br/>Check for pending tasks"]
    CHECK_TODO --> CHECK_MEM["Scan recent memory files<br/>for relevant context"]
    CHECK_MEM --> ARCHIVAL{"File count > 20?"}
    ARCHIVAL -->|Yes| RUN_ARCHIVAL["Run memory archival<br/>(hot → warm → cold)"]
    ARCHIVAL -->|No| PICK_TASK["Pick next task from TODO pool"]
    RUN_ARCHIVAL --> PICK_TASK
    PICK_TASK --> WORK["Begin work"]
```

**Startup commands:**
```bash
# 1. Memory
cd /home/agent
gh repo clone juntinyeh-worker/agent-memory
cd agent-memory && git checkout <AGENT-NAME> && git pull origin <AGENT-NAME>

# 2. Workspaces
cd /home/agent
gh repo clone juntinyeh-worker/agent-workspaces
cd agent-workspaces && git fetch origin

# 3. Outbound
cd /home/agent
gh repo clone juntinyeh-worker/agent-outbound
cd agent-outbound && git pull origin main
```

---

## 4. Memory Lifecycle — Hot → Warm → Cold

Memory files follow a tiered archival strategy to keep the working set small and searchable.

```mermaid
graph LR
    subgraph HOT["🔴 Hot — Current Week"]
        H1["2026-04-27-task-a.md"]
        H2["2026-04-26-task-b.md"]
        H3["2026-04-25-discovery.md"]
    end

    subgraph WARM["🟡 Warm — 1–4 Weeks Old"]
        W1["2026-04-week-3-summary.md"]
        W2["2026-04-week-2-summary.md"]
    end

    subgraph COLD["🔵 Cold — Older Than 1 Month"]
        C1["archive/2026-03-digest.md"]
        C2["archive/2026-02-digest.md"]
    end

    HOT -->|"After 7 days:<br/>consolidate into<br/>weekly summary"| WARM
    WARM -->|"After 30 days:<br/>consolidate into<br/>monthly digest"| COLD

    PROTECTED["🔒 Always Preserved<br/>TODO.md · index.md"]

    style HOT fill:#ffebee,stroke:#c62828
    style WARM fill:#fff8e1,stroke:#f9a825
    style COLD fill:#e3f2fd,stroke:#1565c0
    style PROTECTED fill:#e8f5e9,stroke:#2e7d32
```

### Tier Details

| Tier | Age | Format | Content |
|---|---|---|---|
| **Hot** 🔴 | Current week (0–7 days) | `YYYY-MM-DD-topic.md` | Full detail — task logs, decisions, code notes |
| **Warm** 🟡 | 1–4 weeks old | `YYYY-MM-week-W-summary.md` | Consolidated weekly summary — tasks, decisions, open items |
| **Cold** 🔵 | Older than 1 month | `archive/YYYY-MM-digest.md` | Monthly digest — highlights, learnings, carried-forward items |
| **Protected** 🔒 | Any age | `TODO.md`, `index.md` | Never archived or deleted |

### Archival Process

```mermaid
flowchart TD
    TRIGGER{"Root file count > 20?"}
    TRIGGER -->|No| SKIP["Skip archival"]
    TRIGGER -->|Yes| STEP1

    STEP1["1️⃣ Find files older than 7 days"]
    STEP1 --> STEP2["2️⃣ Group by week"]
    STEP2 --> STEP3["3️⃣ Create weekly summary per group<br/><code>YYYY-MM-week-W-summary.md</code>"]
    STEP3 --> STEP4["4️⃣ Delete original hot files"]
    STEP4 --> STEP5["5️⃣ Find weekly summaries older than 30 days"]
    STEP5 --> STEP6["6️⃣ Group by month"]
    STEP6 --> STEP7["7️⃣ Create monthly digest<br/><code>archive/YYYY-MM-digest.md</code>"]
    STEP7 --> STEP8["8️⃣ Delete original weekly files"]
    STEP8 --> COMMIT["Commit & push archival changes"]

    SKIP2["⚠️ TODO.md and index.md<br/>are NEVER deleted"] -.-> STEP4
    SKIP2 -.-> STEP8

    style SKIP2 fill:#e8f5e9,stroke:#2e7d32
```

### Weekly Summary Format

```markdown
# Week W Summary (YYYY-MM-DD to YYYY-MM-DD)
## Tasks Completed
- [task]: one-line summary (link to workspace branch if applicable)
## Key Decisions
- decision and reasoning
## Open Items
- anything unfinished, carried forward
```

### Monthly Digest Format

```markdown
# YYYY-MM Monthly Digest
## Highlights
- major accomplishments
## Learnings
- reusable knowledge
## Carried Forward
- unresolved items
```

---

## 5. Memory Search Strategy

When an agent needs context for a task, it searches memory in this order:

```mermaid
flowchart TD
    NEED["Need context for a task"] --> S1["1️⃣ Check TODO.md<br/>for related task entries & refs"]
    S1 --> S2["2️⃣ Scan hot files (current week)<br/>by filename date/topic match"]
    S2 --> S3["3️⃣ Check warm summaries<br/>for related tasks/decisions"]
    S3 --> S4["4️⃣ Check cold archive digests<br/>for historical learnings"]
    S4 --> S5["5️⃣ git log --oneline<br/>search commit messages as index"]
    S5 --> S6["6️⃣ Cross-reference workspace branches<br/>git show origin/branch:file"]

    style S1 fill:#ffebee,stroke:#c62828
    style S2 fill:#ffebee,stroke:#c62828
    style S3 fill:#fff8e1,stroke:#f9a825
    style S4 fill:#e3f2fd,stroke:#1565c0
    style S5 fill:#f3e5f5,stroke:#7b1fa2
    style S6 fill:#f3e5f5,stroke:#7b1fa2
```

**Search priority:** Recent & specific → Summarized → Archived → Git history

---

## 6. TODO Pool Strategy

The TODO pool lives in `agent-memory/TODO.md` on each agent's branch. It is the agent's task backlog.

### Task Lifecycle

```mermaid
stateDiagram-v2
    [*] --> Queued: Task created
    Queued --> InProgress: Agent picks task
    InProgress --> Done: Task completed
    InProgress --> Queued: Task blocked / deprioritized

    state Queued {
        [*] --> Waiting
        note right of Waiting
            Status: [ ]
            Sorted by: priority (high→normal→low)
            Then by: date (oldest first)
        end note
    }

    state InProgress {
        [*] --> Working
        note right of Working
            Status: [~]
            Only ONE task at a time
            Workspace branch linked
        end note
    }

    state Done {
        [*] --> Completed
        note right of Completed
            Status: [x]
            Completion date recorded
            Branch reference kept
        end note
    }
```

### Task Format

```
- [ ] `T-NNNN` | <priority> | <description> | source:<origin> | <date-added>
```

| Field | Values | Description |
|---|---|---|
| **Status** | `[ ]` / `[~]` / `[x]` | Queued / In Progress / Done |
| **ID** | `T-NNNN` | Auto-incrementing per agent |
| **Priority** | `high`, `normal`, `low` | Determines pick order |
| **Source** | `admin`, `self`, `<agent-name>` | Who created the task |
| **Date** | `YYYY-MM-DD` | When the task was added |

### Task Picking Algorithm

```mermaid
flowchart TD
    START["Check TODO.md"] --> FILTER["Filter: status = [ ] (queued)"]
    FILTER --> HIGH{"Any high priority?"}
    HIGH -->|Yes| PICK_HIGH["Pick oldest high-priority task"]
    HIGH -->|No| NORMAL{"Any normal priority?"}
    NORMAL -->|Yes| PICK_NORMAL["Pick oldest normal-priority task"]
    NORMAL -->|No| LOW{"Any low priority?"}
    LOW -->|Yes| PICK_LOW["Pick oldest low-priority task"]
    LOW -->|No| IDLE["No tasks — wait or self-generate"]

    PICK_HIGH --> ACTIVATE
    PICK_NORMAL --> ACTIVATE
    PICK_LOW --> ACTIVATE

    ACTIVATE["Move to In Progress [~]<br/>Create workspace branch<br/>Link branch in TODO entry"]
```

### Task Sources

```mermaid
graph TD
    HUMAN["👤 Human / Admin"] -->|"direct command"| TODO["Agent's TODO.md"]
    ADMIN["🔧 UncleBob<br/>(AdminAgent)"] -->|"task dispatch"| TODO
    SELF["🤖 Self-generated<br/>(during work)"] -->|"discovered sub-task"| TODO

    OTHER["Other Workers"] -.-x|"❌ Not accepted"| TODO

    style OTHER fill:#ffebee,stroke:#c62828
```

**Rule:** Workers only accept tasks from Human, AdminAgent (UncleBob), or self-generated. Tasks from other workers are not accepted.

---

## 7. Complete Task Execution Flow

End-to-end flow of how a worker agent picks up and completes a task:

```mermaid
flowchart TD
    SESSION["🟢 Session Start"] --> BOOTSTRAP["Bootstrap:<br/>clone/pull all 3 repos"]
    BOOTSTRAP --> READ_TODO["Read TODO.md"]
    READ_TODO --> PICK["Pick highest-priority oldest task"]
    PICK --> MARK_IP["Mark task [~] In Progress"]

    MARK_IP --> CREATE_BRANCH["Create workspace branch<br/><code>&lt;agent-name&gt;-YYYYMMDD-description</code>"]
    CREATE_BRANCH --> SEARCH_MEM["Search memory for context<br/>(hot → warm → cold → git log)"]
    SEARCH_MEM --> WORK["Do the work<br/>(code, configs, docs, etc.)"]

    WORK --> COMMIT_WS["Commit & push to workspace branch<br/>(frequent commits)"]
    COMMIT_WS --> MORE{"More work needed?"}
    MORE -->|Yes| WORK
    MORE -->|No| SAVE_MEM["Save memory note<br/><code>YYYY-MM-DD-topic.md</code>"]

    SAVE_MEM --> COMMIT_MEM["Commit & push to agent-memory"]
    COMMIT_MEM --> MARK_DONE["Mark task [x] Done in TODO.md<br/>Add completion date & branch ref"]
    MARK_DONE --> PUSH_TODO["Commit & push TODO.md"]

    PUSH_TODO --> EXTERNAL{"Output for<br/>external sharing?"}
    EXTERNAL -->|Yes| PUSH_OUT["Push to agent-outbound"]
    EXTERNAL -->|No| NEXT["Pick next task or wait"]
    PUSH_OUT --> NEXT

    style SESSION fill:#e8f5e9,stroke:#2e7d32
    style MARK_DONE fill:#e8f5e9,stroke:#2e7d32
```

---

## 8. Data Flow Summary

```mermaid
graph TB
    subgraph "Agent Pod (Ephemeral)"
        BRAIN["🧠 Agent LLM"]
        LOCAL_MEM["/agent-memory<br/>(local clone)"]
        LOCAL_WS["/agent-workspaces<br/>(local clone)"]
        LOCAL_OUT["/agent-outbound<br/>(local clone)"]
    end

    subgraph "GitHub (Persistent)"
        GIT_MEM["agent-memory<br/>📝 Knowledge + TODO"]
        GIT_WS["agent-workspaces<br/>🔧 Deliverables"]
        GIT_OUT["agent-outbound<br/>📤 Public output"]
    end

    subgraph "Inputs"
        HUMAN["👤 Human"]
        ADMIN["🔧 UncleBob"]
    end

    subgraph "AWS Sandbox"
        SANDBOX["☁️ Sandbox Resources"]
    end

    HUMAN -->|"commands"| BRAIN
    HUMAN -->|"commands"| ADMIN
    ADMIN -->|"task dispatch"| BRAIN

    BRAIN <-->|"read/write"| LOCAL_MEM
    BRAIN <-->|"read/write"| LOCAL_WS
    BRAIN <-->|"read/write"| LOCAL_OUT

    LOCAL_MEM <-->|"sync"| GIT_MEM
    LOCAL_WS <-->|"sync"| GIT_WS
    LOCAL_OUT <-->|"sync"| GIT_OUT

    BRAIN -->|"deploy via IAM"| SANDBOX
```

---

## Quick Reference

| What | Where | Persists? |
|---|---|---|
| Task backlog | `agent-memory/TODO.md` | ✅ Git |
| Task notes & learnings | `agent-memory/*.md` | ✅ Git (archived over time) |
| Work-in-progress code/docs | `agent-workspaces/<branch>` | ✅ Git |
| External-facing documents | `agent-outbound/main` | ✅ Git |
| Local filesystem | `/home/agent/*` | ❌ Lost on pod restart |
| Git commit history | All repos | ✅ Permanent & searchable |
