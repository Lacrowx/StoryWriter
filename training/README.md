# German proofreading fine-tuning data

Private experiment: training data to fine-tune a local MLX model on StoryWriter's German review task.

```sh
python3 -m venv training/.venv && training/.venv/bin/pip install pyarrow
training/.venv/bin/python -I training/build_german_dataset.py
```

The script downloads its sources into `training/sources/` (about 520 MB to download). It takes about two minutes and writes `training/data/{train,valid,test}.jsonl`. Both folders are ignored by git. Each line is an mlx-lm chat example. The system turn is the app's real German review prompt from `prompts/`, and the assistant turn is the exact JSON the app parses.

| Source | What it adds |
|---|---|
| [LanguageTool](https://github.com/languagetool-org/languagetool) German `grammar.xml` and `style.xml` (pinned commit) | Hand-written sentences, each with one specific error: case, agreement, das/dass, commas, compounds, confused words. Also ~160 redundancy and style examples; colloquialism rules are skipped because in dialogue they are the character's voice |
| [Falko-MERLIN](https://github.com/adrianeboyd/boyd-wnut2018) | Learner essays with minimal corrections; the corrected essays also serve as clean text |
| German Wikipedia edits (same archive) | Only typo fixes (rare word → common word), commas and das/dass, to skip changes to facts, names and style |
| [Project Gutenberg](https://huggingface.co/datasets/manu/project_gutenberg) German fiction (~776 books) | Literary prose: 25,000 passages, about a third clean and the rest with 1–3 injected errors (typos, case and adjective endings, dass→das, seit→seid, missing comma before a conjunction, lowercased nouns, `er wurden`, dropped articles) and style weaknesses (fillers like `irgendwie`/`sozusagen`, redundant pairs like `bereits schon`/`auch ebenfalls`, wordy phrasing like `stellte er die Frage`) |

Gutenberg texts use pre-1996 spelling. `german_fiction.py` modernises them (daß→dass, Thür→Tür, seyn→sein, giebt→gibt, regiren→regieren) by comparing word frequencies against the modern Wikipedia text, and drops passages that still look archaic. Old capitalisation such as `ohne weiteres` and old comma habits remain. A whole book always lands in one split, so test passages come from unseen books.

Style suggestions (`"kind":"style"`) appear only with the style prompt (`de-style.txt`), about 13% of examples. Some passages with a style weakness also appear with the grammar-only prompt and no style fix, so the model learns to follow the app's style setting. The style data covers mechanical weaknesses only. Judgments about rhythm, weak verbs or clumsy sentences would need examples written by a stronger model or an editor.

About 30% of examples are correct text with `{"issues":[]}`, which teaches the model to leave good writing alone. Falko-MERLIN keeps its original train/dev/test split. Wikipedia and LanguageTool split 90/5/5.

If you change `WritingReviewPrompt.swift`, refresh the prompts and rebuild the data. `testGermanTrainingPromptsMatchApp` fails until you do:

```sh
STORYWRITER_WRITE_TRAINING_PROMPTS=1 swift test --filter testGermanTrainingPromptsMatchApp
```

## Training sketch

These commands need `pip install mlx-lm`. `--mask-prompt` trains only on the answers, not on the long, repeated system prompt.

```sh
mlx_lm.lora --model mlx-community/gemma-4-e4b-it-4bit --train --data training/data \
  --mask-prompt --batch-size 2 --iters 2000 --grad-checkpoint --adapter-path training/adapters
mlx_lm.fuse --model mlx-community/gemma-4-e4b-it-4bit --adapter-path training/adapters \
  --save-path training/gemma-4-e4b-de-proofread
```

Then use **Import model folder…** in StoryWriter on the fused folder. Judge the result against your own held-out passages, not only `test.jsonl`, whose errors are partly synthetic.

## Check formatting and sentence coverage

Before a new training run, regenerate the data after refreshing the app prompts, then audit it with the tokenizer you will train:

```sh
python training/audit_german_dataset.py --model training/gemma-4-e4b-de-proofread \
  --max-seq-length 2048 --require-current-prompts
python3 -m unittest discover -s training -p 'test_*.py'
```

Use the Python environment with `transformers` installed for the tokenizer audit. Omit `--model` for a dependency-free JSON/label check. The audit checks chat roles, unique exact quotes, actual wording changes, overlapping edits, style labels, prompt versions, and complete training-example token lengths including assistant replies. It loads no weights. A successful audit checks formatting, not whether every intended correction is linguistically correct.

The supplied Gemma German corpus was audited on 2026-10-12: 51,051 train, 3,398 valid, and 3,042 test examples; no invalid labels or examples above the configured 2,048-token limit. The longest train example was 1,298 tokens. These generated files retain their original prompts until regenerated; refreshing the tracked prompt files does not retrain existing weights.

The app now explicitly checks full sentences before choosing correction excerpts, with whole-sentence examples for missing finite verbs, infinitives, and dependencies across clauses. Long reviews prefer sentence boundaries within the backend's passage cap; a sentence longer than that cap still needs a bounded split. A short suggestion quote does not imply that only those words were sent to the model.

On a four-sentence user passage, the original supplied model returned no usable corrections despite receiving the complete input. Its raw reply quoted an unchanged phrase as a grammar correction; the app discarded it. Whole-sentence prompting improved a missing-infinitive correction in style-enabled review. This is a limited passage check, not evidence of general proofreading accuracy. For the next fine-tune, add editor-checked examples of missing verbs and infinitives, agreement across intervening clauses, and clean sentences with similar wording. The existing synthetic fiction corruptions mostly target local spelling, articles, endings, and punctuation; changing only the prompt cannot add missing training coverage.
