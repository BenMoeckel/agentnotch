#!/usr/bin/env python3
"""Publish an agent lifecycle event without depending on a terminal multiplexer."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True, help='Long-lived agent/extension-host PID, not the hook subprocess')
    parser.add_argument('--kind', required=True, help='Icon kind, e.g. claude, codex, cline, copilot')
    parser.add_argument('--state', choices=['working', 'blocked', 'idle', 'done', 'unknown'], required=True)
    parser.add_argument('--session', help='Stable conversation ID when a process hosts multiple conversations')
    parser.add_argument('--sequence', type=int, help='Monotonic completion counter; retain the same value during a turn')
    parser.add_argument('--title')
    parser.add_argument('--window-title', help='Exact editor window title for unambiguous navigation')
    args = parser.parse_args()
    if args.pid <= 1:
        parser.error('--pid must identify a running agent or extension host')
    try:
        os.kill(args.pid, 0)
    except OSError:
        parser.error('--pid does not identify an accessible running process')
    root = Path(os.environ.get('AGENTNOTCH_EVENT_DIR', Path.home() / 'Library/Application Support/AgentNotch/events'))
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    key = hashlib.sha256(f'{args.pid}:{args.session or ""}'.encode()).hexdigest()
    payload = {k: v for k, v in vars(args).items() if v is not None}
    payload['windowTitle'] = payload.pop('window_title', None)
    payload['updatedAt'] = time.time()
    fd, path = tempfile.mkstemp(prefix='.event-', dir=root)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(payload, stream)
        os.replace(path, root / f'{key}.json')
    finally:
        if os.path.exists(path):
            os.unlink(path)


if __name__ == '__main__':
    main()
