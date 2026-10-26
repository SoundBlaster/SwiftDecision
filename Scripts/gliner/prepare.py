"""Explicitly download and export GLiNER2.5-small's classification path.

The output is a separately provisioned local asset, not a package resource.
Run with --help. No API key, paid service, or remote inference is used.
"""
import argparse
import json
import math
import shutil
import time
from pathlib import Path

MODEL = "fastino/gliner2.5-small-v1"
REVISION = "df5910e44bc4ffdb0d95399a83b0ca4516349aa5"
SOURCE = "ca4f68235b50fe4c3ecf3876851d748fe4b15c6c"


def schema_for(prompt):
    from gliner2.classification import ClassificationSchema
    return ClassificationSchema().single(
        "decision", {o["id"]: o["description"] for o in prompt["options"]},
        instruction=prompt["instructions"],
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sequence-length", type=int, default=256)
    parser.add_argument("--weight-bits", type=int, choices=[8, 32], default=8)
    parser.add_argument("--local-files-only", action="store_true")
    parser.add_argument("--reference-only", action="store_true")
    args = parser.parse_args()
    if not 32 <= args.sequence_length <= 512:
        parser.error("sequence length must be between 32 and 512")
    if args.output.exists():
        parser.error("output must be a new directory")

    import torch
    from huggingface_hub import snapshot_download
    from gliner2.classification import Classifier
    from gliner2.classification.compiler import compile_schema
    torch.set_num_threads(4)
    checkpoint = snapshot_download(
        MODEL, revision=REVISION, cache_dir=str(args.cache_dir),
        local_files_only=args.local_files_only,
        allow_patterns=["*.json", "*.model", "model.safetensors", "encoder_config/*", "LICENSE*"],
    )
    started = time.perf_counter()
    classifier = Classifier.from_pretrained(checkpoint, device="cpu").eval()
    model = classifier.model
    if model.processor.token_pooling != "first":
        raise ValueError("export supports only first-token pooling")
    args.output.mkdir(parents=True)
    corpus = json.loads(Path(__file__).with_name("cases.json").read_text())
    references = []
    for prompt in corpus:
        schema = schema_for(prompt)
        start = time.perf_counter()
        # The pinned facade's cache fingerprint sorts label mappings and can
        # reuse a schema with a different label order. Bypass that cache so
        # permutation tests really run a new input through the encoder.
        compiled = compile_schema(schema)
        scores = classifier.score(prompt["context"], compiled)
        batch = model.processor.collate_fn_inference(
            [(prompt["context"], compiled.build())], architecture="boundary"
        )
        ids = batch.input_ids[0].tolist()
        # Recover positions from the processor, never by scanning IDs that can
        # also occur in descriptions. One prompt row precedes the label rows.
        marker_positions = batch.schema_special_indices[0][0][1:]
        probabilities = [scores.probability("decision", o["id"]) for o in prompt["options"]]
        references.append({
            "prompt": prompt,
            "inputIDs": ids,
            "markerPositions": marker_positions,
            "logits": [scores.logit("decision", o["id"]) for o in prompt["options"]],
            "probabilities": probabilities,
            "seconds": time.perf_counter() - start,
        })
        print(json.dumps({"id": prompt["id"], "probabilities": probabilities}), flush=True)
    (args.output / "reference.json").write_text(json.dumps(references, indent=2) + "\n")
    model.processor.tokenizer.save_pretrained(args.output)
    metadata = {
        "formatVersion": 1, "modelID": MODEL, "revision": REVISION,
        "sourceRevision": SOURCE, "sequenceLength": args.sequence_length,
        "padTokenID": model.processor.tokenizer.pad_token_id,
        "vocabularySize": model.encoder.config.vocab_size,
        "activation": "softmax", "temperature": 1.0,
        "weightBits": args.weight_bits,
        "computePrecision": "float32",
    }
    (args.output / "gliner.json").write_text(json.dumps(metadata, indent=2) + "\n")
    if args.reference_only:
        return

    import coremltools as ct
    import numpy as np

    class ClassificationPath(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.encoder = model.encoder
            self.classifier = model.classifier

        def forward(self, input_ids, attention_mask):
            states = self.encoder(input_ids=input_ids, attention_mask=attention_mask).last_hidden_state
            return self.classifier(states).squeeze(-1)

    wrapper = ClassificationPath().eval()
    sample = references[0]["inputIDs"]
    if len(sample) > args.sequence_length:
        raise ValueError("sample does not fit exported sequence length")
    ids = torch.tensor([sample + [metadata["padTokenID"]] * (args.sequence_length - len(sample))])
    mask = torch.tensor([[1] * len(sample) + [0] * (args.sequence_length - len(sample))])
    # coremltools 9 misinfers the dtype inside Transformers' scripted sqrt
    # helper. The head dimension and scale factor are fixed architecture
    # constants, so emit their exact floating-point constant during tracing.
    import transformers.models.deberta_v2.modeling_deberta_v2 as deberta
    original_scale = deberta.scaled_size_sqrt
    original_rpos = deberta.build_rpos
    def export_scale(query, factor):
        return query.new_tensor(math.sqrt(int(query.shape[-1]) * factor))
    with torch.inference_mode():
        expected = wrapper(ids, mask)
        try:
            deberta.scaled_size_sqrt = export_scale
            # This export contains self-attention only: query/key lengths are
            # always the same. Resolve that scripted shape branch before MIL.
            deberta.build_rpos = lambda query, key, relative, buckets, maximum: relative
            traced = torch.jit.trace(wrapper, (ids, mask))
        finally:
            deberta.scaled_size_sqrt = original_scale
            deberta.build_rpos = original_rpos
        torch.testing.assert_close(traced(ids, mask), expected)
    exported = ct.convert(
        traced, inputs=[
            ct.TensorType(name="input_ids", shape=ids.shape, dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=mask.shape, dtype=np.int32),
        ], outputs=[ct.TensorType(name="logits", dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.CPU_ONLY,
    )
    exported.author = "SwiftDecision GLiNER pilot; model by Fastino AI"
    exported.license = "Apache-2.0"
    exported.short_description = f"{MODEL}@{REVISION}: encoder and classification head only"
    if args.weight_bits == 8:
        from coremltools.optimize.coreml import (
            OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights,
        )
        exported = linear_quantize_weights(exported, config=OptimizationConfig(
            global_config=OpLinearQuantizerConfig(
                mode="linear_symmetric", dtype=np.int8, weight_threshold=512,
            )
        ))
    exported.save(str(args.output / "GLiNERSmall.mlpackage"))
    # Record the compressed model separately from the uncompressed Torch
    # reference. Quantization drift is measured, never hidden by a loose
    # Swift/Python runtime-parity tolerance.
    deltas = []
    agreement = 0
    for reference in references:
        sample = reference["inputIDs"]
        if len(sample) > args.sequence_length:
            raise ValueError(f"case {reference['prompt']['id']} exceeds sequence length")
        result = exported.predict({
            "input_ids": np.array([sample + [metadata["padTokenID"]] * (args.sequence_length - len(sample))], dtype=np.int32),
            "attention_mask": np.array([[1] * len(sample) + [0] * (args.sequence_length - len(sample))], dtype=np.int32),
        })["logits"][0, reference["markerPositions"]].astype(np.float64)
        if not np.isfinite(result).all():
            raise ValueError("nonfinite Core ML logits")
        weights = np.exp(result - result.max())
        probabilities = (weights / weights.sum()).tolist()
        reference["coreMLProbabilities"] = probabilities
        deltas.extend(abs(a - b) for a, b in zip(probabilities, reference["probabilities"], strict=True))
        agreement += int(np.argmax(probabilities) == np.argmax(reference["probabilities"]))
    (args.output / "reference.json").write_text(json.dumps(references, indent=2) + "\n")
    (args.output / "measurement.json").write_text(json.dumps({
        "model": MODEL, "revision": REVISION, "weightBits": args.weight_bits,
        "maxProbabilityDeltaFromTorch": max(deltas),
        "winnerAgreementWithTorch": agreement, "caseCount": len(references),
        "packageBytes": sum(p.stat().st_size for p in (args.output / "GLiNERSmall.mlpackage").rglob("*") if p.is_file()),
    }, indent=2) + "\n")
    # Preserve distribution notices even when the checkpoint has only a model-card license tag.
    for source in Path(__file__).with_name("licenses").iterdir():
        if source.is_file():
            shutil.copy2(source, args.output / source.name)
    print(json.dumps({"exportSeconds": time.perf_counter() - started}), flush=True)


if __name__ == "__main__":
    main()
