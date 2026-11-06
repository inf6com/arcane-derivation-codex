"""Parallel time-series and raster classifier for 229 isolated symbols."""
from __future__ import annotations

import torch
from torch import Tensor, nn
from torch.nn import functional as F

from hinotori_raster_classifier import CLASS_COUNT, EMBEDDING_DIMENSION, RASTER_SIZE, ConvBlock
from hinotori_spatial_pyramid import HinotoriSpatialPyramidAngularMargin


class FirebirdTemporalStrokeEncoder(nn.Module):
    """Encode time-positioned pen trajectories and their explicit motion vectors."""

    def __init__(self, embedding_dimension: int = 128):
        super().__init__()
        self.point_encoder = nn.GRU(input_size=8, hidden_size=64, num_layers=2, batch_first=True, bidirectional=True, dropout=0.1)
        self.stroke_projection = nn.Sequential(nn.Linear(256, 128), nn.LayerNorm(128), nn.GELU())
        self.stroke_sequence = nn.GRU(input_size=128, hidden_size=96, num_layers=1, batch_first=True)
        self.embedding = nn.Sequential(nn.Linear(96, 192), nn.LayerNorm(192), nn.GELU(), nn.Dropout(0.15), nn.Linear(192, embedding_dimension), nn.LayerNorm(embedding_dimension))

    @staticmethod
    def point_features(points: Tensor) -> Tensor:
        if points.ndim != 4 or points.shape[-1] != 5 or points.shape[2] < 2:
            raise ValueError("temporal points must be [batch,stroke,point>=2,(x,y,strokePhase,symbolTimePhase,durationRatio)]")
        if not torch.isfinite(points).all():
            raise ValueError("temporal points contain non-finite values")
        xy = points[..., :2]
        stroke_phase, symbol_time, duration = points[..., 2:3], points[..., 3:4], points[..., 4:5]
        delta_xy = F.pad(xy[:, :, 1:] - xy[:, :, :-1], (0, 0, 1, 0))
        delta_time = F.pad(symbol_time[:, :, 1:] - symbol_time[:, :, :-1], (0, 0, 1, 0))
        distance = torch.linalg.vector_norm(delta_xy, dim=-1, keepdim=True)
        direction = delta_xy / distance.clamp_min(1e-6)
        speed = distance / delta_time.clamp_min(1e-3)
        return torch.cat((xy, stroke_phase, symbol_time, direction, speed, duration), dim=-1)

    def forward(self, points: Tensor, stroke_padding: Tensor) -> Tensor:
        if points.ndim != 4 or points.shape[-1] != 5:
            raise ValueError("points must be [batch,stroke,point,5]")
        batch, stroke_count, point_count, _ = points.shape
        if stroke_padding.shape != (batch, stroke_count) or stroke_padding.dtype != torch.bool:
            raise ValueError("stroke_padding must be boolean [batch,stroke]")
        lengths = (~stroke_padding).sum(dim=1)
        if (lengths < 1).any():
            raise ValueError("every symbol must contain at least one stroke")
        features = self.point_features(points).reshape(batch * stroke_count, point_count, 8)
        point_sequences, _ = self.point_encoder(features)
        stroke_summaries = torch.cat((point_sequences.mean(dim=1), point_sequences.amax(dim=1)), dim=1)
        stroke_vectors = self.stroke_projection(stroke_summaries).reshape(batch, stroke_count, 128)
        stroke_vectors = stroke_vectors.masked_fill(stroke_padding.unsqueeze(-1), 0.0)
        # The unidirectional stroke GRU reads chronological InkML trace order.
        # Gather each sample at its last real stroke; trailing batch padding is excluded.
        sequence, _ = self.stroke_sequence(stroke_vectors)
        final = sequence[torch.arange(batch, device=points.device), lengths - 1]
        return F.normalize(self.embedding(final), p=2, dim=1)


class FirebirdTemporalRasterFusion(nn.Module):
    """Fuse an online temporal encoder and a static raster encoder in parallel."""

    def __init__(self, embedding_dimension: int = EMBEDDING_DIMENSION):
        super().__init__()
        if embedding_dimension < 16:
            raise ValueError("embedding dimension is too small")
        self.raster_features = nn.Sequential(
            nn.Conv2d(1, 32, 3, padding=1, bias=False), nn.BatchNorm2d(32), nn.SiLU(), nn.MaxPool2d(2),
            ConvBlock(32, 48), ConvBlock(48, 64, stride=2), ConvBlock(64, 96, stride=2), ConvBlock(96, 128, stride=2),
        )
        self.raster_projection = nn.Sequential(nn.Linear(256, 128), nn.LayerNorm(128), nn.GELU())
        self.temporal_encoder = FirebirdTemporalStrokeEncoder(128)
        self.raster_classifier = nn.Linear(128, CLASS_COUNT)
        self.temporal_classifier = nn.Linear(128, CLASS_COUNT)
        self.fusion = nn.Sequential(nn.Linear(256, 256), nn.LayerNorm(256), nn.GELU(), nn.Dropout(0.2), nn.Linear(256, embedding_dimension), nn.LayerNorm(embedding_dimension))
        self.classifier = nn.Linear(embedding_dimension, CLASS_COUNT)

    def encode_branches(self, images: Tensor, temporal_points: Tensor, stroke_padding: Tensor) -> tuple[Tensor, Tensor]:
        if images.ndim != 4 or images.shape[1:] != (1, RASTER_SIZE, RASTER_SIZE):
            raise ValueError(f"images must have shape [batch,1,{RASTER_SIZE},{RASTER_SIZE}]")
        if temporal_points.shape[0] != images.shape[0] or stroke_padding.shape != temporal_points.shape[:2]:
            raise ValueError("image and temporal stroke batches do not align")
        features = self.raster_features(images)
        visual = torch.cat((F.adaptive_avg_pool2d(features, 1).flatten(1), F.adaptive_max_pool2d(features, 1).flatten(1)), dim=1)
        raster_embedding = self.raster_projection(visual)
        temporal_embedding = self.temporal_encoder(temporal_points, stroke_padding)
        return raster_embedding, temporal_embedding

    def encode(self, images: Tensor, temporal_points: Tensor, stroke_padding: Tensor) -> Tensor:
        raster, temporal = self.encode_branches(images, temporal_points, stroke_padding)
        return F.normalize(self.fusion(torch.cat((raster, temporal), dim=1)), p=2, dim=1)

    def forward(self, images: Tensor, temporal_points: Tensor, stroke_padding: Tensor):
        raster, temporal = self.encode_branches(images, temporal_points, stroke_padding)
        embedding = F.normalize(self.fusion(torch.cat((raster, temporal), dim=1)), p=2, dim=1)
        return self.classifier(embedding), embedding, self.raster_classifier(raster), self.temporal_classifier(temporal)


class FirebirdDerivativeGraphStrokeEncoder(nn.Module):
    """Encode the complete ordered graph of position and first-derivative values."""

    def __init__(self, embedding_dimension: int = 128):
        super().__init__()
        self.point_encoder = nn.GRU(input_size=7, hidden_size=64, num_layers=2, batch_first=True, bidirectional=True, dropout=0.1)
        self.graph_attention = nn.Sequential(nn.Linear(128, 64), nn.Tanh(), nn.Linear(64, 1))
        self.stroke_projection = nn.Sequential(nn.Linear(256, 128), nn.LayerNorm(128), nn.GELU())
        self.stroke_sequence = nn.GRU(input_size=128, hidden_size=96, num_layers=1, batch_first=True)
        self.embedding = nn.Sequential(nn.Linear(96, 192), nn.LayerNorm(192), nn.GELU(), nn.Dropout(0.15), nn.Linear(192, embedding_dimension), nn.LayerNorm(embedding_dimension))

    @staticmethod
    def point_features(points: Tensor) -> Tensor:
        if points.ndim != 4 or points.shape[-1] != 5 or points.shape[2] < 2:
            raise ValueError("points must be [batch,stroke,point>=2,(x,y,strokePhase,symbolTimePhase,durationRatio)]")
        if not torch.isfinite(points).all():
            raise ValueError("trajectory graph contains non-finite values")
        xy = points[..., :2]
        stroke_phase, symbol_time, duration = points[..., 2:3], points[..., 3:4], points[..., 4:5]
        delta_xy = F.pad(xy[:, :, 1:] - xy[:, :, :-1], (0, 0, 1, 0))
        delta_time = F.pad(symbol_time[:, :, 1:] - symbol_time[:, :, :-1], (0, 0, 1, 0))
        epsilon = torch.finfo(points.dtype).eps
        velocity = torch.where(delta_time > 0, delta_xy / delta_time.clamp_min(epsilon), torch.zeros_like(delta_xy))
        # Each point now carries p(t) and its first derivative dp/dt. The
        # sequence encoder models how those values vary across the whole trace.
        return torch.cat((xy, stroke_phase, symbol_time, velocity, duration), dim=-1)

    def forward(self, points: Tensor, stroke_padding: Tensor) -> Tensor:
        if points.ndim != 4 or points.shape[-1] != 5:
            raise ValueError("points must be [batch,stroke,point,5]")
        batch, stroke_count, point_count, _ = points.shape
        if stroke_padding.shape != (batch, stroke_count) or stroke_padding.dtype != torch.bool:
            raise ValueError("stroke_padding must be boolean [batch,stroke]")
        lengths = (~stroke_padding).sum(dim=1)
        if (lengths < 1).any():
            raise ValueError("every symbol must contain at least one stroke")
        features = self.point_features(points).reshape(batch * stroke_count, point_count, 7)
        point_states, _ = self.point_encoder(features)
        attention = torch.softmax(self.graph_attention(point_states).squeeze(-1), dim=1)
        whole_graph = torch.sum(point_states * attention.unsqueeze(-1), dim=1)
        graph_extrema = point_states.amax(dim=1)
        stroke_vectors = self.stroke_projection(torch.cat((whole_graph, graph_extrema), dim=1)).reshape(batch, stroke_count, 128)
        stroke_vectors = stroke_vectors.masked_fill(stroke_padding.unsqueeze(-1), 0.0)
        stroke_states, _ = self.stroke_sequence(stroke_vectors)
        complete_trajectory = stroke_states[torch.arange(batch, device=points.device), lengths - 1]
        return F.normalize(self.embedding(complete_trajectory), p=2, dim=1)


class FirebirdDerivativeGraphRasterFusion(FirebirdTemporalRasterFusion):
    """Classify the fused raster and whole derivative-trajectory representation."""

    def __init__(self, embedding_dimension: int = EMBEDDING_DIMENSION):
        super().__init__(embedding_dimension)
        self.temporal_encoder = FirebirdDerivativeGraphStrokeEncoder(128)
        del self.raster_classifier
        del self.temporal_classifier

    def forward(self, images: Tensor, temporal_points: Tensor, stroke_padding: Tensor) -> tuple[Tensor, Tensor]:
        raster, trajectory_graph = self.encode_branches(images, temporal_points, stroke_padding)
        embedding = F.normalize(self.fusion(torch.cat((raster, trajectory_graph), dim=1)), p=2, dim=1)
        return self.classifier(embedding), embedding


class FirebirdTrajectoryAuxiliaryClassifier(nn.Module):
    """Keep the trained raster classifier primary and add a bounded trajectory vote."""

    def __init__(self, scale: float = 32.0, maximum_auxiliary_weight: float = 0.5, initial_auxiliary_weight: float = 0.05):
        super().__init__()
        if scale <= 0 or not 0 < initial_auxiliary_weight < maximum_auxiliary_weight <= 1:
            raise ValueError("auxiliary score scale and weight bounds are invalid")
        self.primary_classifier = HinotoriSpatialPyramidAngularMargin(scale=scale)
        self.trajectory_encoder = FirebirdDerivativeGraphStrokeEncoder(128)
        self.trajectory_prototypes = nn.Parameter(torch.empty(CLASS_COUNT, 128))
        nn.init.xavier_uniform_(self.trajectory_prototypes)
        initial_fraction = initial_auxiliary_weight / maximum_auxiliary_weight
        gate_logit = torch.logit(torch.tensor(initial_fraction))
        self.auxiliary_gate_logit = nn.Parameter(gate_logit)
        self.maximum_auxiliary_weight = float(maximum_auxiliary_weight)
        self.scale = float(scale)

    def train(self, mode: bool = True):
        super().train(mode)
        # The selected, validated primary classifier remains frozen and in eval mode.
        self.primary_classifier.eval()
        return self

    def forward(self, images: Tensor, temporal_points: Tensor, stroke_padding: Tensor) -> tuple[Tensor, Tensor, Tensor, Tensor]:
        with torch.no_grad():
            primary_logits, _ = self.primary_classifier(images)
        trajectory_embedding = self.trajectory_encoder(temporal_points, stroke_padding)
        auxiliary_logits = F.linear(
            trajectory_embedding,
            F.normalize(self.trajectory_prototypes, p=2, dim=1),
        ) * self.scale
        auxiliary_weight = self.maximum_auxiliary_weight * torch.sigmoid(self.auxiliary_gate_logit)
        final_logits = primary_logits + auxiliary_weight * auxiliary_logits
        return final_logits, primary_logits, auxiliary_logits, auxiliary_weight


class FirebirdMarginGatedTrajectoryAuxiliaryClassifier(FirebirdTrajectoryAuxiliaryClassifier):
    """Use the primary top-1/top-2 score margin to gate a direction-symmetric auxiliary vote."""

    def __init__(self, scale: float = 32.0, maximum_auxiliary_weight: float = 0.5):
        super().__init__(scale=scale, maximum_auxiliary_weight=maximum_auxiliary_weight, initial_auxiliary_weight=0.05)
        del self.auxiliary_gate_logit
        self.auxiliary_gate_bias = nn.Parameter(torch.tensor(-2.1972246))
        self.auxiliary_gate_slope_raw = nn.Parameter(torch.tensor(1.8545865))

    @staticmethod
    def reverse_all_stroke_directions(points: Tensor, stroke_padding: Tensor) -> Tensor:
        if points.ndim != 4 or points.shape[-1] != 5 or stroke_padding.shape != points.shape[:2]:
            raise ValueError("direction reversal requires aligned [batch,stroke,point,5] points and stroke padding")
        reversed_xy = points[..., :2].flip(dims=(2,))
        xy = torch.where(stroke_padding[:, :, None, None], points[..., :2], reversed_xy)
        return torch.cat((xy, points[..., 2:]), dim=-1)

    def forward(self, images: Tensor, temporal_points: Tensor, stroke_padding: Tensor) -> tuple[Tensor, Tensor, Tensor, Tensor]:
        with torch.no_grad():
            primary_logits, _ = self.primary_classifier(images)
        reversed_points = self.reverse_all_stroke_directions(temporal_points, stroke_padding)
        forward_embedding = self.trajectory_encoder(temporal_points, stroke_padding)
        reversed_embedding = self.trajectory_encoder(reversed_points, stroke_padding)
        normalized_prototypes = F.normalize(self.trajectory_prototypes, p=2, dim=1)
        forward_scores = F.linear(forward_embedding, normalized_prototypes) * self.scale
        reversed_scores = F.linear(reversed_embedding, normalized_prototypes) * self.scale
        auxiliary_logits = (forward_scores + reversed_scores) * 0.5
        top_two = primary_logits.topk(2, dim=1).values
        normalized_margin = (top_two[:, 0] - top_two[:, 1]) / self.scale
        positive_slope = F.softplus(self.auxiliary_gate_slope_raw)
        auxiliary_weight = self.maximum_auxiliary_weight * torch.sigmoid(
            self.auxiliary_gate_bias - positive_slope * normalized_margin
        )
        final_logits = primary_logits + auxiliary_weight[:, None] * auxiliary_logits
        return final_logits, primary_logits, auxiliary_logits, auxiliary_weight
