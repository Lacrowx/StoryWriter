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
