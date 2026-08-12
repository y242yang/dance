import sys

from db import get_studios, delete_past_classes, delete_past_log_entries
from scraper import scrape_all

def run() -> dict:
    print("Starting daily scrape...")
    delete_past_classes()
    delete_past_log_entries()
    studios = get_studios()
    print(f"Found {len(studios)} studios")
    summary = scrape_all(studios)
    print("Done.")
    return summary


def exit_code(summary: dict) -> int:
    """0 if every studio's data was written, 1 if any studio's write didn't happen.

    The daily GitHub Actions run is unattended, so the exit code is the only thing
    that reaches anyone: a failed scheduled run emails the repo owner, a green one
    says nothing. Every failure this has caught so far was already described
    correctly in the logs and went unnoticed for days anyway (Enjoy Dance Studio,
    2026-08-10 and 08-11: the write rejected, existing rows preserved, run green).

    Only `failed` fails the run, deliberately NOT `partial`. Partial is the normal
    resting state for several studios -- Full Out Studios and VIBE AT THE WALL hit
    their booking widgets' pagination limits most days and legitimately can't reach
    the cutoff -- so failing on partial would mean a red run nearly every day, and a
    signal that's always red carries exactly as much information as one that's always
    green. `failed` means a studio kept serving old data, which is never routine.

    Zero studios is also a failure: an empty studio list means the DB query or the
    config is broken, not that there was no work to do."""
    if not summary.get("total"):
        print("FAIL: no studios were scraped at all — check the studios table.")
        return 1
    failed = summary.get("failed") or []
    if failed:
        print(f"FAIL: {len(failed)} studio(s) kept stale data: {', '.join(sorted(failed))}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(exit_code(run()))
