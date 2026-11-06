#!/usr/bin/env python3
import json,tempfile,unittest
from pathlib import Path
import torch
from instance_structure_relation import InstanceRelationHead,assert_formula_only_decoder_contract,relation_loss,relation_targets

class InstanceStructureRelationTests(unittest.TestCase):
 def test_direct_pairs_emit_only_proven_edge_labels(self):
  rows=[{"split":"train","sampleId":"s","instanceId":"s:0","astNodeId":3,"incidentRelations":[[3,4,"baseline",0]],"teacherLayer":"ast-node-edge-auxiliary"},{"split":"train","sampleId":"s","instanceId":"s:1","astNodeId":4,"incidentRelations":[[3,4,"baseline",0]],"teacherLayer":"ast-node-edge-auxiliary"}]
  target=relation_targets(rows)["train:s"]; self.assertEqual(target["pairIndex"].tolist(),[[0,1],[1,0]]); self.assertEqual(target["target"].tolist(),[1,0])
 def test_formula_only_cannot_enter_relation_layer(self):
  with tempfile.TemporaryDirectory() as directory:
   path=Path(directory)/"f.jsonl"; path.write_text(json.dumps({"teacherLayer":"formula-latex-structure-only","astNodeId":None})+"\n")
   with self.assertRaisesRegex(ValueError,"cannot enter relation loss"): assert_formula_only_decoder_contract(path)
 def test_cpu_relation_model_is_rejected_but_loss_contract_is_testable(self):
  with self.assertRaisesRegex(RuntimeError,"requires MPS"): InstanceRelationHead()(torch.zeros((2,128)),torch.tensor([[0,1]]))
  self.assertTrue(torch.isfinite(relation_loss(torch.zeros((2,11)),torch.tensor([0,1]))))
if __name__=="__main__": unittest.main()
