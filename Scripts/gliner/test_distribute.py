import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from distribute import MODEL, REVISION, package


class DistributionTests(unittest.TestCase):
    def checkpoint(self, root):
        path = root / "checkpoint"
        (path / "GLiNERSmall.mlpackage").mkdir(parents=True)
        (path / "GLiNERSmall.mlpackage" / "weights.bin").write_bytes(b"weights")
        (path / "tokenizer.json").write_text("{}")
        (path / "tokenizer_config.json").write_text("{}")
        (path / "gliner.json").write_text(json.dumps({"modelID": MODEL, "revision": REVISION, "weightBits": 8, "computePrecision": "float32"}))
        (path / "reference.json").write_text("not for distribution")
        return path

    def test_reproducible_archive_and_inventory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = self.checkpoint(root)
            manifest, archive = package(source, root / "first")
            _, second = package(source, root / "second")
            self.assertEqual(archive.read_bytes(), second.read_bytes())
            paths = {x["path"] for x in manifest["files"]}
            self.assertIn("LICENSE-APACHE-2.0.txt", paths)
            self.assertIn("LICENSE-MIT-DeBERTa.txt", paths)
            self.assertNotIn("reference.json", paths)
            apple = json.loads((root / "first/AppleManifest.json").read_text())
            self.assertRegex(apple["assetPackID"], r"^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$")
            self.assertEqual(apple["downloadPolicy"], {"onDemand": {}})
            for entry in manifest["files"]:
                self.assertEqual(hashlib.sha256((root / "first/GLiNERSmall" / entry["path"]).read_bytes()).hexdigest(), entry["sha256"])

    def test_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = self.checkpoint(root)
            (source / "GLiNERSmall.mlpackage/link").symlink_to(source / "reference.json")
            with self.assertRaises(ValueError): package(source, root / "out")

    def test_rejects_wrong_model(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = self.checkpoint(root)
            (source / "gliner.json").write_text("{}")
            with self.assertRaises(ValueError): package(source, root / "out")


if __name__ == "__main__": unittest.main()
