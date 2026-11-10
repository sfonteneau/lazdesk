#!/usr/bin/env python3
"""Limited lexical checks for the GUI logger (not an FPC compilation)."""
from pathlib import Path
import re
import xml.etree.ElementTree as ET
root=Path(__file__).resolve().parents[1]
client=root/'client'
text=(client/'kvm_view_form.pas').read_text()
logger=(client/'kvm_client_log.pas').read_text()
lpr=(client/'LazDeskClient.lpr').read_text()
assert not re.search(r'\bWriteLn\s*\(',text,re.I)
assert 'kvm_client_log' in text and 'kvm_client_log' in lpr
assert 'KvmClientLogPath' in text
assert 'EnterCriticalSection' in logger and 'LeaveCriticalSection' in logger
assert 'LAZDESK_CLIENT_LOG' in logger
assert 'GetAppConfigDir(False)' in logger
assert 'WriteBuffer' in logger
assert 'Stream.Free' in logger
assert 'UTF8String' in logger
assert '<IsPartOfProject Value="True" />' in (client/'LazDeskClient.lpi').read_text()
ET.parse(client/'LazDeskClient.lpi')
print('OK: GUI log, no WriteLn in the client, valid project XML')
