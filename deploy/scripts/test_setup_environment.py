from unittest.mock import MagicMock, call

from databricks.sdk.errors import NotFound

from setup_environment import LAYERS, ensure_schema, main


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
