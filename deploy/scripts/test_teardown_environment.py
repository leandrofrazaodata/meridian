from unittest.mock import MagicMock

import pytest
from databricks.sdk.service.sql import StatementState

from teardown_environment import LAYERS, drop_schema_cascade, main


def _response(state):
    response = MagicMock()
    response.status.state = state
    response.status.error = None
    return response


def test_drop_schema_cascade_succeeds_silently_on_success():
    client = MagicMock()
    client.statement_execution.execute_statement.return_value = _response(StatementState.SUCCEEDED)

    drop_schema_cascade(client, "wh-123", "workspace", "meridian_bronze")

    client.statement_execution.execute_statement.assert_called_once_with(
        warehouse_id="wh-123",
        statement="DROP SCHEMA IF EXISTS workspace.meridian_bronze CASCADE",
        wait_timeout="30s",
    )


def test_drop_schema_cascade_raises_on_failure():
    client = MagicMock()
    client.statement_execution.execute_statement.return_value = _response(StatementState.FAILED)

    with pytest.raises(RuntimeError, match="meridian_bronze"):
        drop_schema_cascade(client, "wh-123", "workspace", "meridian_bronze")


def test_main_drops_all_three_layers_gold_first():
    client = MagicMock()
    client.statement_execution.execute_statement.return_value = _response(StatementState.SUCCEEDED)

    main(["--warehouse-id", "wh-123"], client=client)

    statements = [c.kwargs["statement"] for c in client.statement_execution.execute_statement.call_args_list]
    assert statements == [
        "DROP SCHEMA IF EXISTS workspace.meridian_gold CASCADE",
        "DROP SCHEMA IF EXISTS workspace.meridian_silver CASCADE",
        "DROP SCHEMA IF EXISTS workspace.meridian_bronze CASCADE",
    ]


def test_main_requires_warehouse_id():
    with pytest.raises(SystemExit):
        main([])
