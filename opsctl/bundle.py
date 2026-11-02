"""Embed the readable, reviewed deployment runner into the single SSH artifact."""
import argparse
import ast
import base64
import hashlib
import pathlib
import re

parser = argparse.ArgumentParser()
parser.add_argument('directory', type=pathlib.Path)
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
runner = (args.directory / 'deployment.py').read_bytes()
ast.parse(runner)
source = args.directory / 'bootstrap.py'
text = source.read_text(encoding='utf-8')
payload = ('# BEGIN DEPLOYMENT PAYLOAD\nDEPLOYMENT_SHA256 = "' + hashlib.sha256(runner).hexdigest()
           + '"\nDEPLOYMENT_PAYLOAD = "' + base64.b64encode(runner).decode('ascii')
           + '"\n# END DEPLOYMENT PAYLOAD')
updated, count = re.subn(r'# BEGIN DEPLOYMENT PAYLOAD\n.*?\n# END DEPLOYMENT PAYLOAD',
                        lambda _: payload, text, flags=re.S)
if count != 1:
    raise SystemExit('Expected exactly one deployment payload block')
ast.parse(updated)
if args.check:
    if updated != text:
        raise SystemExit('Embedded runner does not match deployment.py')
else:
    source.write_text(updated, encoding='utf-8', newline='\n')
print('Verified runner payload: ' + hashlib.sha256(runner).hexdigest())
