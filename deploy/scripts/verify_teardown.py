"""Check whether Meridian's deployed Databricks objects have been torn down.

Read-only -- makes no changes, only reports what it finds. Checks the three
medallion schemas (bronze/silver/gold), the orchestration job, and the
Lakeflow pipeline: everything docs/deployment-strategy.md's "Full lifecycle"
destroys.

Job and pipeline names are matched by substring rather than exact name,
because the bundle's `dev` target uses `mode: development`
(deploy/databricks.yml), which prefixes deployed resource names with
`[dev <username>]` -- the workspace never has a job literally named
"meridian_pipeline_job", only one whose name contains that string.

Usage:
    python deploy/scripts/verify_teardown.py [--prefix meridian] [--catalog workspace]

Exit code is 0 if everything's gone, 1 if anything still exists.
"""

from __future__ import annotations

import argparse

from databricks.sdk import WorkspaceClient
from databricks.sdk.errors import NotFound

CATALOG_DEFAULT = "workspace"
PREFIX_DEFAULT = "meridian"
JOB_NAME_DEFAULT = "meridian_pipeline_job"
PIPELINE_NAME_DEFAULT = "meridian_pipeline"
LAYERS = ("bronze", "silver", "gold")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", default=PREFIX_DEFAULT, help="Schema prefix (default: %(default)s)")
    parser.add_argument("--catalog", default=CATALOG_DEFAULT, help="Unity Catalog catalog name (default: %(default)s)")
    parser.add_argument("--job-name", default=JOB_NAME_DEFAULT, help="Job name substring to search for (default: %(default)s)")
    parser.add_argument(
        "--pipeline-name", default=PIPELINE_NAME_DEFAULT, help="Pipeline name substring to search for (default: %(default)s)"
    )
    return parser.parse_args(argv)


def schema_exists(client: WorkspaceClient, catalog: str, schema_name: str) -> bool:
    """True if catalog.schema_name still exists."""
    try:
        client.schemas.get(f"{catalog}.{schema_name}")
        return True
    except NotFound:
        return False


def job_exists(client: WorkspaceClient, name_substring: str) -> bool:
    """True if any job's name contains name_substring."""
    return any(name_substring in (job.settings.name or "") for job in client.jobs.list(name=name_substring))


def pipeline_exists(client: WorkspaceClient, name_substring: str) -> bool:
    """True if any pipeline's name contains name_substring."""
    return any(name_substring in (pipeline.name or "") for pipeline in client.pipelines.list_pipelines())


def main(argv: list[str] | None = None, client: WorkspaceClient | None = None) -> int:
    args = parse_args(argv)
    client = client or WorkspaceClient()
    clean = True

    for layer in LAYERS:
        schema_name = f"{args.prefix}_{layer}"
        found = schema_exists(client, args.catalog, schema_name)
        print(f"schema {args.catalog}.{schema_name}: {'still exists' if found else 'gone'}")
        clean = clean and not found

    found = job_exists(client, args.job_name)
    print(f"job matching '{args.job_name}': {'still exists' if found else 'gone'}")
    clean = clean and not found

    found = pipeline_exists(client, args.pipeline_name)
    print(f"pipeline matching '{args.pipeline_name}': {'still exists' if found else 'gone'}")
    clean = clean and not found

    print("Everything torn down." if clean else "Still cleaning up -- see above.")
    return 0 if clean else 1


if __name__ == "__main__":
    raise SystemExit(main())
