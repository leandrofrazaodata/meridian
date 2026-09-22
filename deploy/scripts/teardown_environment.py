"""Drop the Meridian medallion schemas (bronze/silver/gold), cascading.

Soft delete: Unity Catalog keeps dropped schemas recoverable for 7 days,
purged permanently within 48 hours after that -- see
docs/deployment-strategy.md's "What the scripts own" section for why this
runs raw SQL instead of the SDK's schemas.delete() (no CASCADE option
there). Never touches the raw-data Volume.

Usage:
    python deploy/scripts/teardown_environment.py --warehouse-id <id> \
        [--prefix meridian] [--catalog workspace]
"""
from __future__ import annotations

import argparse

from databricks.sdk import WorkspaceClient
from databricks.sdk.service.sql import StatementState

CATALOG_DEFAULT = "workspace"
PREFIX_DEFAULT = "meridian"
# Drop in the reverse of setup_environment.py's creation order -- no
# dependency between the three schemas requires this, but it keeps
# teardown a deliberate mirror of setup rather than an arbitrary order.
LAYERS = ("gold", "silver", "bronze")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--warehouse-id", required=True, help="SQL warehouse ID to run the DROP statements on")
    parser.add_argument("--prefix", default=PREFIX_DEFAULT, help="Schema prefix (default: %(default)s)")
    parser.add_argument("--catalog", default=CATALOG_DEFAULT, help="Unity Catalog catalog name (default: %(default)s)")
    return parser.parse_args(argv)


def drop_schema_cascade(client: WorkspaceClient, warehouse_id: str, catalog: str, schema_name: str) -> None:
    statement = f"DROP SCHEMA IF EXISTS {catalog}.{schema_name} CASCADE"
    response = client.statement_execution.execute_statement(
        warehouse_id=warehouse_id,
        statement=statement,
        wait_timeout="30s",
    )
    state = response.status.state
    if state != StatementState.SUCCEEDED:
        error = getattr(response.status, "error", None)
        raise RuntimeError(f"{statement} did not succeed (state={state}): {error}")


def main(argv: list[str] | None = None, client: WorkspaceClient | None = None) -> None:
    args = parse_args(argv)
    client = client or WorkspaceClient()
    for layer in LAYERS:
        schema_name = f"{args.prefix}_{layer}"
        drop_schema_cascade(client, args.warehouse_id, args.catalog, schema_name)
        print(f"{args.catalog}.{schema_name}: dropped (cascade)")


if __name__ == "__main__":
    main()
