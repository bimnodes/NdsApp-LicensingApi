#!/usr/bin/env python3
"""Validate immutable Supabase migrations and explicit Data API access intent."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

MIGRATION_ROOT = "supabase/migrations/"
RESTORED_MARKER = "-- nds-migration-governance: restored-applied-migration"
RESTORED_ALLOWLIST = {
    "20260903083200_harden_stripe_subscription_license_sync.sql",
}

TABLE_CREATE_RE = re.compile(
    r"\bcreate\s+table\s+(?:if\s+not\s+exists\s+)?"
    r"(?P<name>public\.[A-Za-z_][A-Za-z0-9_$]*)",
    re.IGNORECASE,
)
FUNCTION_CREATE_RE = re.compile(
    r"\bcreate\s+(?:or\s+replace\s+)?function\s+"
    r"(?P<name>public\.[A-Za-z_][A-Za-z0-9_$]*)\s*\(",
    re.IGNORECASE,
)


def _git(*args: str) -> str:
    completed = subprocess.run(
        ["git", *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return completed.stdout


def _object_pattern(name: str) -> str:
    return re.escape(name)


def validate_sql(path: str, sql: str) -> list[str]:
    """Return governance violations for one newly added migration."""
    errors: list[str] = []
    filename = Path(path).name

    if RESTORED_MARKER in sql:
        if filename in RESTORED_ALLOWLIST:
            return []
        errors.append(
            f"{path}: restored-applied-migration marker is reserved for explicitly "
            "allowlisted historical recoveries."
        )
        return errors

    tables = sorted({m.group("name") for m in TABLE_CREATE_RE.finditer(sql)})
    functions = sorted({m.group("name") for m in FUNCTION_CREATE_RE.finditer(sql)})

    for table in tables:
        escaped = _object_pattern(table)
        access_statements = re.findall(
            rf"\b(?:grant|revoke)\b[^;]*\bon\s+(?:table\s+)?{escaped}\b[^;]*;",
            sql,
            flags=re.IGNORECASE | re.DOTALL,
        )
        if not access_statements:
            errors.append(
                f"{path}: {table} is created without an explicit GRANT or REVOKE "
                "declaring its Data API access intent."
            )
            continue

        grants_to_client_roles = [
            statement
            for statement in access_statements
            if re.search(r"^\s*grant\b", statement, flags=re.IGNORECASE)
            and re.search(
                r"\bto\b[^;]*\b(?:anon|authenticated)\b",
                statement,
                flags=re.IGNORECASE | re.DOTALL,
            )
        ]
        if grants_to_client_roles:
            rls_pattern = re.compile(
                rf"\balter\s+table\s+{escaped}\s+enable\s+row\s+level\s+security\b",
                flags=re.IGNORECASE,
            )
            if not rls_pattern.search(sql):
                errors.append(
                    f"{path}: {table} grants Data API access to anon/authenticated "
                    "without enabling Row Level Security in the same migration."
                )

    for function in functions:
        escaped = _object_pattern(function)
        access_statement = re.search(
            rf"\b(?:grant|revoke)\b[^;]*\bon\s+function\s+{escaped}\s*\([^;]*\)[^;]*;",
            sql,
            flags=re.IGNORECASE | re.DOTALL,
        )
        if access_statement is None:
            errors.append(
                f"{path}: {function} is created/replaced without an explicit "
                "GRANT EXECUTE or REVOKE declaring RPC/function access."
            )

    return errors


def changed_migrations(base: str, head: str) -> list[tuple[str, str]]:
    output = _git(
        "diff",
        "--name-status",
        "--no-renames",
        base,
        head,
        "--",
        f"{MIGRATION_ROOT}*.sql",
    )
    changes: list[tuple[str, str]] = []
    for line in output.splitlines():
        if not line.strip():
            continue
        status, path = line.split("\t", 1)
        changes.append((status, path))
    return changes


def file_at_revision(revision: str, path: str) -> str:
    return _git("show", f"{revision}:{path}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True, help="Base commit SHA.")
    parser.add_argument("--head", required=True, help="Head commit SHA.")
    args = parser.parse_args()

    errors: list[str] = []
    additions: list[str] = []

    for status, path in changed_migrations(args.base, args.head):
        if status == "A":
            additions.append(path)
            continue

        errors.append(
            f"{path}: existing migration files are immutable (git status {status}). "
            "Create a new forward migration instead."
        )

    for path in additions:
        sql = file_at_revision(args.head, path)
        errors.extend(validate_sql(path, sql))

    if errors:
        print("Supabase migration governance failed:")
        for error in errors:
            print(f"  - {error}")
        return 1

    if additions:
        print(f"Validated {len(additions)} new Supabase migration(s).")
    else:
        print("No new Supabase migrations to validate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
