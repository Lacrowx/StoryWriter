"""Public-domain German fiction from Project Gutenberg, in modern spelling.

Books come from the German Project Gutenberg export on Hugging Face
(manu/project_gutenberg). Fiction is chosen by dialogue and narrative-verb
density; poetry and drama (short lines) are skipped. Pre-1996 spellings
(daß, Thür, seyn, giebt, regiren, Kenntniß) are modernised with word counts
from the modern Wikipedia side of the Falko-MERLIN archive, and passages
that still read as archaic are dropped.
"""
import glob
import itertools
import re

PARQUET = "https://huggingface.co/datasets/manu/project_gutenberg/resolve/main/data/{}.parquet"
SHARDS = ["de-00000-of-00003-f8e581c008ccc7f2", "de-00001-of-00003-44c9c3b458e2eef3", "de-00002-of-00003-084edb3f286e612c"]
WORD = re.compile(r"[^\W\d_]+")
# (old, modern) substitutions tried on words the modern lexicon doesn't know.
RULES = [("ß", "ss"), ("Th", "T"), ("th", "t"), ("gieb", "gib"), ("ey", "ei"), ("C", "K"), ("c", "k"),
         ("C", "Z"), ("c", "z"), ("Ae", "Ä"), ("Oe", "Ö"), ("Ue", "Ü"), ("ir", "ier"), ("dt", "t"),
         ("niß", "nis")]
# Frequency can't decide these: the old form is common, or a modern word
# has the same letters (Buße vs Busse "buses").
FIXED = {"bißchen": "bisschen", "häßlich": "hässlich", "Kuß": "Kuss", "Haß": "Hass", "Schluß": "Schluss",
         "Faß": "Fass", "naß": "nass", "Riß": "Riss", "Schuß": "Schuss", "mußt": "musst", "laß": "lass", "Laß": "Lass", "riß": "riss", "Buße": "Buße", "Maße": "Maße"}


def books(fetch, sources):
    import pyarrow.parquet as pq  # only the fiction source needs pyarrow
    texts = {}
    for shard in SHARDS:
        path = fetch(PARQUET.format(shard), sources / "gutenberg-de" / f"{shard}.parquet")
        for row in pq.read_table(path).to_pylist():
            book = row["id"].split("-")[0]
            if len(row["text"]) > len(texts.get(book, "")):
                texts[book] = row["text"]
    for book, text in sorted(texts.items()):
        match = re.search(r"\*\*\* ?START[^\n]*\n(.*)\*\*\* ?END", text, re.S)
        body = match.group(1) if match else text
        words = len(body.split())
        lines = [l for l in body.split("\n") if l.strip()]
        if (words > 5000 and len(re.findall(r"[»«„“]", body)) / words * 1000 >= 5
                and len(re.findall(r"\b(sagte|fragte|rief|antwortete)\b", body)) / words * 10000 >= 5
                and sum(len(l) < 40 for l in lines) / len(lines) < 0.35):
            yield book, body


class Modernizer:
    def __init__(self, freq):
        self.freq = freq
        self.cache = {}

    def known(self, word):
        return self.freq.get(word, 0) + self.freq.get(word.lower(), 0)

    def word(self, w):
        if w in self.cache:
            return self.cache[w]
        # An old form survives in modern text (quotes, titles), so compare
        # frequencies rather than only fixing unknown words.
        best, score = FIXED.get(w, w), self.known(w)
        if len(w) >= 3 and w not in FIXED:
            for rules in itertools.chain(([r] for r in RULES), itertools.combinations(RULES, 2)):
                for candidate in self.variants(w, rules):
                    s = self.known(candidate)
                    if s >= 20 and s >= 8 * max(score, 1) and s > self.known(best):
                        best = candidate
        self.cache[w] = best
        return best

    @staticmethod
    def variants(w, rules):
        words = {w}
        for old, new in rules:
            if old in ("c", "C") and len(w) < 5:
                return set()
            words = {v for x in words for v in ([x.replace(old, new)] + [x[:m.start()] + new + x[m.end():] for m in re.finditer(re.escape(old), x)]) if old in x}
            if old == "ß":
                # ß after a diphthong is a long sound and stays: weiß, ließ, draußen.
                words = {v for v in words if not re.search(r"(?:ei|ai|au|eu|äu|ie)ss", v, re.I)}
            if not words:
                return set()
        return words

    def text(self, text):
        text = WORD.sub(lambda m: self.word(m.group()), text)
        text = re.sub(r"\b([Mm])iß(?=[a-zäöü]{3})", r"\1iss", text)
        lower = [w for w in WORD.findall(text) if w.islower() and len(w) > 2]
        unknown = sum(self.known(w) == 0 for w in lower)
        return text if lower and unknown / len(lower) <= 0.015 else None


def passages(body, modernizer, per_book, rng):
    """Paragraphs as clean, modernised passages of 150-900 characters."""
    paragraphs = [" ".join(p.split()) for p in re.split(r"\n\s*\n", body)]
    rng.shuffle(paragraphs)
    found = []
    for p in paragraphs:
        p = re.sub(r"[_=]", "", p)
        if len(p) < 150 or re.search(r"\[|\]|\*|http|Gutenberg|\d{3,}|[A-ZÄÖÜ]{5,}", p):
            continue
        sentences = re.split(r"(?<=[.!?«“])\s+(?=[»„A-ZÄÖÜ])", p)
        chunk = ""
        for s in sentences:
            if len(chunk) + len(s) > 900:
                break
            chunk = f"{chunk} {s}".strip()
        if len(chunk) >= 150 and chunk[-1] in ".!?«“":
            modern = modernizer.text(chunk)
            if modern:
                found.append(modern)
                if len(found) >= per_book:
                    break
    return found


# ---------------------------------------------------------------- errors
# Each corruption returns (start, end, wrong_text) in the clean passage, or
# None. The issue then fixes wrong_text back to the original.

ARTICLE_SWAP = {"dem": "den", "den": "dem", "einem": "einen", "einen": "einem", "ihm": "ihn", "ihn": "ihm",
                "der": "den", "diesem": "diesen", "diesen": "diesem", "seinem": "seinen", "seinen": "seinem",
                "ihrem": "ihren", "ihren": "ihrem", "keinem": "keinen", "keinen": "keinem"}
WORD_SWAP = {"dass": "das", "seit": "seid", "wieder": "wider", "wider": "wieder", "seid": "seit", "Dass": "Das",
             "Seit": "Seid", "Wieder": "Wider", "ob": "ab", "wen": "wenn", "wenn": "wen", "man": "mann"}
TWO_WAY = ["in", "an", "auf", "über", "unter", "vor", "hinter", "neben", "zwischen", "In", "An", "Auf", "Über", "Unter", "Vor", "Hinter", "Neben", "Zwischen"]
CONJUNCTIONS = r"dass|weil|ob|obwohl|damit|nachdem|bevor|während|sodass|wenn|als|wie"
SINGULAR_VERBS = r"war|hatte|wurde|konnte|sollte|wollte|musste|durfte|mochte|ging|kam|sah|stand|lag|saß|sagte"


def typo(text, rng, known):
    words = [m for m in WORD.finditer(text) if len(m.group()) >= 5]
    for m in rng.sample(words, min(len(words), 8)):
        w, i = m.group(), rng.randrange(1, len(m.group()) - 1)
        wrong = rng.choice([w[:i] + w[i + 1:], w[:i] + w[i] + w[i:], w[:i] + w[i + 1] + w[i] + w[i + 2:]])
        if wrong != w and known(wrong) == 0:
            return m.start(), m.end(), wrong
    return None


def regex_swap(pattern, replace):
    def corrupt(text, rng, known):
        matches = list(re.finditer(pattern, text))
        if not matches:
            return None
        # Pattern group 1, when present, is the part to corrupt.
        m = rng.choice(matches)
        g = 1 if m.re.groups else 0
        return m.start(g), m.end(g), replace(m)
    return corrupt


CORRUPTIONS = [
    (typo, 4),
    # Not after two-way prepositions, where dem and den can both be right.
    (regex_swap("".join(rf"(?<!\b{p} )" for p in TWO_WAY) + r"\b(" + "|".join(ARTICLE_SWAP) + r")\b",
                lambda m: ARTICLE_SWAP[m.group()]), 3),
    # Adjective ending after an article: "dem alten" -> "dem alter".
    (regex_swap(r"\b(?:dem|den|der|die|das|einem|einen|eines|einer) ([a-zäöü]{3,}(?:em|en|er|es))\b",
                lambda m: m.group(1)[:-2] + {"em": "en", "en": "em", "er": "es", "es": "er"}[m.group(1)[-2:]]), 2),
    (regex_swap(r"\b(" + "|".join(WORD_SWAP) + r")\b", lambda m: WORD_SWAP[m.group()]), 2),
    (regex_swap(r", (?=(?:" + CONJUNCTIONS + r") )", lambda m: " "), 2),
    # Lowercased noun mid-sentence.
    (regex_swap(r"(?<=[a-zäöüß,] )[A-ZÄÖÜ][a-zäöüß]{3,}\b", lambda m: m.group().lower()), 2),
    (regex_swap(r"\b(?:er|es|ich|man) (" + SINGULAR_VERBS + r")\b",
                lambda m: m.group(1) + ("n" if m.group(1).endswith("e") else "en")), 2),
    # Dropped article.
    (regex_swap(r"\b(?:der|die|das|den|dem|ein|eine|einen|einem) (?=[A-ZÄÖÜ][a-zäöüß]+ )", lambda m: ""), 1),
]


# Style weaknesses the app's style mode should remove: fillers, redundant
# pairs and wordy noun phrasing. They are fixed only under the style prompt.
FILLERS = ["irgendwie", "sozusagen", "quasi", "im Grunde genommen", "im Prinzip"]
PLEONASMS = {"bereits": "bereits schon", "plötzlich": "plötzlich und unerwartet", "Plötzlich": "Plötzlich und unerwartet",
             "schließlich": "schließlich und letztendlich", "Schließlich": "Schließlich und letztendlich",
             "auch": "auch ebenfalls", "oft": "oftmals häufig", "zusammen": "gemeinsam zusammen",
             "dann": "dann daraufhin", "zurück": "wieder zurück", "nie": "nie jemals", "immer": "immer stets",
             "wieder": "erneut wieder", "gleichzeitig": "gleichzeitig zur selben Zeit", "meistens": "meistens überwiegend",
             "zuerst": "zuerst als Erstes", "genug": "genug und ausreichend", "einander": "gegenseitig einander",
             "schon": "schon bereits", "nur": "nur lediglich", "fast": "fast beinahe", "sofort": "sofort und unverzüglich",
             "jetzt": "jetzt nun"}
NOMINAL = [(r"\bhalf (ihm|ihr|ihnen|mir|uns|dir)\b", r"leistete \1 Hilfe"), (r"\bantwortete (er|sie)\b", r"gab \1 zur Antwort"),
           (r"\bfragte (er|sie)\b", r"stellte \1 die Frage"), (r"\bbeschloss (er|sie)\b", r"fasste \1 den Beschluss"),
           (r"\bversuchte (er|sie)\b", r"unternahm \1 den Versuch"), (r"\bentschied (er|sie) sich\b", r"traf \1 die Entscheidung"),
           (r"\bbeschloss\b", "fasste den Beschluss"), (r"\bentschied sich\b", "traf die Entscheidung")]
def pleonasm(text, rng, known):
    # Choose the word first so frequent ones (auch, dann) don't dominate.
    present = [k for k in PLEONASMS if re.search(rf"\b{k}\b", text)]
    return present and regex_swap(rf"\b({rng.choice(present)})\b", lambda m: PLEONASMS[m.group()])(text, rng, known) or None


def nominal(text, rng, known):
    present = [(p, r) for p, r in NOMINAL if re.search(p, text)]
    if not present:
        return None
    pattern, repl = rng.choice(present)
    return regex_swap("(" + pattern + ")", lambda m: re.sub(pattern, repl, m.group(1)))(text, rng, known)


STYLE_CORRUPTIONS = [
    (regex_swap(r"\b(?:war|waren|ist|sind|hatte|hatten|ging|sah|stand|wurde|wurden|kam|lag|saß|schien|blieb|konnte|wollte|wusste|fühlte|dachte) ()"
                r"(?!(?:und|oder|aber|denn|er|sie|es|ich|wir|ihr|der|die|das|den|dem|ein|eine|nicht)\b)(?=[a-zäöü]{3,})",
                lambda m: FILLERS[m.start() % len(FILLERS)] + " "), 3),
    (pleonasm, 3),
    (nominal, 2),
]


def corrupt(text, rng, known, count, style=0):
    """Apply up to count error and style non-overlapping corruptions.

    Returns (wrong, edits, style_starts): edits fix wrong back to text, and
    style_starts holds the start of each style edit in wrong.
    """
    chosen = []
    for table, n in ((CORRUPTIONS, count), (STYLE_CORRUPTIONS, style)):
        funcs = [f for f, weight in table for _ in range(weight)]
        found = 0
        for _ in range(n * 6):
            if found == n:
                break
            edit = rng.choice(funcs)(text, rng, known)
            if edit and not any(edit[0] < b + 2 and a < edit[1] + 2 for a, b, _, _ in chosen):
                chosen.append(edit + (table is STYLE_CORRUPTIONS,))
                found += 1
    wrong, edits, style_starts, shift = text, [], set(), 0
    for a, b, bad, is_style in sorted(chosen):
        wrong = wrong[:a + shift] + bad + wrong[b + shift:]
        edits.append((a + shift, a + shift + len(bad), text[a:b]))
        if is_style:
            style_starts.add(a + shift)
        shift += len(bad) - (b - a)
    return wrong, edits, style_starts
