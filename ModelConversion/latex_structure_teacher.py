#!/usr/bin/env python3
"""Lossless restricted LaTeX AST teacher; unsupported syntax fails explicitly."""
from __future__ import annotations
import json
class ParseError(ValueError): pass
class P:
 def __init__(self,s): self.s=s; self.i=0
 def seq(self,end=None):
  a=[]
  while self.i<len(self.s) and self.s[self.i]!=end:
   a.append(self.atom())
  if end:
   if self.i==len(self.s): raise ParseError('unclosed group')
   self.i+=1
  return a
 def group(self):
  if self.i>=len(self.s) or self.s[self.i]!='{': raise ParseError('expected group')
  self.i+=1; return self.seq('}')
 def literal_group(self):
  if self.i>=len(self.s) or self.s[self.i]!='{': raise ParseError('expected literal group')
  end=self.s.find('}',self.i+1)
  if end<0: raise ParseError('unclosed literal group')
  value=self.s[self.i+1:end]; self.i=end+1; return value
 def matrix(self):
  rows=[[]]; cells=[[]]
  terminator='\\end{matrix}'
  while self.i<len(self.s):
   if self.s.startswith(terminator,self.i):
    self.i+=len(terminator); rows[-1]=cells; return {'k':'matrix','rows':rows}
   if self.s[self.i]=='&':
    self.i+=1; cells.append([]); continue
   if self.s.startswith('\\\\',self.i):
    self.i+=2; rows[-1]=cells; rows.append([]); cells=[[]]; continue
   cells[-1].append(self.atom())
  raise ParseError('unclosed matrix environment')
 def atom(self):
  c=self.s[self.i]; self.i+=1
  if c=='{': return {'k':'group','a':self.seq('}')}
  if c=='\\':
   j=self.i
   while self.i<len(self.s) and self.s[self.i].isalpha(): self.i+=1
   name=self.s[j:self.i]
   if name=='begin':
    environment=self.literal_group()
    if environment!='matrix': raise ParseError('unsupported environment: '+environment)
    return self.matrix()
   if name=='end': raise ParseError('unexpected matrix end')
   if name in ('left','right'):
    raise ParseError('unsupported delimiter structure: \\'+name)
   if name=='frac': return {'k':'frac','n':self.group(),'d':self.group()}
   if name=='sqrt':
    index=None
    if self.i<len(self.s) and self.s[self.i]=='[':
     self.i+=1; index=self.seq(']')
    return {'k':'sqrt','a':self.group(),'index':index}
   if not name:
    # TeX permits an escaped punctuation character as a literal symbol.  It is
    # not a command name, but preserving it as one token keeps reconstruction
    # lossless and lets the structural relation stage assign it a position.
    if self.i<len(self.s) and not self.s[self.i].isalpha() and not self.s[self.i].isspace():
     escaped=self.s[self.i]; self.i+=1; return {'k':'cmd','v':'\\'+escaped}
    raise ParseError('bare escape')
   return {'k':'cmd','v':'\\'+name}
  if c in '^_':
   braced=self.i<len(self.s) and self.s[self.i]=='{'
   return {'k':'sup' if c=='^' else 'sub','a':self.group() if braced else [self.atom()],'braced':braced}
  if c=='$': raise ParseError('unsupported token '+c)
  return {'k':'sym','v':c}
def parse(s):
 p=P(s); a=p.seq(); return {'k':'root','a':a}
def render(n):
 k=n['k']
 if k=='root': return ''.join(map(render,n['a']))
 if k=='group': return '{'+''.join(map(render,n['a']))+'}'
 if k=='sym' or k=='cmd': return n['v']
 if k=='sup': return '^'+(('{' if n['braced'] else '')+''.join(map(render,n['a']))+('}' if n['braced'] else ''))
 if k=='sub': return '_'+(('{' if n['braced'] else '')+''.join(map(render,n['a']))+('}' if n['braced'] else ''))
 if k=='frac': return '\\frac{' + ''.join(map(render,n['n']))+'}{'+''.join(map(render,n['d']))+'}'
 if k=='sqrt': return '\\sqrt'+(('['+''.join(map(render,n['index']))+']') if n['index'] is not None else '')+'{' + ''.join(map(render,n['a']))+'}'
 if k=='matrix': return '\\begin{matrix}'+ '\\\\'.join('&'.join(''.join(map(render,cell)) for cell in row) for row in n['rows'])+'\\end{matrix}'
 raise ParseError('unknown AST')
def visual(n,out=None,edges=None,parent=None,rel='baseline',position=0):
 """Emit explicit structural nodes and deterministic parent edges.

 The list contains both visual leaves and structural operators.  A structural
 operator is necessary because a numerator, denominator, or radical operand
 otherwise has no real parent token.  Edges are [parentNodeId, childNodeId,
 relationKind, structurePosition]; the root has no emitted node.
 """
 out=[] if out is None else out; edges=[] if edges is None else edges
 def add(token, parent_node, relation, sibling_position):
  node_id=len(out); out.append({'nodeId':node_id,'token':token})
  if parent_node is not None: edges.append([parent_node,node_id,relation,sibling_position])
  return node_id
 def children(items, parent_node, relation):
  last=None; child_nodes=[]
  for sibling_position,x in enumerate(items):
   # Baseline tokens are a sequence; other relation groups are siblings of the
   # structural operator, not a handwritten spatial rule.
   actual_parent=last if relation=='baseline' and last is not None else parent_node
   child=visual(x,out,edges,actual_parent,relation,sibling_position)
   child_nodes.append(child)
   if out[child]['token'] in ('(',')','[',']','\\{','\\}','\\langle','\\rangle','\\lceil','\\rceil','\\lfloor','\\rfloor'):
    # Delimiters belong to a parsed syntax scope.  They are not forced into
    # symmetric pairs: intervals and bra/ket notation are intentionally
    # asymmetric in the source labels.
    if parent_node is not None: edges.append([parent_node,child,'delimiter',sibling_position])
   if relation=='baseline': last=child
  return last
 k=n['k']
 if k in ('sym','cmd'): return add(n['v'],parent,rel,position)
 if k=='root':
  scope=add('root',None,'baseline',0); children(n['a'],scope,'baseline'); return scope
 if k=='group':
  scope=add('group',parent,rel,position); children(n['a'],scope,'baseline'); return scope
 if k=='sup':
  op=add('^',parent,rel,position); children(n['a'],op,'superscript'); return op
 if k=='sub':
  op=add('_',parent,rel,position); children(n['a'],op,'subscript'); return op
 if k=='frac':
  op=add('\\frac',parent,rel,position); children(n['n'],op,'numerator'); children(n['d'],op,'denominator'); return op
 if k=='sqrt':
  op=add('\\sqrt',parent,rel,position)
  if n['index'] is not None: children(n['index'],op,'radical-index')
  children(n['a'],op,'radicand'); return op
 if k=='matrix':
  op=add('\\begin{matrix}',parent,rel,position)
  for row_position,row in enumerate(n['rows']):
   row_node=add('matrix-row',op,'matrix-row',row_position)
   for cell_position,cell in enumerate(row):
    cell_node=add('matrix-cell',row_node,'matrix-cell',cell_position)
    children(cell,cell_node,'baseline')
  return op
 raise ParseError('unknown AST node '+k)
def record(sample_id,label):
 ast=parse(label); rebuilt=render(ast)
 if rebuilt!=label: raise ParseError('nonlossless reconstruction')
 nodes=[]; e=[]; visual(ast,nodes,e)
 return {'sampleId':sample_id,'latex':label,'visualTokens':[node['token'] for node in nodes], 'nodes':nodes,'relations':e,'ast':ast}

if __name__=='__main__':
 import argparse,hashlib
 from pathlib import Path
 p=argparse.ArgumentParser(); p.add_argument('--input',type=Path,required=True); p.add_argument('--output',type=Path,required=True); p.add_argument('--report',type=Path,required=True); a=p.parse_args()
 accepted=failed=0; errors=[]
 with a.output.open('w',encoding='utf-8') as out:
  for line in a.input.read_text(encoding='utf-8').splitlines():
   d=json.loads(line)
   try: out.write(json.dumps(record(d['sampleId'],d['normalizedLabel']),ensure_ascii=False)+'\n'); accepted+=1
   except ParseError as e: errors.append({'sampleId':d['sampleId'],'latex':d['normalizedLabel'],'kind':str(e)}); failed+=1
 a.report.write_text(json.dumps({'input':str(a.input),'inputSHA256':hashlib.sha256(a.input.read_bytes()).hexdigest(),'output':str(a.output),'outputSHA256':hashlib.sha256(a.output.read_bytes()).hexdigest(),'accepted':accepted,'failed':failed,'errors':errors},ensure_ascii=False,indent=2),encoding='utf-8')
