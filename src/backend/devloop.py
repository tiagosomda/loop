#!/usr/bin/env python3
"""dev-loop backend CLI — board I/O, repo crawling, shared-rules management.

Examples:
    ./devloop.py items list --status open,in-progress
    ./devloop.py items claim <id>
    ./devloop.py items post <id> --text "done, see PR" --attach shot.png
    ./devloop.py items status <id> needs-review
    ./devloop.py items reorder <id> 1500        # set manual board position
    ./devloop.py items archive <id>            # archive one item
    ./devloop.py items archive --closed        # bulk-archive closed items
    ./devloop.py items unarchive <id>
    ./devloop.py repos crawl
    ./devloop.py schedule update --mark-run
    ./devloop.py run start                     # mark-run + crawl + ordered queue
    ./devloop.py run next                      # next item to claim, or null
    ./devloop.py run stale <id>                 # look for a prior WIP branch/worktree
    ./devloop.py run end --note "..."           # log "run finished: ..."
    ./devloop.py targets list --role worker --enabled-only
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
    p.add_argument("--include-archived", action="store_true",
                   help="also include archived items (excluded by default)")

    p = sub.add_parser("show", help="print an item with its full thread")
    p.add_argument("id")
    p.add_argument("--new", action="store_true",
                   help="only messages after the agent's last reply")

    p = sub.add_parser("fetch", help="download an item's attachments to data/")
    p.add_argument("id")
    p.add_argument("--new", action="store_true",
                   help="only attachments from messages after the agent's last reply")
    p.add_argument("--out", help="target directory (default data/attachments/<id>)")

    p = sub.add_parser("create", help="create a new open item")
    p.add_argument("--title", required=True)
    p.add_argument("--repo", required=True, help="repoId (see repos crawl)")
    p.add_argument("--text", help="first message")
    p.add_argument("--model")
    p.add_argument("--effort")
    p.add_argument("--provider")

    p = sub.add_parser("claim", help="mark in-progress before starting work")
    p.add_argument("id")

    p = sub.add_parser("status", help="set item status")
    p.add_argument("id")
    p.add_argument("status")

    p = sub.add_parser("reorder",
                       help="set an item's manual board position (order field)")
    p.add_argument("id")
    p.add_argument("value", type=float,
                   help="new order value (the frontend uses gap-based values; "
                        "this sets it directly)")

    p = sub.add_parser("archive",
                       help="archive an item by id, or all closed with --closed")
    p.add_argument("id", nargs="?", help="item id (omit when using --closed)")
    p.add_argument("--closed", action="store_true",
                   help="bulk-archive every closed, non-archived item")

    p = sub.add_parser("unarchive", help="restore an archived item to the board")
    p.add_argument("id")

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

    # runlog
    runlog_p = top.add_parser("runlog", help="agent run log (data/agent-runs.log)")
    sub = runlog_p.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("add", help="append a timestamped event line")
    p.add_argument("message")
    p = sub.add_parser("tail", help="show recent log lines")
    p.add_argument("-n", type=int, default=20)

    # run (orchestration helpers: bootstrap, ordered queue, stale-item check)
    run = top.add_parser("run", help="scheduled-run orchestration helpers")
    sub = run.add_subparsers(dest="cmd", required=True)
    sub.add_parser("start", help="mark-run + repos crawl + ordered open/in-progress queue")
    sub.add_parser("next", help="the single next item to claim, per triage order")
    p = sub.add_parser("end", help='log "run finished: ..."')
    p.add_argument("--note", help="override the auto-derived touched-items summary")
    p = sub.add_parser("stale", help="check for a prior run's WIP branch/worktree")
    p.add_argument("id")
    p = sub.add_parser("autonomous", help="route and dispatch the queue locally")
    p.add_argument("--max-items", type=int,
                   help="optional bounded item count for manual rollout checks")
    sub.add_parser("self-healing", help="inspect prior runs and repair scheduler errors")

    # targets
    targets = top.add_parser("targets", help="safe provider target catalog")
    sub = targets.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("list", help="list safe target capabilities and availability")
    p.add_argument("--role", choices=["router", "worker"])
    p.add_argument("--enabled-only", action="store_true")
    sub.add_parser("publish", help="publish selectable targets for the frontend")

    # route
    route = top.add_parser("route", help="local provider routing")
    sub = route.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("context", help="print sanitized routing context")
    p.add_argument("id")
    p = sub.add_parser("decide", help="ask the local router for a validated decision")
    p.add_argument("id")
    p.add_argument("--shadow", action="store_true",
                   help="record the decision locally without dispatching")

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
            _print(mod.list_items(statuses, include_archived=args.include_archived))
        elif args.cmd == "show":
            _print(mod.show_item(args.id, new_only=args.new))
        elif args.cmd == "fetch":
            _print(mod.fetch_attachments(args.id, new_only=args.new,
                                         out_dir=args.out))
        elif args.cmd == "create":
            _print({"id": mod.create_item(args.title, args.repo, args.text,
                                          args.model, args.effort, args.provider)})
        elif args.cmd == "claim":
            mod.claim_item(args.id)
            print(f"{args.id} -> in-progress")
        elif args.cmd == "status":
            mod.set_status(args.id, args.status)
            print(f"{args.id} -> {args.status}")
        elif args.cmd == "reorder":
            mod.set_order(args.id, args.value)
            print(f"{args.id} -> order {args.value}")
        elif args.cmd == "archive":
            if args.closed:
                ids = mod.archive_closed()
                print(f"archived {len(ids)} closed item(s): {', '.join(ids) or '(none)'}")
            elif args.id:
                mod.archive_item(args.id)
                print(f"{args.id} -> archived")
            else:
                raise SystemExit("pass an item id or --closed")
        elif args.cmd == "unarchive":
            mod.unarchive_item(args.id)
            print(f"{args.id} -> unarchived")
        elif args.cmd == "post":
            msg_id = mod.post_message(args.id, args.text, args.author, args.attach)
            print(f"posted {msg_id}")
    elif args.group == "repos":
        from devloop import repos as mod
        _print(mod.crawl())
    elif args.group == "schedule":
        from devloop import schedule as mod
        _print(mod.update(mark_run=args.mark_run))
    elif args.group == "run":
        from devloop import run as mod
        if args.cmd == "start":
            _print(mod.start())
        elif args.cmd == "next":
            _print(mod.next_item())
        elif args.cmd == "end":
            print(mod.end(note=args.note))
        elif args.cmd == "stale":
            _print(mod.check_stale(args.id))
        elif args.cmd == "autonomous":
            from devloop import autonomous
            try:
                _print(autonomous.execute(max_items=args.max_items))
            except autonomous.AlreadyRunning as exc:
                _print({"alreadyRunning": True, "message": str(exc)})
        elif args.cmd == "self-healing":
            from devloop import self_healing
            _print(self_healing.execute())
    elif args.group == "runlog":
        from devloop import runlog as mod
        if args.cmd == "add":
            print(mod.log(args.message))
        elif args.cmd == "tail":
            print("\n".join(mod.tail(args.n)) or "(empty)")
    elif args.group == "targets":
        from devloop import targets as mod
        if args.cmd == "list":
            _print(mod.safe_projection(role=args.role,
                                       enabled_only=args.enabled_only))
        elif args.cmd == "publish":
            _print(mod.publish())
    elif args.group == "route":
        from devloop import router as mod
        context = mod.build_context(args.id)
        if args.cmd == "context":
            _print(context)
        elif args.cmd == "decide":
            decision = mod.decide(context)
            if args.shadow:
                mod.record_shadow(context, decision)
            _print(decision)
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
