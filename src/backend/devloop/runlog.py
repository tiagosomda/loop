"""Local run log for the scheduled agent (data/agent-runs.log).

One timestamped line per event. The first thing a run does is
`schedule update --mark-run`, which logs "run started" automatically — so a
scheduled slot with NO "run started" line means the run never got to execute
anything (harness failure or a rate limit that blocked the model outright),
as opposed to a run that started and then died, which leaves a started line
with no matching "run finished".
"""

from __future__ import annotations

from datetime import datetime

from . import config

LOG_FILE = config.DATA_DIR / "agent-runs.log"


def log(message: str) -> str:
    config.DATA_DIR.mkdir(exist_ok=True)
    stamp = datetime.now().astimezone().isoformat(timespec="seconds")
    line = f"{stamp} {message.strip()}"
    with LOG_FILE.open("a") as fh:
        fh.write(line + "\n")
    return line


def tail(count: int = 20) -> list[str]:
    if not LOG_FILE.is_file():
        return []
    return LOG_FILE.read_text().splitlines()[-count:]
