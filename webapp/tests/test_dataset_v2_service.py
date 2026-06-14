from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from webapp.app.services.dataset_v2_service import (
    build_project_dataset_items,
    build_unattached_dataset_items,
    scan_project_csv_references,
)


def _write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


class DatasetV2ServiceTest(unittest.TestCase):
    def test_scan_project_csv_references_resolves_env_and_marks_invalid_path(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project_dir = root / "scenario" / "demo"

            _write(project_dir / ".env", "data_dir=/opt/jmeter/apache-jmeter/bin\n")
            _write(
                project_dir / "demo.jmx",
                """<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<jmeterTestPlan>
  <hashTree>
    <TestPlan>
      <elementProp name=\"TestPlan.user_defined_variables\" elementType=\"Arguments\">
        <collectionProp name=\"Arguments.arguments\">
          <elementProp name=\"data_dir\" elementType=\"Argument\">
            <stringProp name=\"Argument.name\">data_dir</stringProp>
            <stringProp name=\"Argument.value\">${__P(data_dir, ${data_dir})}</stringProp>
          </elementProp>
        </collectionProp>
      </elementProp>
    </TestPlan>
    <hashTree>
      <CSVDataSet>
        <stringProp name=\"filename\">${data_dir}/valid.csv</stringProp>
      </CSVDataSet>
      <CSVDataSet>
        <stringProp name=\"filename\">/tmp/invalid.csv</stringProp>
      </CSVDataSet>
      <CSVDataSet>
        <stringProp name=\"filename\">relative.csv</stringProp>
      </CSVDataSet>
    </hashTree>
  </hashTree>
</jmeterTestPlan>
""",
            )

            refs = scan_project_csv_references(project_dir)
            by_name = {ref.dataset_name: ref for ref in refs}

            self.assertIn("valid.csv", by_name)
            self.assertIn("invalid.csv", by_name)
            self.assertIn("relative.csv", by_name)

            self.assertTrue(by_name["valid.csv"].path_valid)
            self.assertFalse(by_name["invalid.csv"].path_valid)
            self.assertTrue(by_name["relative.csv"].path_valid)

    def test_build_project_dataset_items_returns_expected_statuses(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            scenario_dir = root / "scenario"
            project_dir = scenario_dir / "demo"
            dataset_dir = scenario_dir / "dataset"

            _write(project_dir / ".env", "data_dir=/opt/jmeter/apache-jmeter/bin\n")
            _write(
                project_dir / "demo.jmx",
                """<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<jmeterTestPlan>
  <hashTree>
    <CSVDataSet>
      <stringProp name=\"filename\">${data_dir}/uploaded.csv</stringProp>
    </CSVDataSet>
    <CSVDataSet>
      <stringProp name=\"filename\">${data_dir}/missing.csv</stringProp>
    </CSVDataSet>
    <CSVDataSet>
      <stringProp name=\"filename\">/var/tmp/invalid.csv</stringProp>
    </CSVDataSet>
  </hashTree>
</jmeterTestPlan>
""",
            )
            _write(dataset_dir / "uploaded.csv", "a,b\n1,2\n")

            items = build_project_dataset_items(project_dir=project_dir, dataset_dir=dataset_dir, owner_section={})
            status_by_name = {item["name"]: item for item in items}

            self.assertEqual(status_by_name["uploaded.csv"]["status"], "已上傳")
            self.assertEqual(status_by_name["missing.csv"]["status"], "尚未上傳")
            self.assertEqual(status_by_name["invalid.csv"]["status"], "路徑不正確")
            self.assertFalse(status_by_name["invalid.csv"]["can_upload"])

    def test_build_unattached_dataset_items_filters_out_referenced_files(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            scenario_dir = root / "scenario"
            dataset_dir = scenario_dir / "dataset"
            project_dir = scenario_dir / "demo"

            _write(project_dir / ".env", "data_dir=/opt/jmeter/apache-jmeter/bin\n")
            _write(
                project_dir / "demo.jmx",
                """<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<jmeterTestPlan>
  <hashTree>
    <CSVDataSet>
      <stringProp name=\"filename\">${data_dir}/used.csv</stringProp>
    </CSVDataSet>
  </hashTree>
</jmeterTestPlan>
""",
            )
            _write(dataset_dir / "used.csv", "a\n1\n")
            _write(dataset_dir / "orphan.csv", "a\n2\n")

            items = build_unattached_dataset_items(
                dataset_dir=dataset_dir,
                projects=["demo"],
                scenario_dir=scenario_dir,
                owner_section={},
            )

            names = [item["name"] for item in items]
            self.assertEqual(names, ["orphan.csv"])
            self.assertTrue(items[0]["show_delete"])


if __name__ == "__main__":
    unittest.main()
