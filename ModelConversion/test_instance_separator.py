#!/usr/bin/env python3
"""CPU tensor-contract diagnostics only; this file never optimizes a model."""
import json,tempfile,unittest
from pathlib import Path
import torch
from instance_separator import EXPECTED_CLASS_COUNT,MASK_SIZE,RASTER_SIZE,InstanceSeparator,InstanceTeacherDataset,SymbolVocabulary,collate_instances,instance_loss

class InstanceSeparatorContractTests(unittest.TestCase):
 def test_cpu_model_execution_is_rejected(self):
  with self.assertRaisesRegex(RuntimeError,"requires MPS"): InstanceSeparator()(torch.zeros((1,1,RASTER_SIZE,RASTER_SIZE)))
 def test_loss_contract_is_finite_without_optimization(self):
  batch={"raster":torch.zeros((2,1,RASTER_SIZE,RASTER_SIZE)),"mask":torch.zeros((2,1,MASK_SIZE,MASK_SIZE)),"bbox":torch.tensor([[.1,.2,.5,.8],[.2,.1,.6,.7]]),"classIndex":torch.tensor([0,EXPECTED_CLASS_COUNT-1],dtype=torch.long),"sampleIds":["a","b"],"instanceIds":["a:0","b:1"],"astConnectionIds":["a","b"]}
  outputs={"maskLogits":torch.zeros((2,1,MASK_SIZE,MASK_SIZE)),"bbox":torch.full((2,4),.5),"classLogits":torch.zeros((2,EXPECTED_CLASS_COUNT))}; losses=instance_loss(outputs,batch)
  self.assertTrue(torch.isfinite(losses["total"])); self.assertEqual(set(losses),{"total","mask","bbox","class"})
 def test_dataset_rejects_missing_ast_source_connection(self):
  with tempfile.TemporaryDirectory() as directory:
   root=Path(directory); teacher=root/"instances.jsonl"; structure=root/"structure.jsonl"; teacher.write_text(json.dumps({"sampleId":"missing","instanceId":"missing:0","symbolToken":"x","maskPixels512":[0],"bbox512":[0,0,1,1],"coordinateSpec":"FormulaRasterV1-512-margin32-isotropic"})+"\n"); structure.write_text(json.dumps({"sampleId":"other"})+"\n"); tokens=tuple(["x"]+[f"t{i}" for i in range(1,EXPECTED_CLASS_COUNT)])
   with self.assertRaisesRegex(ValueError,"no AST source connection"): InstanceTeacherDataset(teacher,root,structure,SymbolVocabulary(tokens))
 def test_collation_preserves_source_stable_connection_ids(self):
  item={"raster":torch.zeros((1,RASTER_SIZE,RASTER_SIZE)),"mask512":torch.zeros((1,RASTER_SIZE,RASTER_SIZE)),"bbox":torch.tensor([.1,.1,.2,.2]),"classIndex":torch.tensor(1,dtype=torch.long),"sampleId":"sample","instanceId":"sample:3-4","astConnectionId":"sample"}; batch=collate_instances([item])
  self.assertEqual(tuple(batch["mask"].shape),(1,1,MASK_SIZE,MASK_SIZE)); self.assertEqual(batch["astConnectionIds"],["sample"])
if __name__=="__main__": unittest.main()
