#!/usr/bin/env python3
"""
nightowl_queue.py — queue a task for 1am execution via NightOwlWorkflow.

Usage:
  python3 /mnt/data/scripts/nightowl_queue.py "do the python to typescript migration"

The script:
  1. Tries to start NightOwlWorkflow with id "nightowl-today"
     (no-op if already running — WorkflowAlreadyStartedError is caught).
  2. Signals the running workflow with add_task("<task>".
"""
import asyncio
import sys
from pathlib import Path

from dotenv import load_dotenv

# Load .env from temporal-workflows so TEMPORAL_HOST etc. are available
load_dotenv(Path(__file__).parent.parent / "temporal-workflows" / ".env")

import os
from temporalio.client import Client
from temporalio.service import RPCError


TEMPORAL_HOST = os.environ.get("TEMPORAL_HOST", "localhost:7233")
TASK_QUEUE = "listings-queue"
WORKFLOW_ID = "nightowl-today"


async def main(task: str) -> None:
    client = await Client.connect(TEMPORAL_HOST)

    # Try to start the workflow; ignore if already running
    try:
        from temporalio.client import WorkflowAlreadyStartedError
        await client.start_workflow(
            "NightOwlWorkflow",
            id=WORKFLOW_ID,
            task_queue=TASK_QUEUE,
        )
        print(f"[nightowl] Started NightOwlWorkflow (id={WORKFLOW_ID})")
    except Exception as exc:
        # WorkflowAlreadyStartedError means it's running — that's fine
        print(f"[nightowl] Workflow already running (or start skipped): {exc}")

    # Signal the workflow to add the task
    handle = client.get_workflow_handle(WORKFLOW_ID)
    await handle.signal("add_task", task)
    print(f"[nightowl] Queued task: {task!r}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 nightowl_queue.py <task description>", file=sys.stderr)
        sys.exit(1)
    task_arg = " ".join(sys.argv[1:])
    asyncio.run(main(task_arg))
