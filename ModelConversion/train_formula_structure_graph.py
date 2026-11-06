#!/usr/bin/env python3
"""Single MPS-only graph for spatial, instance, relation, and formula teachers.

This entrypoint has no CPU execution path.  A raw Metal probe runs before a
graph is constructed or an optimizer is allocated, so a zero-device process
cannot accidentally execute a partial CPU graph.
"""
from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass
from typing import Any

import torch
from torch import Tensor, nn

from formula_structure_decoder import FormulaStructureDecoder, assert_decoder_condition, teacher_forcing_loss
from instance_separator import InstanceSeparator, RASTER_SIZE
from instance_structure_relation import InstanceRelationHead, RELATION_TYPES


@dataclass(frozen=True)
class MetalProbe:
    default_device: bool
    device_count: int
    stderr: str = ""


def raw_metal_probe() -> MetalProbe:
    source = "import Metal; print(MTLCreateSystemDefaultDevice() == nil ? \"nil\" : \"device\"); print(MTLCopyAllDevices().count)"
    environment = {**os.environ, "CLANG_MODULE_CACHE_PATH": "/private/tmp/arcane-raw-metal-module-cache", "SWIFT_MODULE_CACHE_PATH": "/private/tmp/arcane-raw-metal-module-cache"}
    completed = subprocess.run(["swift", "-e", source], text=True, capture_output=True, check=False, env=environment)
    lines = completed.stdout.strip().splitlines()
    if completed.returncode != 0 or len(lines) != 2 or lines[0] not in {"nil", "device"}:
        raise RuntimeError(f"raw Metal probe failed: exit={completed.returncode}, stdout={completed.stdout!r}, stderr={completed.stderr!r}")
    try:
        count = int(lines[1])
    except ValueError as error:
        raise RuntimeError(f"raw Metal probe emitted a non-integer device count: {completed.stdout!r}") from error
    return MetalProbe(lines[0] == "device", count, completed.stderr.strip())


def require_mps(probe: MetalProbe | None = None) -> None:
    measured = raw_metal_probe() if probe is None else probe
    if not measured.default_device or measured.device_count <= 0:
        raise RuntimeError(f"MPS graph aborted before forward: raw Metal device visibility is default={measured.default_device}, count={measured.device_count}")
    if not torch.backends.mps.is_available():
        raise RuntimeError("MPS graph aborted before forward: PyTorch MPS is unavailable after a non-zero raw Metal probe")


class SpatialFormulaEncoder(nn.Module):
    """FormulaRasterV1 512-space encoder retaining the 128x128 spatial map."""
    def __init__(self) -> None:
        super().__init__()
        self.layers = nn.Sequential(nn.Conv2d(1, 64, 5, 2, 2), nn.GELU(), nn.Conv2d(64, 128, 3, 2, 1), nn.GELU())

    def forward(self, raster: Tensor) -> Tensor:
        if raster.device.type != "mps":
            raise RuntimeError("SpatialFormulaEncoder optimization requires MPS")
        if raster.shape[1:] != (1, RASTER_SIZE, RASTER_SIZE):
            raise ValueError("spatial encoder requires FormulaRasterV1 [B,1,512,512]")
        result = self.layers(raster)
        if result.shape[1:] != (128, 128, 128):
            raise ValueError("spatial encoder failed its [B,128,128,128] contract")
        return result


def assert_graph_batch(batch: dict[str, Any]) -> None:
    required = {"sampleIds", "latexIds", "visualIds", "relationTarget", "relationMask", "raster", "instanceRaster", "instanceMask", "instanceSampleIds", "relationMaskInstances"}
    missing = required.difference(batch)
    if missing:
        raise ValueError(f"graph batch missing {sorted(missing)}")
    sample_ids = batch["sampleIds"]; raster = batch["raster"]; instances = batch["instanceRaster"]; active = batch["instanceMask"]
    if not isinstance(sample_ids, list) or raster.shape != (len(sample_ids), 1, RASTER_SIZE, RASTER_SIZE):
        raise ValueError("formula raster must be one FormulaRasterV1 tensor per decoder sampleId")
    if instances.ndim != 5 or instances.shape[:2] != active.shape or instances.shape[2:] != (1, RASTER_SIZE, RASTER_SIZE):
        raise ValueError("instance raster requires [B,N,1,512,512] and [B,N] active mask")
    if len(batch["instanceSampleIds"]) != len(sample_ids):
        raise ValueError("instance sampleId rows must equal decoder sampleId rows")
    for formula_index, sample_id in enumerate(sample_ids):
        ids = batch["instanceSampleIds"][formula_index]
        if len(ids) != active.shape[1]:
            raise ValueError("instance sampleId count does not equal instance axis")
        for instance_index, is_active in enumerate(active[formula_index].tolist()):
            if is_active and ids[instance_index] != sample_id:
                raise ValueError(f"graph sampleId mismatch: formula={sample_id!r}, instance={ids[instance_index]!r}")
            if not is_active and ids[instance_index] is not None:
                raise ValueError("masked graph instance must not carry a sampleId")
    if batch["relationMaskInstances"].shape != (len(sample_ids), active.shape[1], active.shape[1]):
        raise ValueError("instance relation mask shape mismatch")


class FormulaStructureTrainingGraph(nn.Module):
    """The only trainable path: spatial encoder + separator + relation + decoder."""
    def __init__(self, latex_vocab: int, visual_vocab: int) -> None:
        super().__init__()
        self.spatial_encoder = SpatialFormulaEncoder()
        self.separator = InstanceSeparator()
        self.relation_head = InstanceRelationHead()
        self.decoder = FormulaStructureDecoder(latex_vocab, visual_vocab)

    def forward(self, batch: dict[str, Any]) -> dict[str, Tensor]:
        assert_graph_batch(batch)
        if batch["raster"].device.type != "mps":
            raise RuntimeError("FormulaStructureTrainingGraph optimization requires MPS")
        b, n = batch["instanceMask"].shape
        spatial = self.spatial_encoder(batch["raster"])
        flat = batch["instanceRaster"].reshape(b * n, 1, RASTER_SIZE, RASTER_SIZE)
        separated = self.separator(flat)
        embeddings = separated["embedding"].reshape(b, n, 128)
        relation_logits = torch.zeros((b, n, n, len(RELATION_TYPES)), device=spatial.device)
        for index in range(b):
            active_indices = torch.nonzero(batch["instanceMask"][index], as_tuple=False).flatten()
            if active_indices.numel() < 2:
                continue
            pairs = torch.cartesian_prod(active_indices, active_indices)
            pairs = pairs[pairs[:, 0] != pairs[:, 1]]
            relation_logits[index, pairs[:, 0], pairs[:, 1]] = self.relation_head(embeddings[index], pairs)
        assert_decoder_condition(batch, spatial, embeddings, batch["instanceMask"], batch["instanceSampleIds"], relation_logits, batch["relationMaskInstances"])
        latex_logits, visual_logits, structural_logits = self.decoder(spatial, embeddings, batch["instanceMask"], relation_logits, batch["relationMaskInstances"], batch["latexIds"][:, :-1], batch["visualIds"][:, :-1])
        return {"latexLogits": latex_logits, "visualLogits": visual_logits, "structuralLogits": structural_logits, "separator": separated}


def mps_training_step(graph: FormulaStructureTrainingGraph, batch: dict[str, Any], latex_pad_id: int, visual_pad_id: int) -> dict[str, float]:
    """Run one real optimizer step only after raw Metal and PyTorch MPS agree."""
    require_mps()
    assert_graph_batch(batch)
    graph = graph.to("mps")
    device_batch: dict[str, Any] = {key: (value.to("mps") if isinstance(value, Tensor) else value) for key, value in batch.items()}
    output = graph(device_batch)
    losses = teacher_forcing_loss(output["latexLogits"], output["visualLogits"], output["structuralLogits"], device_batch, latex_pad_id, visual_pad_id)
    optimizer = torch.optim.AdamW(graph.parameters(), lr=3e-4)
    optimizer.zero_grad(set_to_none=True); losses["total"].backward(); optimizer.step()
    return {key: float(value.detach().cpu()) for key, value in losses.items()}
