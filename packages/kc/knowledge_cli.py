"""Explicit knowledge workflow commands; review/publish use separate human approval credentials."""
import argparse
import json
import os
from pathlib import Path
from uuid import UUID

import psycopg

from kc import knowledge
from kc.session import tenant_transaction


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='action',required=True)
    create=sub.add_parser('create'); create.add_argument('file',type=Path,help='JSON arguments for create_draft')
    edit=sub.add_parser('edit'); edit.add_argument('version',type=UUID); edit.add_argument('file',type=Path,help='JSON title/content/summary/metadata changes')
    attach=sub.add_parser('attach'); attach.add_argument('version',type=UUID); attach.add_argument('artifact_version',type=UUID); attach.add_argument('--locator',required=True); attach.add_argument('--note',default='')
    assign=sub.add_parser('assign'); assign.add_argument('version',type=UUID); assign.add_argument('role',type=UUID); assign.add_argument('principal',type=UUID)
    for name in ('submit','review','publish','return-to-draft','revise','show'):
        cmd=sub.add_parser(name); cmd.add_argument('version',type=UUID)
        if name in ('submit','review','publish','return-to-draft'): cmd.add_argument('--transition')
        if name=='review': cmd.add_argument('--note',required=True)
    args=parser.parse_args()
    with psycopg.connect(os.environ['KC_RUNTIME_DSN']) as conn:
        with tenant_transaction(conn,os.environ['KC_SESSION_TICKET']):
            if args.action=='create': result=knowledge.create_draft(conn,**json.loads(args.file.read_text(encoding='utf-8')))
            elif args.action=='edit': result=knowledge.edit_draft(conn,args.version,**json.loads(args.file.read_text(encoding='utf-8')))
            elif args.action=='attach': result=knowledge.attach_evidence(conn,args.version,args.artifact_version,args.locator,args.note)
            elif args.action=='assign': result=knowledge.assign_responsibility(conn,args.version,args.role,args.principal)
            elif args.action=='revise': result=knowledge.revise(conn,args.version)
            elif args.action=='show':
                row=conn.execute('SELECT to_jsonb(v) FROM catalog.knowledge_version v WHERE knowledge_version_id=%s',(args.version,)).fetchone()
                if row is None: raise ValueError('Knowledge unavailable')
                result={'version':row[0],
                    'citations':[r[0] for r in conn.execute('SELECT to_jsonb(c) FROM catalog.citation c WHERE knowledge_version_id=%s',(args.version,))],
                    'reviews':[r[0] for r in conn.execute('SELECT to_jsonb(r) FROM governance.knowledge_review r WHERE knowledge_version_id=%s',(args.version,))]}
            else:
                kwargs={'transition_key':args.transition} if args.transition else {}
                if args.action=='review': kwargs['note']=args.note
                result=getattr(knowledge,args.action.replace('-','_'))(conn,args.version,**kwargs)
        # Print only after the transaction has committed successfully.
        print(json.dumps(result,default=str,indent=2))


if __name__=='__main__': main()
