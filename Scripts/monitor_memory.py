#!/usr/bin/env python3
"""Sample one existing app process without reading credentials or session text."""

import argparse
import csv
import datetime
import json
from pathlib import Path
import re
import subprocess
import time


def command(*args):
    try:
        return subprocess.run(args, text=True, capture_output=True, timeout=30)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(args, returncode=124, stdout='', stderr='Probe timed out')


def footprint(pid):
    result = command('/usr/bin/vmmap', '-summary', str(pid))
    if result.returncode:
        return '', ''
    values = []
    for label in ('Physical footprint:', 'Physical footprint (peak):'):
        match = re.search(re.escape(label) + r'\s+([\d.]+)([KMGT]?)', result.stdout)
        values.append(round(float(match[1]) * 1024 ** ('KMGT'.index(match[2]) + 1)
                            / 1048576, 2) if match and match[2] else '')
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--duration', type=int, default=900, help='Seconds, default 900')
    parser.add_argument('--interval', type=int, default=5, help='Seconds, default 5')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.pid <= 0 or args.duration <= 0 or args.interval <= 0:
        parser.error('PID, duration, and interval must be positive')
    identity = command('/bin/ps', '-p', str(args.pid), '-o', 'lstart=', '-o', 'comm=')
    if identity.returncode or not identity.stdout.strip().endswith('/VibeBar'):
        parser.error('PID must identify a running VibeBar executable')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    fields = ['utc', 'elapsed_seconds', 'pid', 'rss_mib', 'cpu_percent',
              'footprint_mib', 'peak_footprint_mib']
    start = time.monotonic()
    next_footprint = 0
    samples = []
    status = 'completed'
    with args.output.open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        while True:
            current = command('/bin/ps', '-p', str(args.pid), '-o', 'lstart=', '-o', 'comm=')
            if current.returncode:
                status = 'process_unavailable'
                break
            if current.stdout != identity.stdout:
                status = 'process_exited_or_changed'
                break
            result = command('/bin/ps', '-p', str(args.pid), '-o', 'rss=', '-o', '%cpu=')
            parts = result.stdout.split()
            if result.returncode or len(parts) != 2:
                status = 'process_unavailable'
                break
            elapsed = time.monotonic() - start
            row = dict(zip(fields, [datetime.datetime.now(datetime.timezone.utc).isoformat(),
                                    round(elapsed, 1), args.pid, round(int(parts[0]) / 1024, 2),
                                    float(parts[1]), '', '']))
            if elapsed >= next_footprint:
                row['footprint_mib'], row['peak_footprint_mib'] = footprint(args.pid)
                next_footprint = elapsed + 60
                print(json.dumps(row), flush=True)
            writer.writerow(row)
            stream.flush()
            samples.append(row)
            remaining = args.duration - (time.monotonic() - start)
            if remaining <= 0:
                break
            time.sleep(min(args.interval, remaining))
    summary = {'status': status, 'pid': args.pid, 'samples': len(samples),
               'elapsed_seconds': round(time.monotonic() - start, 1)}
    if samples:
        summary.update(rss_min_mib=min(row['rss_mib'] for row in samples),
                       rss_max_mib=max(row['rss_mib'] for row in samples),
                       rss_last_mib=samples[-1]['rss_mib'])
    args.output.with_suffix('.summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary), flush=True)
    return 0 if status == 'completed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
