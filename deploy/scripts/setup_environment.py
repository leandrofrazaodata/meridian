"""Create the Meridian medallion schemas (bronze/silver/gold) in Unity Catalog.

Idempotent -- safe to re-run; schemas that already exist are left alone.
Owned by this script, not the DAB bundle in deploy/ -- see
docs/deployment-strategy.md for why.

Usage:
    python deploy/scripts/setup_environment.py [--prefix meridian] [--catalog workspace]
        [--grant-read-to PRINCIPAL]

The --prefix default matches deploy/databricks.yml's schema_prefix bundle
variable default, so an unmodified run of each tool reaches the same
schemas -- see docs/deployment-strategy.md's "Schema prefix" section.

Schemas are owned by whoever runs this script -- run it as the service
principal (docs/deployment-strategy.md "Identity"), and use
--grant-read-to so humans can still query the SP-owned schemas.
"""
from __future__ import annotations

import argparse

from databricks.sdk import WorkspaceClient
from databricks.sdk.errors import NotFound
from databricks.sdk.service.catalog import PermissionsChange, Privilege

CATALOG_DEFAULT = "workspace"
PREFIX_DEFAULT = "meridian"
LAYERS = ("bronze", "silver", "gold")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", default=PREFIX_DEFAULT, help="Schema prefix (default: %(default)s)")
    parser.add_argument("--catalog", default=CATALOG_DEFAULT, help="Unity Catalog catalog name (default: %(default)s)")
    parser.add_argument(
        "--grant-read-to",
        metavar="PRINCIPAL",
        help="Also grant USE SCHEMA + SELECT on every schema to this principal "
        "(user, group, or SP application ID) -- e.g. 'account users'",
    )
    args = parser.parse_args(argv)
    if args.grant_read_to is not None and not args.grant_read_to.strip():
        parser.error("--grant-read-to must not be empty")
    return args


def ensure_schema(client: WorkspaceClient, catalog: str, schema_name: str) -> bool:
    """Create catalog.schema_name if it doesn't exist yet.

    Returns True if it was created, False if it already existed.
    """
    full_name = f"{catalog}.{schema_name}"
    try:
        client.schemas.get(full_name)
        return False
    except NotFound:
        client.schemas.create(name=schema_name, catalog_name=catalog)
        return True


def grant_read(client: WorkspaceClient, catalog: str, schema_name: str, principal: str) -> None:
    """Grant USE SCHEMA + SELECT on catalog.schema_name to principal. Additive, so re-running is harmless."""
    client.grants.update(
        "schema",
        f"{catalog}.{schema_name}",
        changes=[PermissionsChange(principal=principal, add=[Privilege.USE_SCHEMA, Privilege.SELECT])],
    )


def main(argv: list[str] | None = None, client: WorkspaceClient | None = None) -> None:
    args = parse_args(argv)
    client = client or WorkspaceClient()
    for layer in LAYERS:
        schema_name = f"{args.prefix}_{layer}"
        created = ensure_schema(client, args.catalog, schema_name)
        status = "created" if created else "already exists"
        print(f"{args.catalog}.{schema_name}: {status}")
        if args.grant_read_to:
            grant_read(client, args.catalog, schema_name, args.grant_read_to)
            print(f"{args.catalog}.{schema_name}: read granted to {args.grant_read_to}")


if __name__ == "__main__":
    main()
