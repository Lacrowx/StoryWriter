#!/usr/bin/env python3
"""Audit chat JSONL before fine-tuning; optionally check complete token lengths.

No model weights are loaded. With --model, requires the training environment's
transformers tokenizer. Exits nonzero for malformed labels or clipped examples.
"""
import argparse
import json
from pathlib import Path


def validate_example(example):
    messages = example['messages']
    if [m['role'] for m in messages] != ['system', 'user', 'assistant']:
        raise ValueError('Expected system, user, assistant turns')
    if not all(isinstance(m['content'], str) and m['content'].strip() for m in messages):
        raise ValueError('Every turn needs nonempty text')
    passage = messages[1]['content']
    response = json.loads(messages[2]['content'])
    if not isinstance(response, dict) or not isinstance(response.get('issues'), list):
        raise ValueError('Expected a JSON object with an issues array')
    ranges = []
    for issue in response['issues']:
        if not isinstance(issue, dict) or not all(isinstance(issue.get(k), str) for k in ('original', 'replacement', 'kind')):
            raise ValueError('Every issue needs original, replacement and kind strings')
        quote = issue['original']
        if not quote or passage.count(quote) != 1:
            raise ValueError('Original must quote a nonempty, unique input excerpt')
        if quote.split() == issue['replacement'].split():
            raise ValueError('Unchanged or whitespace-only correction')
        if issue['kind'] not in ('grammar', 'spelling', 'style'):
            raise ValueError('Unknown correction kind')
        if 'keine optionalen Stiländerungen' in messages[0]['content'] and issue['kind'] == 'style':
            raise ValueError('Style correction under grammar-only prompt')
        start = passage.index(quote)
        ranges.append((start, start + len(quote)))
    ranges.sort()
    if any(a[1] > b[0] for a, b in zip(ranges, ranges[1:])):
        raise ValueError('Overlapping correction excerpts')
    return messages


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', type=Path, default=Path(__file__).parent / 'data')
    parser.add_argument('--model', type=Path, help='Local model tokenizer folder; never loads weights')
    parser.add_argument('--max-seq-length', type=int, default=2048)
    parser.add_argument('--require-current-prompts', action='store_true', help='Fail if generated data uses older app prompts')
    args = parser.parse_args()
    if args.max_seq_length <= 0:
        parser.error('--max-seq-length must be positive')
    prompt_directory = Path(__file__).parent / 'prompts'
    current_prompts = {p.read_text(encoding='utf-8') for p in prompt_directory.glob('de-*.txt')}
    tokenizer = None
    if args.model:
        from transformers import AutoTokenizer
        tokenizer = AutoTokenizer.from_pretrained(args.model, local_files_only=True)
    failures = 0
    for split in ('train', 'valid', 'test'):
        lengths, count, invalid, clipped, stale = [], 0, 0, 0, 0
        prompts = set()
        for line_number, line in enumerate((args.data / f'{split}.jsonl').open(encoding='utf-8'), 1):
            count += 1
            try:
                messages = validate_example(json.loads(line))
                prompts.add(messages[0]['content'])
                stale += messages[0]['content'] not in current_prompts
                if tokenizer:
                    # Match mlx-lm's ChatDataset, including the assistant JSON.
                    tokens = tokenizer.apply_chat_template(messages, tokenize=True, return_dict=False)
                    lengths.append(len(tokens))
                    clipped += len(tokens) > args.max_seq_length
            except (ValueError, KeyError, TypeError) as error:
                invalid += 1
                if invalid <= 5:
                    print(f'{split}:{line_number}: {error}', flush=True)
        report = dict(split=split, examples=count, invalid=invalid, system_prompt_variants=len(prompts), older_prompt_examples=stale)
        if lengths:
            lengths.sort()
            report.update(p99_tokens=lengths[int((len(lengths)-1)*.99)], max_tokens=max(lengths), clipped=clipped)
        print(json.dumps(report), flush=True)
        failures += invalid + clipped + (count == 0) + (stale if args.require_current_prompts else 0)
    raise SystemExit(1 if failures else 0)


if __name__ == '__main__':
    main()
