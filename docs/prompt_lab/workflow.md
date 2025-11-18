# Prompt Lab Workflow

This workspace keeps experimentation assets out of production Swift code while making it easy to iterate on the transcript-structuring prompt.

## Roles & Responsibilities

| Agent | Responsibilities | Input | Output |
| --- | --- | --- | --- |
| **Orchestrator** | Picks transcripts from the dataset, tracks prompt versions, decides when to branch experiments. | `dataset.json`, prompt version metadata | Run queue, temperature plan |
| **Executor** | Calls the API with the current prompt and transcript batch, captures latency/token stats, stores raw outputs. | Transcripts, prompt text, run config | `runs/<version>/outputs.jsonl` |
| **Critic** | Scores every output using the rubric (coverage, structure, bilingual fidelity, skim time). Suggests targeted feedback per transcript. | Transcript, output, rubric | `runs/<version>/critique.md` |
| **Synthesizer** | Reads critiques, clusters failure modes, proposes prompt edits or experimental knobs (temperature, formatting hints). | Critic notes, history log | Proposed prompt diffs + hypotheses |
| **Historian** | Logs prompt versions, dataset changes, and accepted hypotheses. Surfaces regression warnings. | All artifacts | `history.md`, changelog sections |

This mirrors a Senior Manager overseeing an AI org: people (agents) run the loop, you approve merges.

## Experiment Loop

1. **Select Batch** – Orchestrator samples at least three transcripts that stress different failure modes (single thread, branching, emotional, bilingual, noisy). Each batch must include one regression case from the previous run.
2. **Execute** – Executor runs the current prompt across the batch with deterministic (`temperature=0`) and exploratory (`temperature=0.4`) sweeps. Outputs are written as JSON Lines for reproducibility.
3. **Critique** – Critic applies the rubric below, adds 1–5 scores per dimension, and tags each run with “pass / needs-attention / fail”.
4. **Synthesize** – Synthesizer proposes at most two prompt edits at a time, each with a hypothesis (“If we explicitly ask for Main Summary + Modules, the branching transcripts will stabilize”). They also note UI-alignment tweaks (e.g., bullet density, sidebars).
5. **Approve & Re-run** – Orchestrator (you) reviews proposals, merges one, increments prompt version, and the loop restarts with the full dataset to catch regressions.

## Rubric Snapshot

1. **Structure Detection** – Did the output collapse into a single paragraph when appropriate? Did it introduce Main Summary + sections when multiple storylines exist? (T1 vs. T2)
2. **Canon Fidelity** – Were all canon ideas preserved, especially flagged headings like `# 核心主线`? (T4)
3. **Actionability** – Are concrete ideas and decisions surfaced as bullets or tagged paragraphs? (T3, T5)
4. **Language Integrity** – Does the bilingual mix remain, with minimal hallucinated English or Mandarin? (T1, T3)
5. **Skim Efficiency** – Estimate the seconds required for future-you to re-capture the key point. Goal < 12s for multi-section outputs.

## Files & Automation Hints

- `dataset.json` – canonical evaluation set (extend when new failure modes appear).
- `runs/` – create folders like `runs/prompt_v2/outputs.jsonl` via Executor scripts (not committed yet).
- `prompt_v2.md` – latest prompt text (see below).
- `dashboard.html` – quick visualization of dataset coverage + latest results.

Suggested CLI helpers (can live in `scripts/`):

```bash
python scripts/run_executor.py --prompt prompts/prompt_v2.md --dataset docs/prompt_lab/dataset.json --temperature 0
python scripts/score_runs.py --run runs/prompt_v2 --rubric docs/prompt_lab/rubric.yaml
```

Because automation is outside production Swift code, you can tweak freely without risking App Store builds.
