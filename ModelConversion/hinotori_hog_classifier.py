"""HOG + linear head baseline for isolated 229-symbol recognition."""
from __future__ import annotations

import torch
from torch import Tensor, nn
from torch.nn import functional as F


CLASS_COUNT = 229
RASTER_SIZE = 64
ORIENTATION_BINS = 9
CELL_SIZE = 8


def hog_descriptor(images: Tensor) -> Tensor:
    """Compute unsigned-gradient HOG with 8px cells and 2x2-cell blocks."""
    if images.ndim != 4 or images.shape[1:] != (1, RASTER_SIZE, RASTER_SIZE):
        raise ValueError("images must have shape [batch,1,64,64]")
    if not torch.isfinite(images).all():
        raise ValueError("images contain non-finite values")
    sobel_x = images.new_tensor([[-1, 0, 1], [-2, 0, 2], [-1, 0, 1]]).view(1, 1, 3, 3) / 8
    sobel_y = sobel_x.transpose(-1, -2)
    gx = F.conv2d(images, sobel_x, padding=1)
    gy = F.conv2d(images, sobel_y, padding=1)
    magnitude = torch.sqrt(gx.square() + gy.square() + 1e-12)
    angle = torch.remainder(torch.atan2(gy, gx), torch.pi)
    bins = torch.floor(angle * (ORIENTATION_BINS / torch.pi)).long().clamp_(0, ORIENTATION_BINS - 1)
    votes = F.one_hot(bins[:, 0], num_classes=ORIENTATION_BINS).to(images.dtype)
    votes = votes * magnitude[:, 0, :, :, None]
    votes = votes.permute(0, 3, 1, 2).contiguous()
    cells = F.avg_pool2d(votes, kernel_size=CELL_SIZE, stride=CELL_SIZE) * (CELL_SIZE * CELL_SIZE)
    # [N, bins, cell_y, cell_x] -> normalized overlapping 2x2-cell blocks.
    cell_grid = cells.permute(0, 2, 3, 1).contiguous()
    blocks = cell_grid.unfold(1, 2, 1).unfold(2, 2, 1)
    blocks = blocks.permute(0, 1, 2, 4, 5, 3).reshape(images.shape[0], 7, 7, 4 * ORIENTATION_BINS)
    blocks = blocks / torch.sqrt(blocks.square().sum(-1, keepdim=True) + 1e-6)
    blocks = blocks.clamp(max=0.2)
    blocks = blocks / torch.sqrt(blocks.square().sum(-1, keepdim=True) + 1e-6)
    return blocks.flatten(1)


class HinotoriHOGClassifier(nn.Module):
    """Fixed HOG image descriptor followed by a learned 229-way linear head."""

    def __init__(self) -> None:
        super().__init__()
        self.embedding_dimension = 7 * 7 * 4 * ORIENTATION_BINS
        self.classifier = nn.Linear(self.embedding_dimension, CLASS_COUNT)

    def forward(self, images: Tensor) -> tuple[Tensor, Tensor]:
        features = hog_descriptor(images)
        return self.classifier(features), F.normalize(features, dim=1)
