#!/usr/bin/env python3
"""CPU verifies graph contracts only; it never executes the graph."""
import unittest
from unittest.mock import patch
import torch

from train_formula_structure_graph import FormulaStructureTrainingGraph, MetalProbe, assert_graph_batch, mps_training_step, require_mps


def batch():
    return {"sampleIds":["a"], "latexIds":torch.tensor([[1,4,2]]), "visualIds":torch.tensor([[1,5,6,2]]), "relationTarget":torch.zeros(1,2,2,10), "relationMask":torch.tensor([[[False,True],[False,False]]]), "raster":torch.zeros(1,1,512,512), "instanceRaster":torch.zeros(1,2,1,512,512), "instanceMask":torch.tensor([[True,True]]), "instanceSampleIds":[["a","a"]], "relationMaskInstances":torch.tensor([[[False,True],[False,False]]])}


class GraphPreflightTests(unittest.TestCase):
    def test_zero_raw_device_aborts_before_mps_or_forward(self):
        with self.assertRaisesRegex(RuntimeError, "before forward: raw Metal device visibility"):
            require_mps(MetalProbe(False, 0))
        graph = FormulaStructureTrainingGraph(8, 9)
        with patch("train_formula_structure_graph.raw_metal_probe", return_value=MetalProbe(False, 0)), patch.object(graph, "forward", side_effect=AssertionError("forward must not run")):
            with self.assertRaisesRegex(RuntimeError, "before forward: raw Metal device visibility"):
                mps_training_step(graph, batch(), 0, 0)

    def test_graph_contract_rejects_cross_formula_instance(self):
        invalid=batch(); invalid["instanceSampleIds"]=[["a","other"]]
        with self.assertRaisesRegex(ValueError, "sampleId mismatch"): assert_graph_batch(invalid)

    def test_cpu_graph_forward_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "requires MPS"):
            FormulaStructureTrainingGraph(8, 9)(batch())


if __name__ == "__main__": unittest.main()
