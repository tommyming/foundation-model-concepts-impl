#!/usr/bin/env python3
"""Generates the synthetic classification dataset for the Phase 2 adapter.

Seeded and deterministic: same script, same data. Emits train.jsonl and
valid.jsonl (chat format) under training/data/classify/.
"""

import json
import random
from pathlib import Path

random.seed(20261013)

LABELS = ["Technology", "Business", "Science", "Culture", "Other"]

SYSTEM = (
    "You classify notes. Answer with exactly one word from this list: "
    "Technology, Business, Science, Culture, Other. Output nothing else."
)

PEOPLE = [
    "Sara", "Miguel", "Priya", "Tom", "Aisha", "Kenji", "Lena", "Omar",
    "Nadia", "Victor", "Grace", "Hugo", "Yuki", "Farah", "Carl", "Ines",
]
COMPANIES = [
    "Acme Corp", "Northwind Ltd", "Vertex Labs", "BlueHarbor", "KappaWorks",
    "Stonebridge", "Nimbus AI", "Helios Energy", "Ferrum Freight", "Solstice Media",
]
TOPICS = {
    "Technology": [
        ("the {thing} rollout", ["API gateway", "Kubernetes cluster", "CI pipeline", "Swift 6 migration", "on-device model", "mesh network", "battery firmware", "VR headset prototype"]),
        ("a bug in the {thing}", ["auth service", "payment webhook", "shader compiler", "camera driver", "sync client"]),
        ("benchmarking the {thing}", ["new GPU", "quantized LLM", "SSD array", "edge router"]),
    ],
    "Business": [
        ("the {thing} review", ["Q3 forecast", "pricing strategy", "vendor contract", "hiring plan", "board deck", "marketing budget"]),
        ("renewal talks with {company}", []),
        ("the {thing} proposal", ["merger", "seed round", "retail expansion", "cost-cutting plan"]),
    ],
    "Science": [
        ("the {thing} study results", ["genome", "coral reef", "vaccine trial", "exoplanet survey", "crispr", "dark matter detector"]),
        ("lab work on {thing}", ["antenna tests", "soil samples", "protein folding", "neuron imaging"]),
        ("a paper on {thing}", ["quantum error correction", "ocean salinity", "bird migration", "superconductors"]),
    ],
    "Culture": [
        ("the {thing} opening", ["film festival", "photo exhibition", "street art fair", "opera season", "indie game showcase"]),
        ("a review of {thing}", ["the new novel", "the jazz album", "the museum wing", "the ballet premiere"]),
        ("plans for {thing}", ["the poetry slam", "the heritage walk", "the food market", "the theater workshop"]),
    ],
    "Other": [
        ("the {thing} appointment", ["dentist", "visa office", "apartment viewing", "car service"]),
        ("packing for {thing}", ["the hiking trip", "the family reunion", "the move across town"]),
        ("a reminder about {thing}", ["watering the plants", "renewing the passport", "the neighborhood watch meeting"]),
    ],
}

ACTIONS = [
    "before Friday", "next week", "by end of month", "after the standup",
    "before the audit", "once the numbers land", "before the deadline",
]


def sentence(label: str) -> str:
    person = random.choice(PEOPLE)
    kind = random.choice(TOPICS[label])
    slot = random.choice(kind[1]) if kind[1] else random.choice(COMPANIES)
    text = kind[0].format(thing=slot, company=random.choice(COMPANIES))
    verb = random.choice(["wants", "asked about", "flagged", "owns", "pushed back on"])
    tail = random.choice(ACTIONS)
    return f"{person} {verb} {text} {tail}."


def article(label: str) -> str:
    n = random.randint(2, 4)
    parts = [sentence(label) for _ in range(n)]
    filler = random.choice([
        "Notes are scattered but the gist is clear.",
        "No firm decision yet.",
        "Follow-up expected soon.",
        "Check the shared folder for details.",
    ])
    return " ".join(parts) + " " + filler


def example(label: str) -> dict:
    return {
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": article(label)},
            {"role": "assistant", "content": label},
        ]
    }


def main() -> None:
    out = Path(__file__).parent / "data" / "classify"
    out.mkdir(parents=True, exist_ok=True)

    train, valid = [], []
    for label in LABELS:
        train += [example(label) for _ in range(120)]
        valid += [example(label) for _ in range(20)]
    random.shuffle(train)
    random.shuffle(valid)

    (out / "train.jsonl").write_text(
        "\n".join(json.dumps(e) for e in train) + "\n")
    (out / "valid.jsonl").write_text(
        "\n".join(json.dumps(e) for e in valid) + "\n")
    print(f"train={len(train)} valid={len(valid)} -> {out}")


if __name__ == "__main__":
    main()
