---
name: create-opp-doc
prompt: "I want to sell llama milk online."
max_turns: 50
expect:
  questions_first: true
  min_questions: 1
  any_doc_created: true
  tests_pass: false
  quality_clean: false
---

# Simple doc creation

Minimal scenario: just ask questions and create one OPP document.
Validates the questions → docs pipeline without code generation.

## Answerer Context

You are a small farm owner with 12 llamas. Budget $3-5k.
Located in Vermont. Sell 50 gallons/week at farmers markets.
