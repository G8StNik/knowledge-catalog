"""Transactional, checksummed VNNN SQL migrations; explicit operator command."""
import argparse
import hashlib
import os
from pathlib import Path
import re

import psycopg

MIGRATIONS = Path(__file__).resolve().parents[2] / "database" / "migrations"


def migrate(dsn: str, directory: Path = MIGRATIONS) -> list[str]:
    paths = sorted(directory.glob("V*__*.sql"))
    versions = []
    for path in paths:
        match = re.fullmatch(r"V(\d{3})__[a-z0-9_]+\.sql", path.name)
        if not match:
            raise ValueError(f"Invalid migration name: {path.name}")
        versions.append(int(match[1]))
    if len(versions) != len(set(versions)):
        raise ValueError("Duplicate migration version")
    applied = []
    with psycopg.connect(dsn, autocommit=True) as conn:
        conn.execute("SELECT pg_advisory_lock(724001003)")
        try:
            conn.execute("CREATE SCHEMA IF NOT EXISTS kc_migrations")
            conn.execute("REVOKE ALL ON SCHEMA kc_migrations FROM PUBLIC")
            conn.execute("""CREATE TABLE IF NOT EXISTS kc_migrations.history (
                version integer PRIMARY KEY, name text NOT NULL, checksum text NOT NULL,
                applied_at timestamptz NOT NULL DEFAULT clock_timestamp())""")
            existing = {r[0]: r[1:] for r in conn.execute(
                "SELECT version, name, checksum FROM kc_migrations.history")}
            if set(existing) - set(versions):
                raise ValueError("Applied migration missing from checkout")
            # Validate the entire history before executing any new migration.
            pending = []
            for version, path in zip(versions, paths):
                raw = path.read_bytes()
                checksum = hashlib.sha256(raw).hexdigest()
                if version in existing:
                    if existing[version] != (path.name, checksum):
                        raise ValueError(f"Applied migration changed: {path.name}")
                else:
                    if existing and version < max(existing):
                        raise ValueError("Out-of-order migration")
                    pending.append((version, path, raw, checksum))
            for version, path, raw, checksum in pending:
                with conn.transaction():
                    conn.execute(raw.decode("utf-8"))
                    conn.execute("INSERT INTO kc_migrations.history(version,name,checksum) VALUES (%s,%s,%s)",
                                 (version, path.name, checksum))
                applied.append(path.name)
        finally:
            conn.execute("SELECT pg_advisory_unlock(724001003)")
    return applied


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, default=MIGRATIONS)
    args = parser.parse_args()
    print("Applied:", migrate(os.environ["KC_MIGRATION_DSN"], args.directory))
