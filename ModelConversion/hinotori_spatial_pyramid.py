"""Spatial-pyramid, angular-margin network for isolated Hinotori symbols."""
from __future__ import annotations

import math

import torch
from torch import Tensor, nn
from torch.nn import functional as F

from hinotori_raster_classifier import CLASS_COUNT, RASTER_SIZE, ConvBlock


class HinotoriSpatialPyramidAngularMargin(nn.Module):
    """229-way glyph encoder with local-layout pooling and ArcFace training.

    The embedding retains 1x1, 2x2, and 4x4 spatial evidence. A normalized
    class-weight vector acts as each training class prototype. Angular margin
    is applied only to the labeled training logit; inference uses cosine logits.
    All operators are convolution, pooling, linear, normalization, and element
    arithmetic intended to remain convertible to Core ML/ANE.
    """

    def __init__(self, embedding_dimension: int = 128, scale: float = 32.0, margin: float = 0.30):
        super().__init__()
        if embedding_dimension < 16 or scale <= 0 or not 0.0 < margin < math.pi / 2:
            raise ValueError("embedding dimension, ArcFace scale, and angular margin are invalid")
        self.embedding_dimension = embedding_dimension
        self.scale = float(scale)
        self.margin = float(margin)
        self.features = nn.Sequential(
            nn.Conv2d(1, 32, 3, padding=1, bias=False),
            nn.BatchNorm2d(32),
            nn.SiLU(),
            nn.MaxPool2d(2),
            ConvBlock(32, 48),
            ConvBlock(48, 64, stride=2),
            ConvBlock(64, 96, stride=2),
            ConvBlock(96, 128, stride=2),
        )
        self.spatial_projection = nn.Sequential(
            nn.Linear(128 * (1 + 4 + 16), 256),
            nn.SiLU(),
            nn.Dropout(0.15),
            nn.Linear(256, embedding_dimension),
        )
        self.class_prototypes = nn.Parameter(torch.empty(CLASS_COUNT, embedding_dimension))
        nn.init.xavier_uniform_(self.class_prototypes)

    def encode(self, images: Tensor) -> Tensor:
        if images.ndim != 4 or images.shape[1:] != (1, RASTER_SIZE, RASTER_SIZE):
            raise ValueError(f"images must have shape [batch,1,{RASTER_SIZE},{RASTER_SIZE}]")
        if not torch.isfinite(images).all() or (images < 0).any() or (images > 1).any():
            raise ValueError("ink images must be finite and in [0,1]")
        feature_map = self.features(images)
        pyramids = [F.adaptive_avg_pool2d(feature_map, size).flatten(1) for size in (1, 2, 4)]
        return F.normalize(self.spatial_projection(torch.cat(pyramids, dim=1)), p=2, dim=1)

    def cosine_logits(self, embeddings: Tensor) -> Tensor:
        return F.linear(embeddings, F.normalize(self.class_prototypes, p=2, dim=1)) * self.scale

    def training_logits(self, embeddings: Tensor, labels: Tensor) -> Tensor:
        if labels.shape != (embeddings.shape[0],) or labels.dtype != torch.int64:
            raise ValueError("ArcFace labels must be int64 and match the embedding batch")
        if (labels < 0).any() or (labels >= CLASS_COUNT).any():
            raise ValueError("ArcFace labels must be valid Hinotori class indices")
        cosine = F.linear(embeddings, F.normalize(self.class_prototypes, p=2, dim=1)).clamp(-1.0 + 1e-7, 1.0 - 1e-7)
        sine = torch.sqrt((1.0 - cosine.square()).clamp_min(1e-7))
        cos_margin = math.cos(self.margin)
        sin_margin = math.sin(self.margin)
        target_cosine = cosine * cos_margin - sine * sin_margin
        threshold = math.cos(math.pi - self.margin)
        correction = math.sin(math.pi - self.margin) * self.margin
        target_cosine = torch.where(cosine > threshold, target_cosine, cosine - correction)
        one_hot = F.one_hot(labels, CLASS_COUNT).to(dtype=cosine.dtype)
        return (one_hot * target_cosine + (1.0 - one_hot) * cosine) * self.scale

    def forward(self, images: Tensor) -> tuple[Tensor, Tensor]:
        embedding = self.encode(images)
        return self.cosine_logits(embedding), embedding
