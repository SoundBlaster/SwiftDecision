"""Package an already converted checkpoint. No model download or inference."""
import argparse
import hashlib
import json
import shutil
import zipfile
from pathlib import Path

MODEL = "fastino/gliner2.5-small-v1"
REVISION = "df5910e44bc4ffdb0d95399a83b0ca4516349aa5"
NAME = "gliner2.5-small-coreml-int8-v1"
RUNTIME = ["gliner.json", "tokenizer.json", "tokenizer_config.json", "GLiNERSmall.mlpackage"]


def package(checkpoint, output):
    if output.exists():
        raise ValueError("output must be a new directory")
    metadata = json.loads((checkpoint / "gliner.json").read_text())
    if (metadata.get("modelID"), metadata.get("revision"), metadata.get("weightBits"), metadata.get("computePrecision")) != (MODEL, REVISION, 8, "float32"):
        raise ValueError("checkpoint identity or precision does not match this distribution")
    # Validate before copying; never follow symlinks or include development artifacts.
    for name in RUNTIME:
        source = checkpoint / name
        if not source.exists() or source.is_symlink():
            raise ValueError("missing or symlinked runtime input")
        for path in source.rglob("*") if source.is_dir() else [source]:
            if path.is_symlink() or not (path.is_dir() or path.is_file()):
                raise ValueError("unsupported runtime entry")
    root = output / "GLiNERSmall"
    root.mkdir(parents=True)
    for name in RUNTIME:
        source = checkpoint / name
        if source.is_dir(): shutil.copytree(source, root / name)
        else: shutil.copy2(source, root / name)
    for source in Path(__file__).with_name("licenses").iterdir():
        if source.is_file(): shutil.copy2(source, root / source.name)
    (root / "CHANGES.md").write_text(f"# Converted model\n\nSource: {MODEL}@{REVISION}.\nConverted by the SwiftDecision project; not an official Fastino export.\nEncoder and classification head only; Core ML mlprogram, INT8 symmetric weights, FP32 computation, fixed 256-token input. No additional training.\nConversion source: Scripts/gliner/prepare.py in https://github.com/SoundBlaster/SwiftDecision.\nBackbone: microsoft/deberta-v3-xsmall (MIT). Preserve the included license texts.\n")
    files = []
    for path in sorted(root.rglob("*")):
        if path.is_file():
            data = path.read_bytes()
            files.append({"path": path.relative_to(root).as_posix(), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    manifest = {"formatVersion": 1, "distributionID": NAME, "modelID": MODEL, "revision": REVISION, "files": files}
    (root / "distribution.json").write_text(json.dumps(manifest, indent=2) + "\n")
    archive = output / (NAME + ".zip")
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for path in sorted(root.rglob("*")):
            if path.is_file():
                info = zipfile.ZipInfo(path.relative_to(output).as_posix(), (2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                z.writestr(info, path.read_bytes())
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / "SHA256SUMS").write_text(f"{digest}  {archive.name}\n")
    # This archive is packaged separately by Xcode, not embedded in an app bundle.
    apple = {"assetPackID": "com.soundblaster.oracleball.gliner-small-v1", "downloadPolicy": {"onDemand": {}}, "fileSelectors": [{"directory": "GLiNERSmall"}], "platforms": ["iOS"]}
    (output / "AppleManifest.json").write_text(json.dumps(apple, indent=2) + "\n")
    return manifest, archive


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    manifest, archive = package(args.checkpoint, args.output)
    print(json.dumps({"archive": str(archive), "archiveBytes": archive.stat().st_size, "files": len(manifest["files"])}))
