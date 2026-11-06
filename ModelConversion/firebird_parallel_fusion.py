"""Parallel image-layout and online-trajectory fusion model for isolated symbols."""
from __future__ import annotations

import torch
from torch import Tensor, nn
from torch.nn import functional as F

from firebird_online_trajectory import FirebirdOnlineTrajectoryEncoder
from hinotori_raster_classifier import CLASS_COUNT, EMBEDDING_DIMENSION, RASTER_SIZE, ConvBlock


class FirebirdParallelRasterTrajectoryFusion(nn.Module):
    """Jointly classify from parallel raster-layout and ordered-ink branches.

    The raster branch reads global two-dimensional glyph shape. The trajectory
    branch reads ordered XY motion, per-stroke direction, and stroke sequence.
    Their embeddings are fused before the 229-way decision; neither branch is a
    post-hoc fallback. This candidate requires end-to-end validation and ANE
    measurement before adoption.
    """

    def __init__(self, embedding_dimension: int = EMBEDDING_DIMENSION):
        super().__init__()
        if embedding_dimension < 16:
            raise ValueError("embedding dimension is too small")
        self.raster_features = nn.Sequential(
            nn.Conv2d(1, 32, 3, padding=1, bias=False), nn.BatchNorm2d(32), nn.SiLU(), nn.MaxPool2d(2),
            ConvBlock(32, 48), ConvBlock(48, 64, stride=2),
            ConvBlock(64, 96, stride=2), ConvBlock(96, 128, stride=2),
        )
        self.raster_projection = nn.Sequential(nn.Linear(256, 128), nn.LayerNorm(128), nn.GELU())
        self.trajectory_encoder = FirebirdOnlineTrajectoryEncoder(embedding_dimension=128)
        self.raster_classifier = nn.Linear(128, CLASS_COUNT)
        self.trajectory_classifier = nn.Linear(128, CLASS_COUNT)
        self.fusion = nn.Sequential(
            nn.Linear(256, 256), nn.LayerNorm(256), nn.GELU(), nn.Dropout(0.20),
            nn.Linear(256, embedding_dimension), nn.LayerNorm(embedding_dimension),
        )
        self.classifier = nn.Linear(embedding_dimension, CLASS_COUNT)

    def encode_branches(self, images: Tensor, points: Tensor, stroke_padding: Tensor) -> tuple[Tensor, Tensor]:
        if images.ndim != 4 or images.shape[1:] != (1, RASTER_SIZE, RASTER_SIZE):
            raise ValueError(f"images must have shape [batch,1,{RASTER_SIZE},{RASTER_SIZE}]")
        if points.shape[0] != images.shape[0] or stroke_padding.shape != points.shape[:2]:
            raise ValueError("image, trajectory, and stroke mask batches do not align")
        raster_map = self.raster_features(images)
        raster_stats = torch.cat((
            F.adaptive_avg_pool2d(raster_map, 1).flatten(1),
            F.adaptive_max_pool2d(raster_map, 1).flatten(1),
        ), dim=1)
        raster_embedding = self.raster_projection(raster_stats)
        trajectory_embedding = self.trajectory_encoder(points, stroke_padding)
        return raster_embedding, trajectory_embedding

    def encode(self, images: Tensor, points: Tensor, stroke_padding: Tensor) -> Tensor:
        raster_embedding, trajectory_embedding = self.encode_branches(images, points, stroke_padding)
        return F.normalize(self.fusion(torch.cat((raster_embedding, trajectory_embedding), dim=1)), p=2, dim=1)

    def forward(self, images: Tensor, points: Tensor, stroke_padding: Tensor):
        raster_embedding, trajectory_embedding = self.encode_branches(images, points, stroke_padding)
        embedding = F.normalize(self.fusion(torch.cat((raster_embedding, trajectory_embedding), dim=1)), p=2, dim=1)
        return (
            self.classifier(embedding), embedding,
            self.raster_classifier(raster_embedding),
            self.trajectory_classifier(trajectory_embedding),
        )
