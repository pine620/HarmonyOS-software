#!/usr/bin/env python3
"""Summarize user-exported preload logs offline; never contact a device or AGC."""

import argparse
from collections import Counter, defaultdict
import json
import math
from pathlib import Path
import re


CLOUD_STATES = {
    "disabled", "unconfigured", "snapshot_expired", "cooldown", "miss", "hit",
    "race_hit", "fallback",
}
ERRORS = {"none", "invalid_snapshot", "timeout", "auth", "dependency", "connection", "unavailable"}
CLOUD_NUMBERS = (
    "candidateDbQueries", "candidateDbMs", "cacheReadMs", "cacheWriteMs", "candidates",
    "profileDbQueries", "mediaDbQueries", "profileFailures", "hydrationMs", "cards", "totalMs",
)
EVENTS = {
    "snapshot", "next_page", "nearby_metadata", "nearby_first_cover", "detail_primary_image",
    "media_cache", "media_queue", "media_download",
}
STATES = {
    "hit", "miss", "joined", "stale", "success", "error", "cancelled", "empty", "decoded", "open", "refresh",
}
TRACES = {
    "shike.nearby.cloud_list", "shike.nearby.snapshot_load", "shike.nearby.primary_media",
    "shike.nearby.next_page_prefetch", "shike.nearby.location.rounded", "shike.detail.metadata",
}
FIELDS = re.compile(r"([A-Za-z][A-Za-z0-9]*)=([^\s]+)")


def number(fields, name):
    value = fields.get(name, "")
    if not re.fullmatch(r"\d{1,15}", value):
        raise ValueError("invalid numeric field")
    return int(value)


def distribution(values):
    ordered = sorted(values)
    if not ordered:
        return {"samples": 0, "p50": None, "p95": None}
    # Nearest-rank percentiles: no interpolation and no invented zero samples.
    return {
        "samples": len(ordered),
        "p50": ordered[math.ceil(len(ordered) * 0.50) - 1],
        "p95": ordered[math.ceil(len(ordered) * 0.95) - 1],
    }


def summarize(paths):
    cloud_counts = Counter()
    error_counts = Counter()
    totals = Counter()
    successful_totals = Counter()
    cache_states = Counter()
    cloud_durations = defaultdict(list)
    client_counts = Counter()
    client_durations = defaultdict(list)
    trace_durations = defaultdict(list)
    rejected = 0
    cloud_requests = 0
    for path in paths:
        with path.open(encoding="utf-8", errors="replace") as source:
            for line in source:
                marker = next((item for item in ("nearby.cache ", "preload.metric ", "preload.trace ")
                               if item in line), None)
                if marker is None:
                    continue
                # Only whitelisted enums and numbers survive; raw lines never leave the parser.
                fields = dict(FIELDS.findall(line.split(marker, 1)[1]))
                try:
                    if marker == "nearby.cache ":
                        state, outcome, page = fields.get("state"), fields.get("outcome"), fields.get("page")
                        error = fields.get("error")
                        if (state not in CLOUD_STATES or outcome not in {"success", "error"}
                                or page not in {"first", "next"} or error not in ERRORS):
                            raise ValueError("invalid cloud enum")
                        values = {key: number(fields, key) for key in CLOUD_NUMBERS}
                        cloud_requests += 1
                        cache_states[state] += 1
                        cloud_counts[f"{page}/{state}/{outcome}"] += 1
                        error_counts[error] += 1
                        for key in ("candidateDbQueries", "profileDbQueries", "mediaDbQueries", "profileFailures"):
                            totals[key] += values[key]
                        if outcome == "success":
                            for key in ("cards", "profileDbQueries", "mediaDbQueries"):
                                successful_totals[key] += values[key]
                        # Failure latency is a separate distribution, never counted as a fast success.
                        for key in ("totalMs", "candidateDbMs", "cacheReadMs", "cacheWriteMs", "hydrationMs"):
                            cloud_durations[f"{page}/{state}/{outcome}/{key}"].append(values[key])
                    elif marker == "preload.metric ":
                        event, state = fields.get("event"), fields.get("state")
                        if event not in EVENTS or state not in STATES:
                            raise ValueError("invalid client enum")
                        duration = number(fields, "durationMs")
                        number(fields, "count")
                        key = f"{event}/{state}"
                        client_counts[key] += 1
                        client_durations[key].append(duration)
                    else:
                        name = fields.get("name")
                        if name not in TRACES:
                            raise ValueError("invalid trace enum")
                        trace_durations[name].append(number(fields, "durationMs"))
                except ValueError:
                    rejected += 1
    cache_attempts = sum(cache_states[state] for state in ("hit", "miss", "race_hit", "fallback", "snapshot_expired"))
    returned_cards = successful_totals["cards"]
    return {
        "cloudRequests": cloud_requests,
        "cacheStates": dict(sorted(cache_states.items())),
        "directHitRateAmongCacheAttempts": cache_states["hit"] / cache_attempts if cache_attempts else None,
        "cloudCounts": dict(sorted(cloud_counts.items())),
        "cacheErrorCounts": dict(sorted(error_counts.items())),
        "queryTotals": dict(sorted(totals.items())),
        "successfulReturnedCards": returned_cards,
        "profileQueriesPerReturnedCard": successful_totals["profileDbQueries"] / returned_cards if returned_cards else None,
        "mediaQueriesPerReturnedCard": successful_totals["mediaDbQueries"] / returned_cards if returned_cards else None,
        "cloudLatencyMs": {key: distribution(values) for key, values in sorted(cloud_durations.items())},
        "clientCounts": dict(sorted(client_counts.items())),
        "clientLatencyMs": {key: distribution(values) for key, values in sorted(client_durations.items())},
        "traceLatencyMsIncludingFailures": {
            key: distribution(values) for key, values in sorted(trace_durations.items())
        },
        "rejectedMetricLines": rejected,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="+", type=Path, help="UTF-8 text logs from one measurement group")
    parser.add_argument("--phase", required=True, choices=("baseline", "cache", "rollback"))
    parser.add_argument("--scenario", required=True,
                        choices=("cold", "warm", "refresh", "paging", "detail", "offline", "fault", "isolation"))
    parser.add_argument("--network", required=True, choices=("wifi", "cellular", "offline", "other"))
    args = parser.parse_args()
    try:
        result = summarize(args.logs)
    except OSError:
        parser.exit(2, "Cannot read an input log; check its path and read permissions.\n")
    result["group"] = {"phase": args.phase, "scenario": args.scenario, "network": args.network}
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
