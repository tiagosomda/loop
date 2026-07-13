#!/usr/bin/env python3
"""dev-loop backend CLI — board I/O, repo crawling, shared-rules management.

Examples:
    ./devloop.py items list --status open,in-progress
    ./devloop.py items claim <id>
    ./devloop.py items post <id> --text "done, see PR" --attach shot.png
    ./devloop.py items status <id> needs-review
    ./devloop.py repos crawl
    ./devloop.py schedule update --mark-run
    ./devloop.py rules pull && ./devloop.py rules merge && ./devloop.py rules deploy
"""

from __future__ import annotations

import argparse
import json
import sys


def _print(data) -> None:
    json.dump(data, sys.stdout, indent=2)
    print()


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="devloop", description=__doc__)
    top = parser.add_subparsers(dest="group", required=True)

    # items
    items = top.add_parser("items", help="action-item board operations")
    sub = items.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("list", help="list items (writes data/board-cache.json)")
    p.add_argument("--status", help="comma-separated statuses, e.g. open,in-progress")

    p = sub.add_parser("show", help="print an item with its full thread")
    p.add_argument("id")

    p = sub.add_parser("create", help="create a new open item")
    p.add_argument("--title", required=True)
    p.add_argument("--repo", required=True, help="repoId (see repos crawl)")
    p.add_argument("--text", help="first message")
    p.add_argument("--model")
    p.add_argument("--effort")

    p = sub.add_parser("claim", help="mark in-progress before starting work")
    p.add_argument("id")

    p = sub.add_parser("status", help="set item status")
    p.add_argument("id")
    p.add_argument("status")

    p = sub.add_parser("post", help="append a message to an item's thread")
    p.add_argument("id")
    p.add_argument("--text", required=True)
    p.add_argument("--author", default="agent", choices=["agent", "user"])
    p.add_argument("--attach", action="append", default=[],
                   help="file to upload as attachment (repeatable)")

    # repos
    repos = top.add_parser("repos", help="repo registry operations")
    sub = repos.add_subparsers(dest="cmd", required=True)
    sub.add_parser("crawl", help="scan dev/ for git repos and sync to Firestore")

    # schedule
    schedule = top.add_parser("schedule", help="publish agent schedule")
    sub = schedule.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("update", help="write wake-up times to Firestore")
    p.add_argument("--mark-run", action="store_true",
                   help="also stamp lastRunAt (call at the start of an agent run)")

    # rules
    rules = top.add_parser("rules", help="shared security-rules management")
    sub = rules.add_subparsers(dest="cmd", required=True)
    for name, help_text in (
        ("pull", "download the released ruleset to data/"),
        ("merge", "splice in rules/dev-loop rules between markers"),
        ("deploy", "upload + release the merged ruleset"),
    ):
        p = sub.add_parser(name, help=help_text)
        p.add_argument("--service", default="firestore",
                       choices=["firestore", "storage"])
        if name == "deploy":
            p.add_argument("--yes", action="store_true", help="skip confirmation")

    args = parser.parse_args(argv)

    if args.group == "items":
        from devloop import items as mod
        if args.cmd == "list":
            statuses = args.status.split(",") if args.status else None
            _print(mod.list_items(statuses))
        elif args.cmd == "show":
            _print(mod.show_item(args.id))
        elif args.cmd == "create":
            _print({"id": mod.create_item(args.title, args.repo, args.text,
                                          args.model, args.effort)})
        elif args.cmd == "claim":
            mod.claim_item(args.id)
            print(f"{args.id} -> in-progress")
        elif args.cmd == "status":
            mod.set_status(args.id, args.status)
            print(f"{args.id} -> {args.status}")
        elif args.cmd == "post":
            msg_id = mod.post_message(args.id, args.text, args.author, args.attach)
            print(f"posted {msg_id}")
    elif args.group == "repos":
        from devloop import repos as mod
        _print(mod.crawl())
    elif args.group == "schedule":
        from devloop import schedule as mod
        _print(mod.update(mark_run=args.mark_run))
    elif args.group == "rules":
        from devloop import rules as mod
        if args.cmd == "pull":
            print(f"pulled -> {mod.pull(args.service)}")
        elif args.cmd == "merge":
            print(f"merged -> {mod.merge(args.service)}")
        elif args.cmd == "deploy":
            print(f"released {mod.deploy(args.service, yes=args.yes)}")


if __name__ == "__main__":
    main()
