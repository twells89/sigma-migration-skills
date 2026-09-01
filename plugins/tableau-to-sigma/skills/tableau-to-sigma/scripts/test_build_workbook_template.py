import importlib.util
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "build-workbook-template.py"
spec = importlib.util.spec_from_file_location("build_workbook_template", SCRIPT)
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class BuildWorkbookTemplateTest(unittest.TestCase):
    def template(self):
        return {
            "name": "Migration Fixture",
            "folderId": "__FOLDER_ID__",
            "document": {
                "schemaVersion": 1,
                "kind": "workbook",
                "elements": [
                    {
                        "id": "master",
                        "kind": "table",
                        "source": {
                            "kind": "data-model",
                            "dataModelId": "__DATA_MODEL_ID__",
                            "elementId": "__DATA_MODEL_ELEMENT_ID__",
                        },
                        "columns": [
                            {
                                "id": "metric",
                                "name": "Metric",
                                "formula": "[FACT/Metric]",
                            }
                        ],
                    }
                ],
                "pages": [{"id": "page", "name": "Overview"}],
                "layout": (
                    '<Page type="grid" id="page">'
                    '<Element elementId="master"/></Page>'
                ),
            },
        }

    def test_binds_live_identifiers_and_validates_layout(self):
        result = builder.bind(
            self.template(),
            {
                "__FOLDER_ID__": "folder-1",
                "__DATA_MODEL_ID__": "model-1",
                "__DATA_MODEL_ELEMENT_ID__": "element-1",
            },
        )
        builder.validate(result)
        self.assertEqual("folder-1", result["folderId"])
        self.assertEqual(
            "model-1",
            result["document"]["elements"][0]["source"]["dataModelId"],
        )

    def test_unplaced_element_is_rejected(self):
        template = self.template()
        template["document"]["layout"] = '<Page type="grid" id="page"/>'
        with self.assertRaisesRegex(ValueError, "place every element"):
            builder.validate(
                builder.bind(
                    template,
                    {
                        "__FOLDER_ID__": "folder",
                        "__DATA_MODEL_ID__": "model",
                        "__DATA_MODEL_ELEMENT_ID__": "element",
                    },
                )
            )


if __name__ == "__main__":
    unittest.main()
