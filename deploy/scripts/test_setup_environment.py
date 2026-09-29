from unittest.mock import MagicMock, call

import pytest
from databricks.sdk.errors import NotFound
from databricks.sdk.service.catalog import PermissionsChange, Privilege

from setup_environment import LAYERS, ensure_schema, grant_read, main


def test_ensure_schema_creates_when_missing():
    client = MagicMock()
    client.schemas.get.side_effect = NotFound("no such schema")

    created = ensure_schema(client, "workspace", "meridian_bronze")

    assert created is True
    client.schemas.get.assert_called_once_with("workspace.meridian_bronze")
    client.schemas.create.assert_called_once_with(name="meridian_bronze", catalog_name="workspace")


def test_ensure_schema_skips_when_present():
    client = MagicMock()
    client.schemas.get.return_value = object()  # any truthy SchemaInfo-like value

    created = ensure_schema(client, "workspace", "meridian_bronze")

    assert created is False
    client.schemas.create.assert_not_called()


def test_main_creates_all_three_layers_with_default_prefix():
    assert LAYERS == ("bronze", "silver", "gold")

    client = MagicMock()
    client.schemas.get.side_effect = NotFound("no such schema")

    main([], client=client)

    expected = [call(name=f"meridian_{layer}", catalog_name="workspace") for layer in LAYERS]
    assert client.schemas.create.call_args_list == expected


def test_main_honors_custom_prefix_and_catalog():
    client = MagicMock()
    client.schemas.get.side_effect = NotFound("no such schema")

    main(["--prefix", "meridian_dev", "--catalog", "sandbox"], client=client)

    expected = [call(name=f"meridian_dev_{layer}", catalog_name="sandbox") for layer in LAYERS]
    assert client.schemas.create.call_args_list == expected


def test_grant_read_adds_use_schema_and_select():
    client = MagicMock()

    grant_read(client, "workspace", "meridian_gold", "account users")

    client.grants.update.assert_called_once_with(
        "schema",
        "workspace.meridian_gold",
        changes=[PermissionsChange(principal="account users", add=[Privilege.USE_SCHEMA, Privilege.SELECT])],
    )


def test_main_grants_read_on_all_layers_when_flag_set():
    client = MagicMock()
    client.schemas.get.return_value = object()  # schemas already exist -- grants must still apply

    main(["--grant-read-to", "account users"], client=client)

    granted = [c.args[1] for c in client.grants.update.call_args_list]
    assert granted == [f"workspace.meridian_{layer}" for layer in LAYERS]


def test_main_skips_grants_by_default():
    client = MagicMock()
    client.schemas.get.side_effect = NotFound("no such schema")

    main([], client=client)

    client.grants.update.assert_not_called()


def test_main_rejects_empty_grant_principal():
    client = MagicMock()

    with pytest.raises(SystemExit):
        main(["--grant-read-to", ""], client=client)

    client.schemas.create.assert_not_called()
    client.grants.update.assert_not_called()
