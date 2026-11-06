"""Order-invariant raster classifier for isolated Hinotori symbols.

Directly annotated stroke groups are rendered as a single binary ink image.
Taking the union of strokes makes rendering invariant to stroke order; drawing
each segment as an undirected line makes it invariant to direction within a
stroke. Spatial geometry within the symbol is retained in the raster.
"""
from __future__ import annotations

import torch
from torch import Tensor, nn
from torch.nn import functional as F


CLASS_COUNT = 229
RASTER_SIZE = 64
EMBEDDING_DIMENSION = 128


def rasterize_group(points: Tensor, size: int = RASTER_SIZE) -> Tensor:
    """Rasterize canonical [stroke,point,2] ink as a one-channel image.

    Canonical coordinates are isotropically scaled to a unit box and centered
    at zero by ``canonical_group_tensor``. No stroke/time index is encoded.
    """
    if points.ndim != 3 or points.shape[0] < 1 or points.shape[1] < 1 or points.shape[2] != 2:
        raise ValueError("points must be nonempty [stroke,point,2]")
    if size < 16:
        raise ValueError("raster size must be at least 16")
    if not torch.isfinite(points).all():
        raise ValueError("points contain non-finite coordinates")
    if (points.abs() > 0.5001).any():
        raise ValueError("points are outside the canonical [-0.5,0.5] coordinate range")

    # Preserve aspect ratio and leave a one-pixel safety margin around the box.
    xy = ((points.detach().cpu() + 0.5) * (size - 3) + 1).round().to(torch.int64)
    canvas = torch.zeros((1, size, size), dtype=torch.float32)
    for stroke in xy:
        if stroke.shape[0] == 1:
            x, y = stroke[0].tolist()
            canvas[0, y, x] = 1.0
            continue
        for start, end in zip(stroke[:-1], stroke[1:]):
            x0, y0 = start.tolist()
            x1, y1 = end.tolist()
            (x0, y0), (x1, y1) = sorted(((x0, y0), (x1, y1)))
            steps = max(abs(x1 - x0), abs(y1 - y0), 1)
            for step in range(steps + 1):
                t = step / steps
                x = round(x0 + (x1 - x0) * t)
                y = round(y0 + (y1 - y0) * t)
                canvas[0, y, x] = 1.0
    # InkML provides centerline coordinates but no reliable pen width. A fixed
    # 3x3 dilation makes raster coverage stable without depending on stroke order.
    return F.max_pool2d(canvas.unsqueeze(0), kernel_size=3, stride=1, padding=1)[0]


class ConvBlock(nn.Module):
    def __init__(self, in_channels: int, out_channels: int, stride: int = 1):
        super().__init__()
        self.conv1 = nn.Conv2d(in_channels, out_channels, 3, stride=stride, padding=1, bias=False)
        self.norm1 = nn.BatchNorm2d(out_channels)
        self.conv2 = nn.Conv2d(out_channels, out_channels, 3, padding=1, bias=False)
        self.norm2 = nn.BatchNorm2d(out_channels)
        self.skip = (
            nn.Identity()
            if stride == 1 and in_channels == out_channels
            else nn.Sequential(nn.Conv2d(in_channels, out_channels, 1, stride=stride, bias=False), nn.BatchNorm2d(out_channels))
        )

    def forward(self, x: Tensor) -> Tensor:
        residual = self.skip(x)
        x = F.silu(self.norm1(self.conv1(x)))
        x = self.norm2(self.conv2(x))
        return F.silu(x + residual)


class HinotoriRasterClassifier(nn.Module):
    """229-way exact classifier plus a normalized visual embedding."""

    def __init__(self, class_count: int = CLASS_COUNT, embedding_dimension: int = EMBEDDING_DIMENSION):
        super().__init__()
        if class_count != CLASS_COUNT or embedding_dimension < 1:
            raise ValueError("Hinotori requires exactly 229 classes and a positive embedding dimension")
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
        self.embedding = nn.Sequential(
            nn.Linear(256, 192),
            nn.SiLU(),
            nn.Dropout(0.15),
            nn.Linear(192, embedding_dimension),
        )
        self.classifier = nn.Linear(embedding_dimension, CLASS_COUNT)

    def forward(self, images: Tensor) -> tuple[Tensor, Tensor]:
        if images.ndim != 4 or images.shape[1:] != (1, RASTER_SIZE, RASTER_SIZE):
            raise ValueError(f"images must have shape [batch,1,{RASTER_SIZE},{RASTER_SIZE}]")
        feature_map = self.features(images)
        pooled = torch.cat((F.adaptive_avg_pool2d(feature_map, 1).flatten(1), F.adaptive_max_pool2d(feature_map, 1).flatten(1)), dim=1)
        embedding = F.normalize(self.embedding(pooled), p=2, dim=1)
        return self.classifier(embedding), embedding


class SqueezeExcitation(nn.Module):
    """Channel recalibration with a fixed, Core ML friendly reduction path."""

    def __init__(self, channels: int, reduction: int = 8):
        super().__init__()
        hidden = max(channels // reduction, 4)
        self.reduce = nn.Linear(channels, hidden)
        self.expand = nn.Linear(hidden, channels)

    def forward(self, feature_map: Tensor) -> Tensor:
        descriptor = F.adaptive_avg_pool2d(feature_map, 1).flatten(1)
        gate = torch.sigmoid(self.expand(F.relu(self.reduce(descriptor))))
        return feature_map * gate[:, :, None, None]


class SEConvBlock(nn.Module):
    """Residual convolution block with input-conditioned channel weighting."""

    def __init__(self, in_channels: int, out_channels: int, stride: int = 1):
        super().__init__()
        self.conv1 = nn.Conv2d(in_channels, out_channels, 3, stride=stride, padding=1, bias=False)
        self.norm1 = nn.BatchNorm2d(out_channels)
        self.conv2 = nn.Conv2d(out_channels, out_channels, 3, padding=1, bias=False)
        self.norm2 = nn.BatchNorm2d(out_channels)
        self.recalibrate = SqueezeExcitation(out_channels)
        self.skip = (
            nn.Identity()
            if stride == 1 and in_channels == out_channels
            else nn.Sequential(nn.Conv2d(in_channels, out_channels, 1, stride=stride, bias=False), nn.BatchNorm2d(out_channels))
        )

    def forward(self, x: Tensor) -> Tensor:
        residual = self.skip(x)
        x = F.silu(self.norm1(self.conv1(x)))
        x = self.norm2(self.conv2(x))
        return F.silu(self.recalibrate(x) + residual)


class HinotoriSEClassifier(nn.Module):
    """229-way raster classifier with residual and channel-attention features."""

    def __init__(self, class_count: int = CLASS_COUNT, embedding_dimension: int = EMBEDDING_DIMENSION):
        super().__init__()
        if class_count != CLASS_COUNT or embedding_dimension < 1:
            raise ValueError("Hinotori requires exactly 229 classes and a positive embedding dimension")
        self.features = nn.Sequential(
            nn.Conv2d(1, 32, 3, padding=1, bias=False), nn.BatchNorm2d(32), nn.SiLU(), nn.MaxPool2d(2),
            SEConvBlock(32, 48), SEConvBlock(48, 64, stride=2),
            SEConvBlock(64, 96, stride=2), SEConvBlock(96, 128, stride=2),
        )
        self.embedding = nn.Sequential(
            nn.Linear(256, 192), nn.SiLU(), nn.Dropout(0.15), nn.Linear(192, embedding_dimension),
        )
        self.classifier = nn.Linear(embedding_dimension, CLASS_COUNT)

    def forward(self, images: Tensor) -> tuple[Tensor, Tensor]:
        if images.ndim != 4 or images.shape[1:] != (1, RASTER_SIZE, RASTER_SIZE):
            raise ValueError(f"images must have shape [batch,1,{RASTER_SIZE},{RASTER_SIZE}]")
        feature_map = self.features(images)
        pooled = torch.cat((F.adaptive_avg_pool2d(feature_map, 1).flatten(1), F.adaptive_max_pool2d(feature_map, 1).flatten(1)), dim=1)
        embedding = F.normalize(self.embedding(pooled), p=2, dim=1)
        return self.classifier(embedding), embedding


class TrajectoryConvBlock(nn.Module):
    """Residual 1-D trajectory block represented with ANE-friendly Conv2d ops."""

    def __init__(self, in_channels: int, out_channels: int, stride: int = 1):
        super().__init__()
        self.conv1 = nn.Conv2d(in_channels, out_channels, (1, 5), stride=(1, stride), padding=(0, 2), bias=False)
        self.norm1 = nn.BatchNorm2d(out_channels)
        self.conv2 = nn.Conv2d(out_channels, out_channels, (1, 3), padding=(0, 1), bias=False)
        self.norm2 = nn.BatchNorm2d(out_channels)
        self.skip = (
            nn.Identity()
            if stride == 1 and in_channels == out_channels
            else nn.Sequential(nn.Conv2d(in_channels, out_channels, 1, stride=(1, stride), bias=False), nn.BatchNorm2d(out_channels))
        )

    def forward(self, x: Tensor) -> Tensor:
        residual = self.skip(x)
        x = F.relu(self.norm1(self.conv1(x)))
        x = self.norm2(self.conv2(x))
        return F.relu(x + residual)


class HinotoriStrokeSetClassifier(nn.Module):
    """Order- and stroke-direction-invariant classifier for direct symbols.

    A global ink raster is fused with a shared trajectory encoder. The caller
    supplies each stroke and its reversed point sequence; averaging their
    embeddings makes stroke direction irrelevant. Masked symmetric pooling
    makes the symbol embedding independent of the order of its strokes.
    """

    def __init__(self, class_count: int = CLASS_COUNT, embedding_dimension: int = EMBEDDING_DIMENSION):
        super().__init__()
        if class_count != CLASS_COUNT or embedding_dimension < 1:
            raise ValueError("Hinotori requires exactly 229 classes and a positive embedding dimension")
        self.raster_features = nn.Sequential(
            nn.Conv2d(1, 32, 3, padding=1, bias=False), nn.BatchNorm2d(32), nn.SiLU(), nn.MaxPool2d(2),
            ConvBlock(32, 48), ConvBlock(48, 64, stride=2),
            ConvBlock(64, 96, stride=2), ConvBlock(96, 128, stride=2),
        )
        self.raster_projection = nn.Sequential(nn.Linear(256, 128), nn.ReLU())
        self.trajectory_features = nn.Sequential(
            nn.Conv2d(4, 32, (1, 5), stride=(1, 2), padding=(0, 2), bias=False),
            nn.BatchNorm2d(32), nn.ReLU(),
            TrajectoryConvBlock(32, 48, stride=2),
            TrajectoryConvBlock(48, 64, stride=2),
        )
        self.stroke_projection = nn.Sequential(nn.Linear(128, 128), nn.ReLU())
        self.embedding = nn.Sequential(
            nn.Linear(385, 256), nn.SiLU(), nn.Dropout(0.15), nn.Linear(256, embedding_dimension),
        )
        self.classifier = nn.Linear(embedding_dimension, CLASS_COUNT)

    def forward(
        self,
        ink_raster: Tensor,
        stroke_points: Tensor,
        reversed_stroke_points: Tensor,
        stroke_valid: Tensor,
    ) -> tuple[Tensor, Tensor]:
        if ink_raster.ndim != 4 or ink_raster.shape[1:] != (1, RASTER_SIZE, RASTER_SIZE):
            raise ValueError(f"ink_raster must have shape [batch,1,{RASTER_SIZE},{RASTER_SIZE}]")
        if stroke_points.ndim != 4 or stroke_points.shape[0] != ink_raster.shape[0] or stroke_points.shape[2:] != (128, 2):
            raise ValueError("stroke_points must have shape [batch,stroke,128,2]")
        if reversed_stroke_points.shape != stroke_points.shape or stroke_valid.shape != stroke_points.shape[:2]:
            raise ValueError("reversed strokes and validity mask must match stroke_points")
        if stroke_valid.dtype not in (torch.float32, torch.float16, torch.bool):
            raise ValueError("stroke_valid must be float32, float16, or bool")

        batch_size, stroke_count = stroke_points.shape[:2]
        if stroke_count < 1:
            raise ValueError("stroke-set input must contain at least one trajectory slot")

        raster_map = self.raster_features(ink_raster)
        raster_pooled = torch.cat((F.adaptive_avg_pool2d(raster_map, 1).flatten(1),
                                   F.adaptive_max_pool2d(raster_map, 1).flatten(1)), dim=1)
        raster_embedding = self.raster_projection(raster_pooled)

        both_directions = torch.cat((stroke_points, reversed_stroke_points), dim=0)
        deltas = torch.cat((both_directions[:, :, 1:] - both_directions[:, :, :-1],
                            torch.zeros_like(both_directions[:, :, :1])), dim=2)
        sequence_features = torch.cat((both_directions, deltas), dim=-1)
        flattened = sequence_features.reshape(2 * batch_size * stroke_count, 128, 4).permute(0, 2, 1).unsqueeze(2)
        trajectory_map = self.trajectory_features(flattened)
        trajectory_pooled = torch.cat((F.adaptive_avg_pool2d(trajectory_map, 1).flatten(1),
                                       F.adaptive_max_pool2d(trajectory_map, 1).flatten(1)), dim=1)
        encoded = self.stroke_projection(trajectory_pooled)
        encoded = encoded.reshape(2, batch_size, stroke_count, 128).mean(dim=0)

        valid = stroke_valid.to(dtype=encoded.dtype).unsqueeze(-1)
        counts = valid.sum(dim=1).clamp_min(1.0)
        stroke_mean = (encoded * valid).sum(dim=1) / counts
        stroke_max = torch.where(valid > 0, encoded, torch.zeros_like(encoded)).amax(dim=1)
        stroke_count_feature = torch.log1p(counts) / 3.0
        fused = torch.cat((raster_embedding, stroke_mean, stroke_max, stroke_count_feature), dim=1)
        embedding = F.normalize(self.embedding(fused), p=2, dim=1)
        return self.classifier(embedding), embedding


def ink_scale_space(images: Tensor) -> Tensor:
    """Build order-invariant fine, dilated, and local-density glyph fields."""
    if images.ndim != 4 or images.shape[1:] != (1, RASTER_SIZE, RASTER_SIZE):
        raise ValueError(f"images must have shape [batch,1,{RASTER_SIZE},{RASTER_SIZE}]")
    if not torch.isfinite(images).all() or (images < 0).any() or (images > 1).any():
        raise ValueError("ink rasters must be finite and in [0,1]")
    fine = images
    near = F.max_pool2d(images, kernel_size=3, stride=1, padding=1)
    middle = F.max_pool2d(images, kernel_size=7, stride=1, padding=3)
    density = F.avg_pool2d(images, kernel_size=9, stride=1, padding=4, count_include_pad=False)
    return torch.cat((fine, near, middle, density), dim=1)


class HinotoriScaleSpaceClassifier(nn.Module):
    """Multi-scale ink-field classifier for isolated handwritten symbols.

    A shared residual trunk encodes the fine-to-coarse ink fields. Four feature
    resolutions are pooled independently and combined with learned scale
    gates, preserving small marks while exposing larger glyph geometry.
    """

    def __init__(self, class_count: int = CLASS_COUNT, embedding_dimension: int = EMBEDDING_DIMENSION):
        super().__init__()
        if class_count != CLASS_COUNT or embedding_dimension < 1:
            raise ValueError("Hinotori requires exactly 229 classes and a positive embedding dimension")
        self.stem = nn.Sequential(nn.Conv2d(4, 32, 3, padding=1, bias=False), nn.BatchNorm2d(32), nn.ReLU())
        self.stage1 = ConvBlock(32, 48)
        self.down1 = ConvBlock(48, 64, stride=2)
        self.down2 = ConvBlock(64, 96, stride=2)
        self.down3 = ConvBlock(96, 128, stride=2)
        channels = (48, 64, 96, 128)
        self.scale_projections = nn.ModuleList(nn.Linear(channel * 2, 128) for channel in channels)
        self.scale_gate = nn.Sequential(nn.Linear(128 * 4, 128), nn.ReLU(), nn.Linear(128, 4))
        self.embedding = nn.Sequential(nn.Linear(128, 192), nn.ReLU(), nn.Dropout(0.10), nn.Linear(192, embedding_dimension))
        self.classifier = nn.Linear(embedding_dimension, CLASS_COUNT)

    def forward(self, images: Tensor) -> tuple[Tensor, Tensor]:
        fields = ink_scale_space(images)
        x = self.stem(fields)
        maps = []
        x = self.stage1(x); maps.append(x)
        x = self.down1(x); maps.append(x)
        x = self.down2(x); maps.append(x)
        x = self.down3(x); maps.append(x)
        scale_features = []
        for feature_map, projection in zip(maps, self.scale_projections):
            pooled = torch.cat((F.adaptive_avg_pool2d(feature_map, 1).flatten(1),
                                F.adaptive_max_pool2d(feature_map, 1).flatten(1)), dim=1)
            scale_features.append(F.relu(projection(pooled)))
        stacked = torch.stack(scale_features, dim=1)
        gate_logits = self.scale_gate(torch.cat(scale_features, dim=1))
        gates = torch.softmax(gate_logits, dim=1)
        fused = (stacked * gates.unsqueeze(-1)).sum(dim=1)
        embedding = F.normalize(self.embedding(fused), p=2, dim=1)
        return self.classifier(embedding), embedding


class DepthwiseSeparableBlock(nn.Module):
    def __init__(self, in_channels: int, out_channels: int, stride: int):
        super().__init__()
        self.depthwise = nn.Conv2d(in_channels, in_channels, 3, stride=stride, padding=1, groups=in_channels, bias=False)
        self.depthwise_norm = nn.BatchNorm2d(in_channels)
        self.pointwise = nn.Conv2d(in_channels, out_channels, 1, bias=False)
        self.pointwise_norm = nn.BatchNorm2d(out_channels)

    def forward(self, x: Tensor) -> Tensor:
        x = F.silu(self.depthwise_norm(self.depthwise(x)))
        return F.silu(self.pointwise_norm(self.pointwise(x)))


class HinotoriMobileRasterClassifier(nn.Module):
    """MobileNet-style depthwise CNN for isolated 229-symbol recognition."""

    def __init__(self, class_count: int = CLASS_COUNT, embedding_dimension: int = EMBEDDING_DIMENSION):
        super().__init__()
        if class_count != CLASS_COUNT or embedding_dimension < 1:
            raise ValueError("Hinotori requires exactly 229 classes and a positive embedding dimension")
        self.features = nn.Sequential(
            nn.Conv2d(1, 32, 3, stride=2, padding=1, bias=False),
            nn.BatchNorm2d(32),
            nn.SiLU(),
            DepthwiseSeparableBlock(32, 48, 1),
            DepthwiseSeparableBlock(48, 64, 2),
            DepthwiseSeparableBlock(64, 96, 2),
            DepthwiseSeparableBlock(96, 128, 2),
            DepthwiseSeparableBlock(128, 160, 2),
        )
        self.embedding = nn.Sequential(
            nn.Linear(320, 192),
            nn.SiLU(),
            nn.Dropout(0.15),
            nn.Linear(192, embedding_dimension),
        )
        self.classifier = nn.Linear(embedding_dimension, CLASS_COUNT)

    def forward(self, images: Tensor) -> tuple[Tensor, Tensor]:
        if images.ndim != 4 or images.shape[1:] != (1, RASTER_SIZE, RASTER_SIZE):
            raise ValueError(f"images must have shape [batch,1,{RASTER_SIZE},{RASTER_SIZE}]")
        feature_map = self.features(images)
        pooled = torch.cat((F.adaptive_avg_pool2d(feature_map, 1).flatten(1), F.adaptive_max_pool2d(feature_map, 1).flatten(1)), dim=1)
        embedding = F.normalize(self.embedding(pooled), p=2, dim=1)
        return self.classifier(embedding), embedding


def topk_and_macro_recall(logits: Tensor, targets: Tensor, topk: tuple[int, ...] = (1, 5)) -> dict[str, float]:
    """Return example-level Top-k and unweighted per-class recall."""
    if logits.ndim != 2 or logits.shape[1] != CLASS_COUNT or targets.shape != (logits.shape[0],):
        raise ValueError("logits/targets do not match the 229-class task")
    if logits.shape[0] == 0 or any(k < 1 or k > CLASS_COUNT for k in topk):
        raise ValueError("evaluation batch must be nonempty and top-k values valid")
    predictions = logits.topk(max(topk), dim=1).indices
    result = {f"top{k}": (predictions[:, :k] == targets[:, None]).any(1).float().mean().item() for k in topk}
    predicted = logits.argmax(1)
    recalls = []
    for class_index in targets.unique().tolist():
        mask = targets == class_index
        recalls.append((predicted[mask] == targets[mask]).float().mean())
    result["macroRecallObservedClasses"] = torch.stack(recalls).mean().item()
    return result


def direct_class_centroids(embeddings: Tensor, class_indices: Tensor) -> Tensor:
    """Build a normalized, direct-training-only centroid for each symbol class."""
    if embeddings.ndim != 2 or class_indices.shape != (embeddings.shape[0],):
        raise ValueError("embeddings and class_indices must align")
    if class_indices.dtype != torch.int64 or embeddings.shape[0] == 0:
        raise ValueError("class_indices must be int64 and the anchor bank nonempty")
    if not torch.isfinite(embeddings).all() or (class_indices < 0).any() or (class_indices >= CLASS_COUNT).any():
        raise ValueError("invalid embedding or class index")
    sums = torch.zeros((CLASS_COUNT, embeddings.shape[1]), dtype=embeddings.dtype, device=embeddings.device)
    sums.index_add_(0, class_indices, F.normalize(embeddings, p=2, dim=1))
    counts = torch.bincount(class_indices, minlength=CLASS_COUNT)
    if (counts == 0).any():
        missing = torch.where(counts == 0)[0].tolist()
        raise ValueError(f"training anchor bank is missing classes: {missing}")
    return F.normalize(sums / counts.to(embeddings.device, embeddings.dtype).unsqueeze(1), p=2, dim=1)


def rank_eligible_similar_classes(
    queries: Tensor,
    centroids: Tensor,
    eligible_classes: list[list[int]],
    *,
    excluded_classes: list[int] | None = None,
) -> list[list[tuple[int, float]]]:
    """Rank explicitly authorized alternatives by cosine distance, not probability."""
    if queries.ndim != 2 or centroids.shape != (CLASS_COUNT, queries.shape[1]):
        raise ValueError("queries and centroids must be [batch,dimension] and [229,dimension]")
    if len(eligible_classes) != queries.shape[0] or not torch.isfinite(queries).all() or not torch.isfinite(centroids).all():
        raise ValueError("eligible classes must align with finite query embeddings")
    excluded = excluded_classes or [-1] * len(eligible_classes)
    if len(excluded) != len(eligible_classes):
        raise ValueError("excluded_classes must align with query batch")
    similarities = F.normalize(queries, p=2, dim=1) @ F.normalize(centroids, p=2, dim=1).transpose(0, 1)
    ranked: list[list[tuple[int, float]]] = []
    for row, allowed in enumerate(eligible_classes):
        if not allowed or len(allowed) != len(set(allowed)) or any(index < 0 or index >= CLASS_COUNT for index in allowed):
            raise ValueError(f"query {row} has an empty, duplicate, or invalid alternative set")
        candidates = [index for index in allowed if index != excluded[row]]
        distances = [(index, 1.0 - float(similarities[row, index].item())) for index in candidates]
        ranked.append(sorted(distances, key=lambda item: (item[1], item[0])))
    return ranked
