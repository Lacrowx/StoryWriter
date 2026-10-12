import copy
import unittest

from audit_german_dataset import validate_example


def example():
    return {'messages': [
        {'role': 'system', 'content': 'Nur Rechtschreibung und Grammatik; keine optionalen Stiländerungen.'},
        {'role': 'user', 'content': 'Sie hat ein Brief bekommen.'},
        {'role': 'assistant', 'content': '{"issues":[{"original":"ein Brief","replacement":"einen Brief","kind":"grammar"}]}'},
    ]}


class DatasetAuditTests(unittest.TestCase):
    def test_exact_correction_and_clean_passage(self):
        self.assertEqual(len(validate_example(example())), 3)
        clean = example()
        clean['messages'][2]['content'] = '{"issues":[]}'
        validate_example(clean)

    def test_rejects_malformed_and_conflicting_labels(self):
        for response in [
            'broken', '[]', '{"issues":{}}',
            '{"issues":[{"original":"missing","replacement":"word","kind":"grammar"}]}',
            '{"issues":[{"original":"ein Brief","replacement":"ein  Brief","kind":"grammar"}]}',
            '{"issues":[{"original":"ein Brief","replacement":"einen Brief","kind":"style"}]}',
            '{"issues":[{"original":"ein Brief","replacement":"einen Brief","kind":"grammar"},{"original":"Brief","replacement":"Paket","kind":"grammar"}]}',
        ]:
            data = example()
            data['messages'][2]['content'] = response
            with self.subTest(response=response), self.assertRaises(ValueError):
                validate_example(data)

    def test_rejects_ambiguous_quotes_and_wrong_roles(self):
        duplicate = example()
        duplicate['messages'][1]['content'] += ' ein Brief'
        with self.assertRaises(ValueError):
            validate_example(duplicate)
        roles = copy.deepcopy(example())
        roles['messages'][0]['role'] = 'user'
        with self.assertRaises(ValueError):
            validate_example(roles)


if __name__ == '__main__':
    unittest.main()
