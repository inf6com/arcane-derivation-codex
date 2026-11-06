#!/usr/bin/env python3
"""Deterministically split train-only instance teachers by source formula ID."""
import argparse,hashlib,json
from collections import Counter
from pathlib import Path
def main():
 p=argparse.ArgumentParser(); p.add_argument('--input',type=Path,required=True); p.add_argument('--train',type=Path,required=True); p.add_argument('--validation',type=Path,required=True); p.add_argument('--report',type=Path,required=True); a=p.parse_args()
 rows=[json.loads(x) for x in a.input.read_text().splitlines()]; ids={x['sampleId'] for x in rows}; by_label={}
 for r in rows: by_label.setdefault(r['symbolToken'],set()).add(r['sampleId'])
 valid={i for i in ids if int(hashlib.sha256(i.encode()).hexdigest()[:8],16)%10==0}
 # Every observed label must be represented in validation without splitting a formula.
 for label,sources in by_label.items():
  if not sources & valid: valid.add(min(sources,key=lambda i:hashlib.sha256((label+i).encode()).hexdigest()))
 def write(path,part): path.write_text(''.join(json.dumps(x,ensure_ascii=False)+'\n' for x in part))
 tr=[x for x in rows if x['sampleId'] not in valid]; va=[x for x in rows if x['sampleId'] in valid]; write(a.train,tr); write(a.validation,va)
 labels=sorted({x['symbolToken'] for x in rows}); c=lambda x:Counter(r['symbolToken'] for r in x)
 report={'source':'train-symbol-instance-teachers-v2 train-only','formulaCounts':{'train':len({x['sampleId'] for x in tr}),'validation':len(valid)},'instanceCounts':{'train':len(tr),'validation':len(va)},'vocabularySize':len(labels),'validationMissingLabels':[x for x in labels if not c(va)[x]],'validationRareLabels':{x:c(va)[x] for x in labels if c(va)[x]<3}}
 a.report.write_text(json.dumps(report,ensure_ascii=False,indent=2))
if __name__=='__main__': main()
