from unittest.mock import MagicMock

from databricks.sdk.errors import NotFound

from verify_teardown import LAYERS, job_exists, main, pipeline_exists, schema_exists


def _job(name):
    job = MagicMock()
    job.settings.name = name
    return job


def _pipeline(name):
    pipeline = MagicMock()
    pipeline.name = name
    return pipeline


def test_schema_exists_true_when_found():
    client = MagicMock()
    client.schemas.get.return_value = object()  # any truthy SchemaInfo-like value

    assert schema_exists(client, "workspace", "meridian_bronze") is True


def test_schema_exists_false_when_not_found():
    client = MagicMock()
    client.schemas.get.side_effect = NotFound("no such schema")

    assert schema_exists(client, "workspace", "meridian_bronze") is False


def test_job_exists_true_when_name_matches():
    client = MagicMock()
    client.jobs.list.return_value = [_job("[dev leandro] meridian_etl_orchestrator")]

    assert job_exists(client, "meridian_etl_orchestrator") is True


def test_job_exists_false_when_no_jobs():
    client = MagicMock()
    client.jobs.list.return_value = []

    assert job_exists(client, "meridian_etl_orchestrator") is False


def test_pipeline_exists_true_when_name_matches():
    client = MagicMock()
    client.pipelines.list_pipelines.return_value = [_pipeline("[dev leandro] meridian_silver_pipeline")]

    assert pipeline_exists(client, "meridian_silver_pipeline") is True


def test_pipeline_exists_false_when_no_pipelines():
    client = MagicMock()
    client.pipelines.list_pipelines.return_value = []

    assert pipeline_exists(client, "meridian_silver_pipeline") is False


def test_main_reports_clean_and_returns_zero():
    assert LAYERS == ("bronze", "silver", "gold")

    client = MagicMock()
    client.schemas.get.side_effect = NotFound("no such schema")
    client.jobs.list.return_value = []
    client.pipelines.list_pipelines.return_value = []

    assert main([], client=client) == 0


def test_main_reports_dirty_and_returns_one_when_schema_remains():
    client = MagicMock()
    client.schemas.get.return_value = object()  # all three "exist"
    client.jobs.list.return_value = []
    client.pipelines.list_pipelines.return_value = []

    assert main([], client=client) == 1


def test_main_reports_dirty_when_job_remains():
    client = MagicMock()
    client.schemas.get.side_effect = NotFound("no such schema")
    client.jobs.list.return_value = [_job("[dev leandro] meridian_etl_orchestrator")]
    client.pipelines.list_pipelines.return_value = []

    assert main([], client=client) == 1


def test_main_reports_dirty_when_only_silver_pipeline_remains():
    client = MagicMock()
    client.schemas.get.side_effect = NotFound("no such schema")
    client.jobs.list.return_value = []
    client.pipelines.list_pipelines.return_value = [_pipeline("[dev leandro] meridian_silver_pipeline")]

    assert main([], client=client) == 1


def test_main_reports_dirty_when_only_gold_pipeline_remains():
    client = MagicMock()
    client.schemas.get.side_effect = NotFound("no such schema")
    client.jobs.list.return_value = []
    client.pipelines.list_pipelines.return_value = [_pipeline("[dev leandro] meridian_gold_pipeline")]

    assert main([], client=client) == 1


def test_main_honors_custom_prefix_and_catalog():
    client = MagicMock()
    client.schemas.get.side_effect = NotFound("no such schema")
    client.jobs.list.return_value = []
    client.pipelines.list_pipelines.return_value = []

    main(["--prefix", "meridian_dev", "--catalog", "sandbox"], client=client)

    client.schemas.get.assert_any_call("sandbox.meridian_dev_bronze")
    client.schemas.get.assert_any_call("sandbox.meridian_dev_silver")
    client.schemas.get.assert_any_call("sandbox.meridian_dev_gold")
