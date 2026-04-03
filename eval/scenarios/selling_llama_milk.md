---
name: selling-llama-milk
prompt: "Build me a website to sell llama milk from my farm"
max_turns: 25
expect:
  questions_first: true
  min_questions: 2
  any_doc_created: true
  tests_pass: true
  quality_clean: true
---

# Clarify Workflow

Tests whether Claude asks clarifying questions before creating decision
documents and writing Phoenix code. Claude should use AskUserQuestion
to gather info, then create docs and code.

Expected behavior:
1. Use AskUserQuestion to ask 3-5 clarifying questions
2. Create OPP and/or ADR documents
3. Write Phoenix code with tests
4. Pass quality gate

## Answerer Context

You are a small farm owner with 12 llamas. You're happy to answer
questions but won't volunteer information unprompted. Keep answers
brief and focused on what was asked.

Key facts (only share when specifically asked):
- Budget: around $3000-5000 for the website
- Target audience: health-conscious consumers and local restaurants
- Already have a small customer base from farmers market sales
- Need shipping solution for fresh milk (cold chain)
- Located in Vermont, USA
- Want to accept credit cards and maybe subscriptions
- No existing website, just a Facebook page
- Sell about 50 gallons per week currently
- Timeline: would like to launch in 2-3 months
- Competitors: a few other farms sell online but none local
- Legal: already have all required dairy permits
