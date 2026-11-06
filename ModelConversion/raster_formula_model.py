#!/usr/bin/env python3
"""Raster-only FormulaRasterV1 encoder/decoder and canonical PGM renderer."""
from __future__ import annotations

import math
from pathlib import Path

import torch
from torch import Tensor, nn

from formula_whole_input import FormulaInput, model_features

RASTER_SIZE = 512
MARGIN = 32.0
PGM_HEADER = b"P5\n512 512\n255\n"


def rasterize_formula_v1(formula: FormulaInput) -> bytes:
    """Produce the exact FormulaRasterV1 PGM bytes; invalid geometry is fatal."""
    traces = model_features(formula)
    points = [point for trace in traces for point in trace]
    if not points:
        raise ValueError("FormulaRasterV1 requires at least one point")
    min_x, max_x = min(x for x, _ in points), max(x for x, _ in points)
    min_y, max_y = min(y for _, y in points), max(y for _, y in points)
    if not (math.isfinite(min_x) and math.isfinite(max_x) and math.isfinite(min_y) and math.isfinite(max_y)) or max_x <= min_x or max_y <= min_y:
        raise ValueError("FormulaRasterV1 requires finite non-degenerate x and y ranges")
    scale = min((RASTER_SIZE - 2.0 * MARGIN) / (max_x - min_x), (RASTER_SIZE - 2.0 * MARGIN) / (max_y - min_y))
    pixels = bytearray([255]) * (RASTER_SIZE * RASTER_SIZE)
    def draw(ax: float, ay: float, bx: float, by: float) -> None:
        lo_x, hi_x = max(0, math.floor(min(ax, bx) - 3)), min(RASTER_SIZE - 1, math.ceil(max(ax, bx) + 3))
        lo_y, hi_y = max(0, math.floor(min(ay, by) - 3)), min(RASTER_SIZE - 1, math.ceil(max(ay, by) + 3))
        dx, dy = bx - ax, by - ay
        norm = dx * dx + dy * dy
        for y in range(lo_y, hi_y + 1):
            for x in range(lo_x, hi_x + 1):
                px, py = x + 0.5, y + 0.5
                t = 0.0 if norm == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / norm))
                distance = math.hypot(px - (ax + t * dx), py - (ay + t * dy))
                coverage = max(0.0, min(1.0, 2.5 - distance))
                value = int(round(255.0 * (1.0 - coverage)))
                index = y * RASTER_SIZE + x
                if value < pixels[index]:
                    pixels[index] = value
    for trace in traces:
        converted = [(MARGIN + (x - min_x) * scale, MARGIN + (y - min_y) * scale) for x, y in trace]
        for (ax, ay), (bx, by) in zip(converted, converted[1:]):
            draw(ax, ay, bx, by)
    return PGM_HEADER + bytes(pixels)


def raster_tensor(formula: FormulaInput) -> Tensor:
    pgm = rasterize_formula_v1(formula)
    pixels = torch.tensor(list(pgm[len(PGM_HEADER):]), dtype=torch.float32)
    return (255.0 - pixels).reshape(1, RASTER_SIZE, RASTER_SIZE).div_(255.0)


class RasterFormulaModel(nn.Module):
    """Direct spatial-raster-to-LaTeX model; no stroke or symbol input exists."""
    def __init__(self, vocab_size: int, d_model: int = 192) -> None:
        super().__init__()
        self.encoder = nn.Sequential(
            nn.Conv2d(1, 32, 5, stride=2, padding=2), nn.GELU(),
            nn.Conv2d(32, 64, 3, stride=2, padding=1), nn.GELU(),
            nn.Conv2d(64, 128, 3, stride=2, padding=1), nn.GELU(),
            nn.Conv2d(128, d_model, 3, stride=2, padding=1), nn.GELU(),
            nn.AdaptiveAvgPool2d((8, 8)),
        )
        self.image_position = nn.Parameter(torch.zeros(1, 64, d_model))
        self.embedding = nn.Embedding(vocab_size, d_model)
        self.target_position = nn.Embedding(128, d_model)
        layer = nn.TransformerDecoderLayer(d_model=d_model, nhead=4, dim_feedforward=d_model * 4, dropout=0.0, batch_first=True, activation="gelu")
        self.decoder = nn.TransformerDecoder(layer, num_layers=2)
        self.output = nn.Linear(d_model, vocab_size)

    def forward(self, raster: Tensor, tokens: Tensor) -> Tensor:
        if tokens.shape[1] > 128:
            raise ValueError(f"target length {tokens.shape[1]} exceeds fixed decoder limit 128")
        memory = self.encoder(raster).flatten(2).transpose(1, 2) + self.image_position
        positions = torch.arange(tokens.shape[1], device=tokens.device)
        embedded = self.embedding(tokens) + self.target_position(positions).unsqueeze(0)
        causal = torch.triu(torch.ones(tokens.shape[1], tokens.shape[1], device=tokens.device, dtype=torch.bool), diagonal=1)
        decoded = self.decoder(embedded, memory, tgt_mask=causal)
        return self.output(decoded)
