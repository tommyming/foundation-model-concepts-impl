#!/usr/bin/env python3
"""Generates the synthetic datasets for the three demo adapters.

Seeded and deterministic. Emits train.jsonl / valid.jsonl (chat format) under
training/data/<task>/ for task in classify, summarize, extract.

All three tasks share the same underlying "facts", rendered differently:
classify -> one label; summarize -> one compressed sentence; extract -> strict
JSON. This mirrors the demo story: same input world, three capabilities.
"""

import json
import random
from pathlib import Path

random.seed(20261013)

LABELS = ["Technology", "Business", "Science", "Culture", "Other"]

SYSTEMS = {
    "classify": (
        "You classify notes. Answer with exactly one word from this list: "
        "Technology, Business, Science, Culture, Other. Output nothing else."
    ),
    "summarize": (
        "You summarize notes in exactly one sentence. Keep names and "
        "deadlines. Output only the summary sentence. /no_think"
    ),
    "extract": (
        'You extract structured data from notes. Output only strict JSON with '
        'these keys: people, organizations, locations, action_items. Each '
        'value is a list of strings. Output nothing else. /no_think'
    ),
}

PEOPLE = [
    "Sara", "Miguel", "Priya", "Tom", "Aisha", "Kenji", "Lena", "Omar",
    "Nadia", "Victor", "Grace", "Hugo", "Yuki", "Farah", "Carl", "Ines",
]
COMPANIES = [
    "Acme Corp", "Northwind Ltd", "Vertex Labs", "BlueHarbor", "KappaWorks",
    "Stonebridge", "Nimbus AI", "Helios Energy", "Ferrum Freight", "Solstice Media",
]
LOCATIONS = [
    "the Singapore lab", "the Berlin office", "Warehouse 9", "Studio B",
    "the rooftop garden", "Hall 3", "the Osaka branch", "Meeting Room 4",
]
DELIVERABLES = [
    "the Q3 forecast slides", "the migration plan", "the safety report",
    "the onboarding guide", "the prototype firmware", "the press draft",
    "the budget sheet", "the field survey",
]
DEADLINES = [
    "before Friday", "next week", "by end of month", "before the audit",
    "once the numbers land", "before the deadline", "after the standup",
]
CATEGORY_SENTENCES = {
    "Technology": [
        "{person} flagged a bug in the {thing}.",
        "The {thing} rollout is behind schedule.",
        "Benchmarking of the {thing} starts Monday.",
    ],
    "Business": [
        "{company} asked about the renewal.",
        "The pricing strategy review landed poorly.",
        "{person} owns the hiring plan now.",
    ],
    "Science": [
        "The coral reef study enters phase two.",
        "Lab work on soil samples stalled.",
        "The exoplanet survey paper is out.",
    ],
    "Culture": [
        "The film festival opening sold out.",
        "Reviews of the new novel are mixed.",
        "The heritage walk needs a new route.",
    ],
    "Other": [
        "{person} has a dentist appointment.",
        "Packing for the hiking trip started.",
        "The neighborhood watch meeting moved.",
    ],
}
CATEGORY_THINGS = {
    "Technology": ["auth service", "CI pipeline", "shader compiler", "edge router"],
    "Business": ["vendor contract", "board deck", "seed round", "cost-cutting plan"],
    "Science": ["vaccine trial", "protein folding", "ocean salinity", "superconductors"],
    "Culture": ["opera season", "jazz album", "museum wing", "poetry slam"],
    "Other": ["visa office", "apartment viewing", "car service", "passport renewal"],
}
FILLERS = [
    "Notes are scattered but the gist is clear.",
    "No firm decision yet.",
    "Follow-up expected soon.",
    "Check the shared folder for details.",
]


def classify_example() -> tuple[str, str]:
    label = random.choice(LABELS)
    parts = []
    for _ in range(random.randint(2, 3)):
        tpl = random.choice(CATEGORY_SENTENCES[label])
        parts.append(tpl.format(
            person=random.choice(PEOPLE),
            company=random.choice(COMPANIES),
            thing=random.choice(CATEGORY_THINGS[label]),
        ))
    parts.append(random.choice(FILLERS))
    return " ".join(parts), label


def facts() -> list[dict]:
    """Shared ground truth: 2-3 typed facts rendered by summarize/extract."""
    out = []
    for _ in range(random.randint(2, 3)):
        kind = random.choice(["action", "org", "place"])
        if kind == "action":
            out.append({
                "person": random.choice(PEOPLE),
                "text": f"{random.choice(PEOPLE)} wants {random.choice(DELIVERABLES)} {random.choice(DEADLINES)}.",
            })
        elif kind == "org":
            out.append({
                "org": random.choice(COMPANIES),
                "text": f"{random.choice(COMPANIES)} asked about the renewal {random.choice(DEADLINES)}.",
            })
        else:
            out.append({
                "place": random.choice(LOCATIONS),
                "text": f"The review session is at {random.choice(LOCATIONS)}.",
            })
    return out


def summarize_example() -> tuple[str, str]:
    fs = facts()
    article = " ".join(f["text"] for f in fs) + " " + random.choice(FILLERS)
    summary = " ".join(f["text"] for f in fs)
    return article, summary


def extract_example() -> tuple[str, str]:
    fs = facts()
    article = " ".join(f["text"] for f in fs) + " " + random.choice(FILLERS)
    slots = {"people": [], "organizations": [], "locations": [], "action_items": []}
    for f in fs:
        if "person" in f:
            name = f["person"]
            if name not in slots["people"]:
                slots["people"].append(name)
            if f["text"] not in slots["action_items"]:
                slots["action_items"].append(f["text"])
        elif "org" in f:
            if f["org"] not in slots["organizations"]:
                slots["organizations"].append(f["org"])
        elif "place" in f:
            if f["place"] not in slots["locations"]:
                slots["locations"].append(f["place"])
    return article, json.dumps(slots)


MAKERS = {
    "classify": classify_example,
    "summarize": summarize_example,
    "extract": extract_example,
}


def main() -> None:
    base = Path(__file__).parent / "data"
    for task, maker in MAKERS.items():
        out = base / task
        out.mkdir(parents=True, exist_ok=True)
        train, valid = [], []
        for _ in range(600):
            article, answer = maker()
            train.append({"messages": [
                {"role": "system", "content": SYSTEMS[task]},
                {"role": "user", "content": article},
                {"role": "assistant", "content": answer},
            ]})
        for _ in range(100):
            article, answer = maker()
            valid.append({"messages": [
                {"role": "system", "content": SYSTEMS[task]},
                {"role": "user", "content": article},
                {"role": "assistant", "content": answer},
            ]})
        (out / "train.jsonl").write_text(
            "\n".join(json.dumps(e) for e in train) + "\n")
        (out / "valid.jsonl").write_text(
            "\n".join(json.dumps(e) for e in valid) + "\n")
        print(f"{task}: train={len(train)} valid={len(valid)} -> {out}")


if __name__ == "__main__":
    main()
