import json
from pathlib import Path
import tempfile
import unittest
import torch

from formula_structure_decoder import (FormulaStructureTeacherDataset, FormulaStructureDecoder, VisualVocabulary, assert_decoder_condition, build_visual_vocabulary, collate_formula_structure, teacher_forcing_loss)
from formula_whole_model import FormulaTokenizer
from instance_structure_relation import RELATION_TYPES


class FormulaStructureDecoderTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.path = Path(self.temp.name) / "teacher.jsonl"
        rows = [{"sampleId":"a","latex":"x","visualTokens":["root","x"],"nodes":[{"nodeId":0,"token":"root"},{"nodeId":1,"token":"x"}],"relations":[[0,1,"baseline",0]]}, {"sampleId":"b","latex":"y","visualTokens":["root","y"],"nodes":[{"nodeId":0,"token":"root"},{"nodeId":1,"token":"y"}],"relations":[[0,1,"baseline",0]]}]
        self.path.write_text("".join(json.dumps(row)+"\n" for row in rows), encoding="utf-8")
        tokens=["<pad>","<bos>","<eos>","<unk>","x","y"]
        self.latex=FormulaTokenizer(tokens,{value:index for index,value in enumerate(tokens)},"character")

    def tearDown(self): self.temp.cleanup()

    def test_loader_and_mask(self):
        visual=build_visual_vocabulary(self.path); dataset=FormulaStructureTeacherDataset(self.path,self.latex,visual)
        self.assertEqual(len(dataset),2); batch=collate_formula_structure([dataset[0],dataset[1]],self.latex.pad_id,visual.pad_id)
        self.assertEqual(batch["relationTarget"].shape,(2,2,2,10)); self.assertTrue(batch["relationMask"][0,0,1])
        self.assertEqual(dataset[0]["latexIds"].tolist(),[1,4,2])

    def test_identity_and_cpu_decoder_rejection(self):
        visual=build_visual_vocabulary(self.path); dataset=FormulaStructureTeacherDataset(self.path,self.latex,visual); batch=collate_formula_structure([dataset[0]],self.latex.pad_id,visual.pad_id)
        spatial=torch.zeros(1,128,128,128); instances=torch.zeros(1,1,128); active=torch.tensor([[True]]); relations=torch.zeros(1,1,1,len(RELATION_TYPES)); relation_mask=torch.tensor([[[False]]])
        assert_decoder_condition(batch,spatial,instances,active,[["a"]],relations,relation_mask)
        with self.assertRaisesRegex(ValueError,"sampleId mismatch"): assert_decoder_condition(batch,spatial,instances,active,[["other"]],relations,relation_mask)
        with self.assertRaisesRegex(RuntimeError,"requires MPS"): FormulaStructureDecoder(self.latex.vocab_size,visual.size)(spatial,instances,active,relations,relation_mask,batch["latexIds"][:,:-1],batch["visualIds"][:,:-1])

    def test_teacher_forcing_loss_masks_relations(self):
        batch={"latexIds":torch.tensor([[1,4,2]]),"visualIds":torch.tensor([[1,3,4,2]]),"relationTarget":torch.zeros(1,2,2,10),"relationMask":torch.tensor([[[False,True],[False,False]]])}
        batch["relationTarget"][0,0,1,0]=1
        result=teacher_forcing_loss(torch.zeros(1,2,6),torch.zeros(1,3,5),torch.zeros(1,2,2,10),batch,0,0)
        self.assertTrue(torch.isfinite(result["total"]))

if __name__ == "__main__": unittest.main()
