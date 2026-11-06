#!/usr/bin/env python3
import unittest
from assemble_three_layer_teachers import validate

class ThreeLayerTeacherTests(unittest.TestCase):
 def test_null_ast_node_id_cannot_become_auxiliary_class(self):
  all_instances=[{"sampleId":"a","split":"train"}]*6423
  with self.assertRaisesRegex(ValueError,"AST auxiliary"):
   validate(all_instances,[{"astNodeId":None}],[],[])
 def test_formula_only_assignment_must_omit_node_id(self):
  all_instances=[{"sampleId":str(index),"split":"train"} for index in range(3426)]
  all_instances.extend({"sampleId":"0","split":"train"} for _ in range(6423-3426))
  with self.assertRaisesRegex(ValueError,"omit astNodeId"):
   validate(all_instances,[],[{"sampleId":"a","astNodeId":None}],[])
if __name__=="__main__": unittest.main()
