#!/usr/bin/env python3
"""TLS fixtures for the ACTUAL mORMot probe built from test_tls_probe.lpi.
--self-test validates only the Python harness, NOT the Pascal implementation.
Test private keys exist only in a temporary directory; never production secrets.
"""
from __future__ import annotations
import argparse
import base64
import datetime as dt
import hashlib
import ipaddress
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from kvm_ws import WS

def fixtures(root):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes,serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID,ExtendedKeyUsageOID
    now=dt.datetime.now(dt.timezone.utc)
    def key():return rsa.generate_private_key(public_exponent=65537,key_size=2048)
    ca_key=key(); ca_name=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'LazDesk temporary test CA')])
    ca=(x509.CertificateBuilder().subject_name(ca_name).issuer_name(ca_name).public_key(ca_key.public_key())
        .serial_number(x509.random_serial_number()).not_valid_before(now-dt.timedelta(days=1)).not_valid_after(now+dt.timedelta(days=2))
        .add_extension(x509.BasicConstraints(ca=True,path_length=0),True)
        .add_extension(x509.KeyUsage(True,False,False,False,False,True,True,None,None),True)
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(ca_key.public_key()),False)
        .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_key.public_key()),False).sign(ca_key,hashes.SHA256()))
    (root/'ca.pem').write_bytes(ca.public_bytes(serialization.Encoding.PEM))
    for name,expired,mismatch in [('valid',False,False),('expired',True,False),('wrong-name',False,True)]:
        k=key();subject=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'wrong.invalid' if mismatch else 'localhost')])
        san=[x509.DNSName('wrong.invalid')] if mismatch else [x509.DNSName('localhost'),x509.IPAddress(ipaddress.ip_address('127.0.0.1'))]
        leaf=(x509.CertificateBuilder().subject_name(subject).issuer_name(ca.subject).public_key(k.public_key())
              .serial_number(x509.random_serial_number()).not_valid_before(now-dt.timedelta(days=2))
              .not_valid_after(now-dt.timedelta(days=1) if expired else now+dt.timedelta(days=1))
              .add_extension(x509.BasicConstraints(ca=False,path_length=None),True)
              .add_extension(x509.SubjectAlternativeName(san),False)
              .add_extension(x509.KeyUsage(True,False,True,False,False,False,False,None,None),True)
              .add_extension(x509.SubjectKeyIdentifier.from_public_key(k.public_key()),False)
              .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_key.public_key()),False)
              .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]),False).sign(ca_key,hashes.SHA256()))
        (root/(name+'.pem')).write_bytes(leaf.public_bytes(serialization.Encoding.PEM))
        kp=root/(name+'.key');kp.write_bytes(k.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()));os.chmod(kp,0o600)
    other_key=key()
    other=(x509.CertificateBuilder().subject_name(ca_name).issuer_name(ca_name).public_key(other_key.public_key())
        .serial_number(x509.random_serial_number()).not_valid_before(now-dt.timedelta(days=1)).not_valid_after(now+dt.timedelta(days=2))
        .add_extension(x509.BasicConstraints(ca=True,path_length=0),True)
        .add_extension(x509.KeyUsage(True,False,False,False,False,True,True,None,None),True)
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(other_key.public_key()),False)
        .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(other_key.public_key()),False).sign(other_key,hashes.SHA256()))
    (root/'wrong-ca.pem').write_bytes(other.public_bytes(serialization.Encoding.PEM))

class Fixture:
    def __init__(self,root,leaf):
        self.ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);self.ctx.minimum_version=ssl.TLSVersion.TLSv1_2
        self.ctx.load_cert_chain(root/(leaf+'.pem'),root/(leaf+'.key'))
        self.listener=socket.socket();self.listener.bind(('127.0.0.1',0));self.listener.listen(1);self.listener.settimeout(8)
        self.port=self.listener.getsockname()[1];self.error=None
        self.thread=threading.Thread(target=self.run,daemon=True);self.thread.start()
    def run(self):
        try:
            raw,_=self.listener.accept();raw.settimeout(5)
            with self.ctx.wrap_socket(raw,server_side=True) as sock:
                request=b''
                while b'\r\n\r\n' not in request:
                    chunk=sock.recv(4096)
                    if not chunk:return
                    request+=chunk
                    if len(request)>16384:raise ValueError('oversized upgrade')
                headers={k.strip().lower():v.strip() for k,v in
                         (line.split(':',1) for line in request.decode('ascii').split('\r\n')[1:] if ':' in line)}
                accept=base64.b64encode(hashlib.sha1((headers['sec-websocket-key']+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
                reply=('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                       f'Sec-WebSocket-Accept: {accept}\r\nSec-WebSocket-Protocol: lazdesk9\r\n\r\n')
                sock.sendall(reply.encode('ascii'))
                if sock.recv(4096):sock.sendall(b'\x88\x02\x03\xe8')
        except (ssl.SSLError,ConnectionError,TimeoutError,OSError):pass
        except Exception as exc:self.error=exc
        finally:self.listener.close()
    def join(self):
        self.thread.join(10)
        if self.thread.is_alive():raise RuntimeError('TLS fixture did not stop')
        if self.error:raise self.error

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--probe',type=Path);p.add_argument('--self-test',action='store_true')
    a=p.parse_args()
    if not a.self_test and (not a.probe or not a.probe.is_file()):
        print('NOT RUN: compile test_tls_probe.lpi and provide --probe (actual mORMot client)',file=sys.stderr);return 2
    with tempfile.TemporaryDirectory(prefix='lazdesk-tls-') as directory:
        root=Path(directory);fixtures(root)
        for leaf,ca,ok in [('valid','ca.pem',True),('valid','wrong-ca.pem',False),('wrong-name','ca.pem',False),('expired','ca.pem',False)]:
            server=Fixture(root,leaf)
            try:
                if a.self_test:
                    try:
                        with WS('127.0.0.1',server.port,tls=True,ca=str(root/ca)):pass
                        accepted=True
                    except ssl.SSLCertVerificationError:accepted=False
                else:
                    result=subprocess.run([str(a.probe.resolve()),'127.0.0.1',str(server.port),str(root/ca)],capture_output=True,text=True,timeout=10)
                    if result.returncode not in (0,1):raise RuntimeError(f'Unexpected probe exit {result.returncode}: {result.stderr}')
                    accepted=result.returncode==0
                assert accepted==ok,(leaf,ca,accepted,ok)
            finally:server.join()
            print('PASS', 'PYTHON HARNESS ONLY' if a.self_test else 'mORMot client',leaf,ca,'accepted' if ok else 'rejected')
    return 0
if __name__=='__main__':sys.exit(main())
