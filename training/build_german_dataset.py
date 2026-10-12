#!/usr/bin/env python3
"""Build German proofreading fine-tuning data in StoryWriter's review format.

Writes mlx-lm chat JSONL (train/valid/test) whose assistant turns are exactly
the JSON the app parses: {"issues":[{"original","replacement","kind"}]}.

Sources (downloaded into training/sources on first run):
  - LanguageTool German grammar.xml: hand-written wrong/right example sentences
  - Falko-MERLIN: learner essays with minimal corrections (Boyd 2018)
  - German Wikipedia edits, filtered to small spelling/grammar fixes (Boyd 2018)
  - Public-domain German fiction from Project Gutenberg, modernised, with
    injected errors and as clean text (see german_fiction.py)

Usage: training/.venv/bin/python -I training/build_german_dataset.py
"""
import argparse
import difflib
import json
import os
import random
import re
import sys
import tarfile
import urllib.request
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import german_fiction  # noqa: E402
from audit_german_dataset import validate_example  # noqa: E402

ROOT = Path(__file__).resolve().parent
SOURCES = ROOT / "sources"
LT_COMMIT = "5d0395ff0dfdfb4d41c766a1a7eae8dbd02259a5"
LT_URL = f"https://raw.githubusercontent.com/languagetool-org/languagetool/{LT_COMMIT}/languagetool-language-modules/de/src/main/resources/org/languagetool/rules/de/{{}}.xml"
FM_URL = "https://github.com/adrianeboyd/boyd-wnut2018/releases/download/wnut2018/data.tar.gz"
# Categories that are real errors in prose; style, typography, dates,
# letter conventions and joke rules are left out.
LT_CATEGORIES = {"GRAMMAR", "TYPOS", "CASING", "COMPOUNDING", "CONFUSED_WORDS", "PUNCTUATION",
                 "HILFESTELLUNG_KOMMASETZUNG", "MULTITOKEN_SPELLING", "IDIOMS"}
LT_SPELLING = {"TYPOS", "CASING", "COMPOUNDING", "MULTITOKEN_SPELLING"}
# Style rules worth suggesting in fiction. Colloquialisms are left out: in
# dialogue they are usually the character's voice.
LT_STYLE = {"REDUNDANCY", "STYLE"}


def fetch(url, path):
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        print(f"Downloading {url}")
        urllib.request.urlretrieve(url, path)
    return path


# ---------------------------------------------------------------- issues

def word_spans(text):
    return [m.span() for m in re.finditer(r"\S+", text)]


def make_issues(passage, edits, kind):
    """Turn character edits (start, end, replacement) into app issues.

    Each excerpt grows by whole words until it contains a word beyond the
    edit and occurs exactly once; overlapping excerpts are merged. Returns
    None when no unique excerpt exists.
    """
    spans = word_spans(passage)
    groups = []
    for start, end, repl in sorted(edits):
        a = max([s for s, e in spans if s <= start] or [0])
        b = min([e for s, e in spans if e >= end] or [len(passage)])
        groups.append([a, b, [(start, end, repl)]])
    changed = True
    while changed:
        changed = False
        for g in groups:
            while True:
                excerpt = passage[g[0]:g[1]]
                words = [w for w in re.findall(r"\w+", excerpt)]
                if passage.count(excerpt) == 1 and len(words) >= 2:
                    break
                before = [s for s, e in spans if e < g[0] + 1 and s < g[0]]
                after = [e for s, e in spans if s > g[1] - 1 and e > g[1]]
                if not before and not after:
                    return None
                if after and (len(words) % 2 == 0 or not before):
                    g[1] = min(after)
                else:
                    g[0] = max(before)
        groups.sort()
        for i in range(len(groups) - 1):
            if groups[i][1] >= groups[i + 1][0]:
                groups[i] = [groups[i][0], max(groups[i][1], groups[i + 1][1]), groups[i][2] + groups[i + 1][2]]
                del groups[i + 1]
                changed = True
                break
    issues = []
    for a, b, parts in groups:
        replacement, cursor = "", a
        for start, end, repl in sorted(parts):
            replacement += passage[cursor:start] + repl
            cursor = end
        replacement += passage[cursor:b]
        original = passage[a:b]
        if original.strip() == replacement.strip():
            continue
        issues.append({"original": original, "replacement": replacement, "kind": kind(original, replacement, parts)})
    return issues


def char_edits(src, tgt):
    """Character edits turning src into tgt, aligned on whole tokens."""
    a, b = re.findall(r"\S+|\s+", src), re.findall(r"\S+|\s+", tgt)
    offsets, pos = [], 0
    for t in a:
        offsets.append(pos)
        pos += len(t)
    offsets.append(pos)
    edits = []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if op != "equal":
            edits.append((offsets[i1], offsets[i2], "".join(b[j1:j2])))
    return edits


def kind_for(original, replacement, parts=()):
    # One misspelled word (not just a changed ending) or a case change is
    # spelling; endings, added/removed words and punctuation are grammar.
    if original.lower() == replacement.lower():
        return "spelling"
    o, r = re.findall(r"\w+", original), re.findall(r"\w+", replacement)
    if len(o) == len(r) and sum(x != y for x, y in zip(o, r)) == 1:
        x, y = next((x, y) for x, y in zip(o, r) if x != y)
        prefix = len(os.path.commonprefix([x, y]))
        if prefix < min(len(x), len(y)) - 1:
            return "spelling"
    return "grammar"


# ---------------------------------------------------------------- sources

def detokenize(tokens):
    text = ""
    for t in tokens:
        if text and not (t in {",", ".", ";", ":", "!", "?", ")", "]", "“", "%"} or text.endswith(("(", "[", "„"))):
            text += " "
        text += t
    return text


def languagetool(name="grammar", categories=LT_CATEGORIES):
    root = ET.parse(fetch(LT_URL.format(name), SOURCES / f"languagetool-de-{name}.xml")).getroot()
    wrong, right = [], []
    for category in root.iter("category"):
        cid = category.get("id")
        if cid not in categories or category.get("default") == "off":
            continue
        for rule in category.iter("rule"):
            if rule.get("default") == "off" or "picky" in (rule.get("tags") or ""):
                continue
            for ex in rule.iter("example"):
                text = "".join(ex.itertext()).strip()
                if not text or len(text) > 400 or "\n" in text:
                    continue
                marker = ex.find("marker")
                if ex.get("correction") is None:
                    if ex.get("type") in (None, "correct") and marker is None:
                        right.append(text)
                    continue
                if marker is None:
                    continue
                prefix = (ex.text or "").lstrip()
                bad = "".join(marker.itertext())
                fix = ex.get("correction").split("|")[0]
                if not bad or not fix or fix == bad or "\\" in fix or "ehemals" in fix:
                    continue
                start = len(prefix)
                kind = "style" if cid in LT_STYLE else "spelling" if cid in LT_SPELLING else "grammar"
                wrong.append((text, [(start, start + len(bad), fix)], kind))
    return wrong, right


def fm_and_wiki():
    tar = fetch(FM_URL, SOURCES / "boyd-wnut2018-data.tar.gz")
    out = SOURCES / "boyd-wnut2018"
    if not (out / "data").exists():
        with tarfile.open(tar) as t:
            members = [m for m in t.getmembers() if m.isfile() or m.isdir()]
            if any(m.name.startswith("/") or ".." in Path(m.name).parts for m in members):
                raise SystemExit("Unexpected paths in the Falko-MERLIN archive.")
            t.extractall(out, members=members)
    return out / "data"


def read_pairs(src, tgt):
    with open(src, encoding="utf-8") as s, open(tgt, encoding="utf-8") as t:
        for a, b in zip(s, t):
            ta, tb = a.split(), b.split()
            if '"' in ta or '"' in tb or not ta:
                continue
            yield detokenize(ta), detokenize(tb)


def word_counts(path):
    counts = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            for w in line.split():
                counts[w] = counts.get(w, 0) + 1
    return counts


def small_wiki_edit(src, tgt, freq):
    # Wikipedia revisions also change facts, names and one valid spelling for
    # another. Keep commas, das/dass, and fixes of a rare (misspelled) word
    # to a common one; that leaves numbers, names and style choices alone.
    if re.findall(r"\d+", src) != re.findall(r"\d+", tgt) or len(src) < 30:
        return False
    a, b = src.split(), tgt.split()
    ops = [o for o in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes() if o[0] != "equal"]
    if not ops or len(ops) > 2:
        return False
    for op, i1, i2, j1, j2 in ops:
        x, y = " ".join(a[i1:i2]), " ".join(b[j1:j2])
        if {x, y} <= {",", ""} or {x.lower(), y.lower()} == {"das", "dass"}:
            continue
        if op != "replace" or i2 - i1 != 1 or j2 - j1 != 1 or not x.isalpha() or not y.isalpha():
            return False
        if freq.get(x, 0) >= 5 or freq.get(y, 0) < 20:
            return False
        if x.lower() != y.lower() and (difflib.SequenceMatcher(None, x, y).ratio() < 0.75 or x[0].isupper() != y[0].isupper()):
            return False
    return True


# ---------------------------------------------------------------- assembly

def example(passage, issues, prompt):
    return {"messages": [
        {"role": "system", "content": prompt},
        {"role": "user", "content": passage},
        {"role": "assistant", "content": json.dumps({"issues": issues}, ensure_ascii=False, separators=(",", ":"))},
    ]}


def from_pairs(pairs, prompts, rng, max_sentences=4):
    """Group consecutive sentence pairs into short passages."""
    examples, i = [], 0
    while i < len(pairs):
        n = rng.randint(1, max_sentences)
        chunk = pairs[i:i + n]
        i += n
        src = " ".join(s for s, _ in chunk)
        edits, offset = [], 0
        for s, t in chunk:
            edits += [(a + offset, b + offset, r) for a, b, r in char_edits(s, t)]
            offset += len(s) + 1
        issues = make_issues(src, edits, kind_for) if edits else []
        if issues is not None:
            examples.append(example(src, issues, rng.choice(prompts)))
    return examples


def clean_passages(sentences, count, prompts, rng):
    """Correct text with an empty answer, so the model learns restraint."""
    examples, i = [], 0
    while i < len(sentences) and len(examples) < count:
        n = rng.randint(1, 4)
        examples.append(example(" ".join(sentences[i:i + n]), [], rng.choice(prompts)))
        i += n
    return examples


def from_languagetool(wrong, right, prompts, rng):
    """Mix 1-3 erroneous and 0-2 correct example sentences into passages,
    plus clean-only passages so the model learns to leave good text alone."""
    rng.shuffle(wrong)
    rng.shuffle(right)
    clean = iter(right)
    examples, i = [], 0
    while i < len(wrong):
        parts = [(True, w) for w in wrong[i:i + rng.randint(1, 3)]]
        i += len(parts)
        parts += [(False, s) for s in (next(clean, None) for _ in range(rng.randint(0, 2))) if s]
        rng.shuffle(parts)
        passage, edits, kinds = "", [], {}
        for is_wrong, item in parts:
            passage += " " if passage else ""
            if is_wrong:
                text, item_edits, kind = item
                for a, b, r in item_edits:
                    edits.append((a + len(passage), b + len(passage), r))
                    kinds[a + len(passage)] = kind
                passage += text
            else:
                passage += item
        issues = make_issues(passage, edits, lambda o, r, ps: "spelling" if all(kinds[p[0]] == "spelling" for p in ps) else "grammar")
        if issues:
            examples.append(example(passage, issues, rng.choice(prompts)))
    rest = list(clean)
    for _ in range(len(examples) // 3):
        if not rest:
            break
        n = rng.randint(1, 3)
        examples.append(example(" ".join(rest[:n]), [], rng.choice(prompts)))
        rest = rest[n:]
    return examples


def validate(ex):
    validate_example(ex)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--wiki-limit", type=int, default=10000, help="filtered Wikipedia edit pairs to use (default 10000)")
    parser.add_argument("--fiction", type=int, default=25000, help="Gutenberg fiction passages to use (default 25000; 0 skips)")
    parser.add_argument("--per-book", type=int, default=60, help="maximum passages per book (default 60)")
    parser.add_argument("--out", type=Path, default=ROOT / "data")
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()
    rng = random.Random(args.seed)
    style_prompt, grammar_prompt = [(ROOT / "prompts" / name).read_text(encoding="utf-8") for name in ("de-style.txt", "de-grammar.txt")]
    prompts = [style_prompt, grammar_prompt]

    splits = {"train": [], "valid": [], "test": []}
    data = fm_and_wiki()
    for split, name in (("train", "train"), ("valid", "dev"), ("test", "test")):
        pairs = list(read_pairs(data / f"fm-{name}.src", data / f"fm-{name}.trg"))
        # Drop heavy rewrites of beginner text; they teach paraphrasing.
        pairs = [(s, t) for s, t in pairs if difflib.SequenceMatcher(None, s, t).ratio() > 0.75]
        examples = from_pairs(pairs, prompts, rng)
        # The corrected essays double as clean text.
        splits[split] += examples + clean_passages([t for _, t in pairs], len(examples) // 2, prompts, rng)
    counts = {"falko-merlin": sum(map(len, splits.values()))}

    wiki, wiki_clean = [], []
    freq = word_counts(data / "wiki.1M.trg")
    for s, t in read_pairs(data / "wiki.1M.src", data / "wiki.1M.trg"):
        if small_wiki_edit(s, t, freq):
            wiki.append((s, t))
            if len(wiki) >= args.wiki_limit:
                break
        elif len(wiki_clean) < args.wiki_limit and len(t) > 40 and t.endswith("."):
            wiki_clean.append(t)
    wiki_examples = from_pairs(wiki, prompts, rng, max_sentences=1)
    wiki_examples += clean_passages(wiki_clean, len(wiki_examples) // 3, prompts, rng)
    counts["wikipedia"] = len(wiki_examples)

    if args.fiction:
        counts["fiction"] = 0
        modernizer = german_fiction.Modernizer(freq)
        known = modernizer.known
        for book, body in german_fiction.books(fetch, SOURCES):
            if counts["fiction"] >= args.fiction:
                break
            # Whole books go to one split, so test passages come from unseen books.
            bucket = zlib.crc32(book.encode()) % 20
            split = "valid" if bucket == 0 else "test" if bucket == 1 else "train"
            for text in german_fiction.passages(body, modernizer, args.per_book, rng):
                counts["fiction"] += 1
                if rng.random() < 0.3:
                    splits[split].append(example(text, [], rng.choice(prompts)))
                    continue
                style = int(rng.random() < 0.6)
                errors = rng.choice([0, 1, 1, 2, 2, 3]) if style else rng.choice([1, 1, 2, 2, 3])
                wrong, edits, style_starts = german_fiction.corrupt(text, rng, known, errors, style)
                if not edits:
                    splits[split].append(example(text, [], rng.choice(prompts)))
                    continue
                kind = lambda o, r, parts: "style" if all(p[0] in style_starts for p in parts) else kind_for(o, r)
                issues = make_issues(wrong, edits, kind)
                if issues is None:
                    continue
                if not style_starts:
                    splits[split].append(example(wrong, issues, rng.choice(prompts)))
                    continue
                splits[split].append(example(wrong, issues, style_prompt))
                # The same weakness under the grammar-only prompt stays untouched.
                if rng.random() < 0.3:
                    grammar_issues = make_issues(wrong, [e for e in edits if e[0] not in style_starts], kind_for)
                    if grammar_issues is not None and not any(i["kind"] == "style" for i in grammar_issues):
                        splits[split].append(example(wrong, grammar_issues, grammar_prompt))

    wrong, right = languagetool()
    lt_examples = from_languagetool(wrong, right, prompts, rng)
    for text, edits, _ in languagetool("style", LT_STYLE)[0]:
        issues = make_issues(text, edits, lambda o, r, parts: "style")
        if issues:
            lt_examples.append(example(text, issues, style_prompt))
            if rng.random() < 0.5:
                lt_examples.append(example(text, [], grammar_prompt))
    counts["languagetool"] = len(lt_examples)

    for examples in (wiki_examples, lt_examples):
        rng.shuffle(examples)
        n = len(examples) // 20
        splits["valid"] += examples[:n]
        splits["test"] += examples[n:2 * n]
        splits["train"] += examples[2 * n:]

    args.out.mkdir(parents=True, exist_ok=True)
    for split, examples in splits.items():
        rng.shuffle(examples)
        for ex in examples:
            validate(ex)
        with open(args.out / f"{split}.jsonl", "w", encoding="utf-8") as f:
            for ex in examples:
                f.write(json.dumps(ex, ensure_ascii=False) + "\n")
    clean = sum(ex["messages"][2]["content"] == '{"issues":[]}' for exs in splits.values() for ex in exs)
    styled = sum('"kind":"style"' in ex["messages"][2]["content"] for exs in splits.values() for ex in exs)
    total = sum(map(len, splits.values()))
    print("Examples by source:", counts)
    print("Split sizes:", {k: len(v) for k, v in splits.items()}, f"({clean / total:.0%} with no changes, {styled / total:.0%} with style suggestions)")
    print("Wrote", args.out)


if __name__ == "__main__":
    main()
