#!/usr/bin/env python3
"""Generate Python Laya-MLX references for SwiftDecision's fixed parity prompts."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Any

import laya_mlx


def _selected_id(option_ids: list[str], probabilities: list[float]) -> str:
    if len(option_ids) != len(probabilities) or not option_ids:
        raise ValueError("Laya response probabilities do not match the fixed options")
    return option_ids[max(range(len(probabilities)), key=probabilities.__getitem__)]


def _answer(agent: Any, state: str, question: dict[str, Any], question_id: str) -> dict[str, Any]:
    response = agent.predict(state, {question_id: question})
    try:
        answer = response["answers"][question_id]
    except (KeyError, TypeError) as error:
        raise ValueError(f"Laya response is missing answer {question_id!r}") from error
    if not isinstance(answer, dict):
        raise ValueError(f"Laya answer {question_id!r} is not an object")
    return answer


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--checkpoint",
        type=Path,
        default=os.environ.get("SWIFTDECISION_LAYA_CHECKPOINT"),
        help="local Laya checkpoint directory (or SWIFTDECISION_LAYA_CHECKPOINT)",
    )
    parser.add_argument("--output", type=Path, required=True, help="reference JSON output path")
    parser.add_argument("--dtype", choices=("float16", "float32"), default="float16")
    args = parser.parse_args()
    if args.checkpoint is None or not args.checkpoint.is_dir():
        parser.error("--checkpoint must point to an existing local checkpoint directory")

    agent = laya_mlx.load(str(args.checkpoint), dtype=args.dtype)

    noul_answer = _answer(
        agent,
        "The status page reports that all customers are unable to sign in.",
        {
            "type": "noul",
            "instructions": "Is the service outage affecting every customer?",
        },
        "noul",
    )
    p_true = float(noul_answer["noul"])
    noul_probabilities = [round(1.0 - p_true, 4), p_true]
    noul_ids = ["false", "true"]

    choice_ids = ["support", "billing", "sales"]
    choice_answer = _answer(
        agent,
        "My invoice contains a duplicate charge from yesterday.",
        {
            "type": "choice",
            "instructions": "Choose the best team to handle this customer message.",
            "criteria": {
                "support": "account access or product use",
                "billing": "invoices, refunds, or charges",
                "sales": "plan selection or purchasing",
            },
        },
        "choice",
    )
    choice_probabilities = [float(choice_answer["probabilities"][label]) for label in choice_ids]

    score_ids = ["0", "1", "2"]
    score_answer = _answer(
        agent,
        "Question: How do I reset my password? Response: Open Settings, choose Security, and select Reset Password.",
        {
            "type": "score",
            "instructions": "Rate how completely the response answers the question.",
            "criteria": [
                "does not answer the question",
                "partially answers the question",
                "fully answers the question",
            ],
        },
        "score",
    )
    score_probabilities = [float(score_answer["probabilities"][option_id]) for option_id in score_ids]

    reference = {
        "noul": {
            "selectedOptionID": _selected_id(noul_ids, noul_probabilities),
            "probabilities": noul_probabilities,
        },
        "choice": {
            "selectedOptionID": str(choice_answer["choice"]),
            "probabilities": choice_probabilities,
        },
        "score": {
            "selectedOptionID": _selected_id(score_ids, score_probabilities),
            "probabilities": score_probabilities,
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(reference, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote Python Laya-MLX {args.dtype} references to {args.output}")


if __name__ == "__main__":
    main()
