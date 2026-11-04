#!/usr/bin/env python3
"""Score final outputs of a frozen synthetic correction suite, separately from candidates.

Lexical reference matches are a narrow diagnostic, not a human quality judgment.
No output text is printed by default.
"""
from __future__ import annotations
import argparse,collections,hashlib,json,re,statistics,unicodedata,math
from pathlib import Path

def tokens(text):
    return re.findall(r"\w+(?:'\w+)*",unicodedata.normalize('NFC',text).replace('’',"'").casefold())

def validate_frozen_corpus(root):
    """Verify bytes, provenance, unique utterances and split membership before a run."""
    manifest=json.loads((root/'manifest.json').read_text())
    if manifest.get('source')!='synthetic' or manifest.get('humanReviewed') is not False or manifest.get('trainingEligible') is not False:
        raise ValueError('This benchmark must remain explicitly synthetic and evaluation-only')
    for name,digest in manifest['files'].items():
        if name not in ('cases.jsonl','development.json','holdout.json'):
            raise ValueError('Unexpected corpus file')
        if hashlib.sha256((root/name).read_bytes()).hexdigest()!=digest:
            raise ValueError('Frozen corpus changed: '+name)
    rows=[json.loads(line) for line in (root/'cases.jsonl').read_text().splitlines() if line]
    if len(rows)!=manifest['count'] or not rows:
        raise ValueError('Invalid corpus count')
    for field in ('id','sourceGroup','transcript'):
        values=[str(row[field]).casefold().strip() for row in rows]
        if len(values)!=len(set(values)):
            raise ValueError('Duplicate corpus '+field)
    for row in rows:
        if row['source']!='synthetic' or row['humanReviewed'] is not False or not row['expected'].strip():
            raise ValueError('Invalid provenance or reference: '+row['id'])
    for split,count in manifest['countsBySplit'].items():
        expected=[row for row in rows if row['split']==split]
        actual=json.loads((root/(split+'.json')).read_text())['cases']
        if actual!=expected or len(actual)!=count:
            raise ValueError('Split membership mismatch: '+split)
    return manifest

def score(suite,report):
    cases=suite['cases'];expected={c['id']:c for c in cases}
    if not cases or len(expected)!=len(cases):
        raise ValueError('Suite must have unique cases and nonempty references')
    ids=[r['id'] for r in report['results']]
    if len(ids)!=len(set(ids)) or set(ids)!=set(expected):
        raise ValueError('Report must contain every frozen case exactly once')
    rows=[]
    for result in report['results']:
        c=expected[result['id']];final=result['finalText']
        if not isinstance(final,str) or not isinstance(c.get('expected'),str) or not c['expected'].strip():
            raise ValueError('Final text and nonempty reference required')
        duration=result['durationMilliseconds']
        if not isinstance(duration,(int,float)) or not math.isfinite(duration) or duration<0:
            raise ValueError('Invalid measured duration')
        if result.get('expected')!=c['expected']:
            raise ValueError('Result reference does not match frozen suite: '+c['id'])
        numeric=lambda s:re.findall(r'\b\d+(?:[.,]\d+)?\b',s)
        code=lambda s:re.findall(r'(?:/[^\s,.]+|--[\w-]+|\b\w+_\w+\b)',s)
        # Literal reference comparison only: this does not prove factual preservation.
        # Number words versus digits may differ legitimately on older suites.
        literals_match=numeric(final)==numeric(c['expected']) and code(final)==code(c['expected'])
        markdown=bool(re.search(r'(^\s*[*_`#]|\*\*|```)',final)) and not bool(re.search(r'(^\s*[*_`#]|\*\*|```)',c['expected']))
        lexical=tokens(final)==tokens(c['expected'])
        rows.append({'id':c['id'],'category':c.get('category','legacy'),'language':c['language'],
            'exact':final==c['expected'],'lexicalMatch':lexical,'literalDigitCodeMatch':literals_match,
            'unrequestedMarkdown':markdown,'cleanReferenceMatch':lexical and literals_match and not markdown,
            'failure':result.get('failure'),'rejection':result.get('rejection'),
            'route':result.get('route'),'durationMilliseconds':result['durationMilliseconds']})
    counts=collections.Counter(c['category'] for c in rows)
    durations=[r['durationMilliseconds'] for r in rows]
    return {'caseCount':len(rows),'exactCount':sum(r['exact'] for r in rows),
        'lexicalMatchCount':sum(r['lexicalMatch'] for r in rows),
        'cleanReferenceMatchCount':sum(r['cleanReferenceMatch'] for r in rows),
        'literalDigitCodeMismatchCount':sum(not r['literalDigitCodeMatch'] for r in rows),
        'unrequestedMarkdownCount':sum(r['unrequestedMarkdown'] for r in rows),
        'changedPreservationCases':[r['id'] for r in rows if r['category'] in ('preserve','ambiguity') and not r['cleanReferenceMatch']],
        'failedCalls':sum(r['failure'] is not None for r in rows),
        'meanMilliseconds':round(statistics.mean(durations),1),'medianMilliseconds':statistics.median(durations),
        'byCategory':{k:{'count':n,'cleanReferenceMatches':sum(r['category']==k and r['cleanReferenceMatch'] for r in rows)} for k,n in sorted(counts.items())},
        'rows':rows}

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--suite',type=Path,required=True);parser.add_argument('--report',type=Path,required=True);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    result=score(json.loads(args.suite.read_text()),json.loads(args.report.read_text()))
    result.update(suiteSHA256=hashlib.sha256(args.suite.read_bytes()).hexdigest(),reportSHA256=hashlib.sha256(args.report.read_bytes()).hexdigest())
    args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ('rows','byCategory')},ensure_ascii=False))
if __name__=='__main__':main()
