"""Explicit draft import/export/activation; credentials and tickets come from the environment."""
import argparse
import json
import os
from datetime import datetime
from pathlib import Path
from uuid import UUID

import psycopg

from kc.configuration import export_package,import_package
from kc.ids import uuid7
from kc.session import tenant_transaction


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    commands=parser.add_subparsers(dest='command',required=True)
    load=commands.add_parser('import'); load.add_argument('file',type=Path); load.add_argument('--proposal',type=UUID)
    export=commands.add_parser('export'); export.add_argument('revision',type=UUID); export.add_argument('file',type=Path)
    approve=commands.add_parser('activate'); approve.add_argument('revision',type=UUID)
    approve.add_argument('--effective-from',type=datetime.fromisoformat,required=True)
    approve.add_argument('--effective-to',type=datetime.fromisoformat)
    approve.add_argument('--note',required=True)
    args=parser.parse_args()
    with psycopg.connect(os.environ['KC_RUNTIME_DSN']) as conn:
        with tenant_transaction(conn,os.environ['KC_SESSION_TICKET']):
            if args.command=='import':
                print(import_package(conn,json.loads(args.file.read_text(encoding='utf-8')),args.proposal))
            elif args.command=='export':
                result=export_package(conn,args.revision)
                args.file.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
            else:
                if args.effective_from.tzinfo is None or (args.effective_to and args.effective_to.tzinfo is None):
                    raise ValueError('Effective times require an explicit timezone offset')
                conn.execute('SELECT governance.approve_and_activate(%s,%s,%s,%s,%s,%s)',
                    (args.revision,uuid7(),uuid7(),args.effective_from,args.effective_to,args.note))
                print('Approved and scheduled',args.revision)


if __name__=='__main__': main()
