Below is a **multi-agent DAG specification** for the **Autonomous Sandwich Builder** workflow, formatted in a way that can map directly to agent orchestration frameworks (LangGraph-style, temporal-style, or a custom event-driven runtime).

---

## Multi-Agent DAG: Sandwich Builder

### High-Level Graph

```
            ┌─────────────────┐
            │   User Input    │
            └────────┬────────┘
                     ↓
            ┌─────────────────┐
            │   Intent Agent   │
            └────────┬────────┘
                     ↓
            ┌─────────────────┐
            │ Recipe RAG Agent │
            └────────┬────────┘
                     ↓
            ┌─────────────────┐
            │ Inventory Agent  │
            └────────┬────────┘
                     ↓
            ┌──────────────────────┐
            │ Substitution Agent   │
            └────────┬─────────────┘
                     ↓
            ┌──────────────────────┐
            │ Execution Planner    │
            └────────┬─────────────┘
                     ↓
            ┌──────────────────────┐
            │ Quality Reviewer     │
            └───────┬──────────────┘
                    │
        (fail) ─────┘
                    ↓
                (loop to RAG)
```

---

## DAG Specification (YAML)

```yaml
version: "1.0"

workflow: sandwich_agent_pipeline

inputs:
  - user_request

state:
  intent_struct: null
  candidate_recipes: []
  inventory: {}
  substitutions: {}
  execution_plan: null
  validation_score: null

nodes:

  - id: intent_agent
    type: llm_agent
    description: Extract constraints and preferences
    input:
      - user_request
    output:
      - intent_struct

  - id: recipe_rag_agent
    type: rag_agent
    description: Retrieve candidate sandwich recipes
    input:
      - intent_struct
    output:
      - candidate_recipes

  - id: inventory_agent
    type: tool_agent
    description: Query available ingredients
    tools:
      - get_inventory
    input:
      - candidate_recipes
    output:
      - inventory

  - id: substitution_agent
    type: llm_agent
    description: Replace missing ingredients
    input:
      - candidate_recipes
      - inventory
    output:
      - substitutions

  - id: execution_planner
    type: llm_agent
    description: Generate preparation steps
    input:
      - candidate_recipes
      - substitutions
    output:
      - execution_plan

  - id: quality_reviewer
    type: eval_agent
    description: Validate nutrition and constraints
    input:
      - execution_plan
      - intent_struct
    output:
      - validation_score

edges:

  - from: intent_agent
    to: recipe_rag_agent

  - from: recipe_rag_agent
    to: inventory_agent

  - from: inventory_agent
    to: substitution_agent

  - from: substitution_agent
    to: execution_planner

  - from: execution_planner
    to: quality_reviewer

conditional_edges:

  - from: quality_reviewer
    condition: validation_score < 0.8
    to: recipe_rag_agent

outputs:
  - execution_plan
```

---

## Agent Execution Contracts (Minimal)

### Intent Agent

**Input**

```json
{
  "user_request": "high protein sandwich under 600 calories"
}
```

**Output**

```json
{
  "protein_level": "high",
  "calories_max": 600
}
```

---

### Recipe RAG Agent

**Responsibilities**

* Embed query
* Retrieve top-k recipes
* Return structured recipe objects

---

### Inventory Tool Contract

```json
{
  "tool": "get_inventory",
  "returns": {
    "ingredients": []
  }
}
```

---

### Quality Reviewer (Eval Pattern)

Checks:

* Constraint satisfaction
* Missing steps
* Logical consistency

Returns:

```json
{
  "validation_score": 0.92
}
```

---

## Parallelization Opportunities (Important for Real Systems)

The DAG can be optimized:

**Parallel branches**

* Nutrition estimation agent
* Cost estimation agent
* Taste profile agent

Example:

```
execution_planner
     ↓
 ┌────┼────┐
 ↓    ↓    ↓
nutrition cost taste
     ↓
quality_reviewer
```

