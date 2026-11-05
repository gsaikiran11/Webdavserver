#!/usr/bin/env python3
import os, json, pathlib, shutil, subprocess, zipfile, mimetypes, urllib.parse, socket
from http.server import BaseHTTPRequestHandler, HTTPServer
import threading
import re

BASE = pathlib.Path.home() / "webdav-manager"
STATIC = BASE / "static"
CONFIG_FILE = BASE / "config.json"

default_config = {
    "mobile_path": "/storage/emulated/0",
    "server_mode": "mobile",
    "listen_addr": "0.0.0.0",
    "listen_port": "8080",
    "tailscale_ip": "100.111.156.54",
    "wd_auth": {"user": "admin", "pass": "admin123"},
    "router_ftp": {"host": "", "user": "", "pass": "", "port": "21"},
    "ui_type": "google_drive",
    "theme": "light",
    "icon_pack": "material",
    "features": {"preview": True, "search": True, "player": True, "pdf": True, "details": True, "right_panel": True}
}

def load_config():
    if CONFIG_FILE.exists():
        try:
            c = json.loads(CONFIG_FILE.read_text())
            for k,v in default_config.items():
                if k not in c: c[k]=v
            return c
        except:
            return default_config.copy()
    return default_config.copy()

def save_config(cfg):
    try:
        CONFIG_FILE.write_text(json.dumps(cfg, indent=2))
    except Exception as e:
        print(f"Save config failed: {e}")

config = load_config()

# ---------- TAILSCALE FIX - WORKS WITHOUT ROOT, NO ip addr PERMISSION NEEDED ----------
def get_tailscale():
    ip=""; status="disconnected"; url=""; connected=False
    port = int(str(config.get('listen_port','8080')).strip() or 8080)
    
    # Known IPs - your IP + last saved
    KNOWN_IPS = [
        config.get('tailscale_ip','').strip(),
        "100.111.156.54",
    ]
    KNOWN_IPS = [x for x in dict.fromkeys(KNOWN_IPS) if x and x.startswith("100.")]

    # METHOD 1: If Tailscale App is ON, we CAN connect to our own 100.x IP (same device)
    # If OFF, connect_ex fails -> we know it's OFF
    for test_ip in KNOWN_IPS:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(1.2)
            result = s.connect_ex((test_ip, port))
            s.close()
            if result == 0:
                ip = test_ip
                status = "connected"
                connected = True
                print(f"[TS] ON - reachable {test_ip}:{port}")
                break
            else:
                print(f"[TS] {test_ip}:{port} unreachable code={result}")
        except Exception as e:
            print(f"[TS] Check {test_ip} error: {e}")
            continue

    # METHOD 2: Socket source trick - no permission needed
    if not ip:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.settimeout(1)
            s.connect(("100.100.100.100", 53))
            local = s.getsockname()[0]
            s.close()
            if local.startswith("100."):
                ip = local
                status = "connected"
                connected = True
                print(f"[TS] Found via socket src: {ip}")
        except Exception as e:
            print(f"[TS] Socket trick failed: {e}")

    # METHOD 3: Try tailscale binary if exists (Termux version)
    if not ip:
        try:
            for bin_path in ["tailscale", "/data/data/com.termux/files/usr/bin/tailscale"]:
                try:
                    r = subprocess.run([bin_path, "ip", "-4"], capture_output=True, text=True, timeout=2)
                    if r.returncode==0 and r.stdout.strip():
                        for line in r.stdout.strip().split():
                            if line.strip().startswith("100."):
                                ip=line.strip(); status="connected"; connected=True
                                print(f"[TS] Found via binary: {ip}")
                                break
                    if ip: break
                except: continue
        except: pass

    # Final - if no IP reachable, Tailscale is OFF
    if not ip:
        status="disconnected"
        connected=False
        url=""
        print(f"[TS] OFF - no 100.x reachable")
    else:
        url=f"http://{ip}:{port}"
        # Save working IP for next check
        if ip != config.get('tailscale_ip'):
            config['tailscale_ip']=ip
            save_config(config)

    print(f"[TS Final] ip={ip} status={status} connected={connected}")
    return {"ip":ip,"status":status,"url":url,"connected":connected}

def list_local(path):
    p=pathlib.Path(path)
    if not p.exists(): return None
    out=[]
    try:
        for item in p.iterdir():
            try:
                stat=item.stat()
                out.append({"Name":item.name,"IsDir":item.is_dir(),"Size":stat.st_size if item.is_file() else 0,"ModTime":stat.st_mtime})
            except: continue
    except Exception as e:
        print(f"list error {path}: {e}")
    return out

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed=urllib.parse.urlparse(self.path)
        path=parsed.path
        qs=urllib.parse.parse_qs(parsed.query)
        
        def cors_headers():
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
            self.send_header('Access-Control-Allow-Headers', '*')
        
        if self.path.startswith('/api/'):
            if path=='/api/config':
                data=json.dumps(load_config()).encode()
                self.send_response(200); cors_headers(); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data); return
            elif path=='/api/tailscale':
                info=get_tailscale()
                data=json.dumps(info).encode()
                self.send_response(200); cors_headers(); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data); return
            elif path=='/api/ls':
                local=qs.get('local',[None])[0]
                if local:
                    res=list_local(local)
                    if res is None: 
                        data=json.dumps({"error":"Not found"}).encode()
                        self.send_response(404); cors_headers(); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(data)
                    else:
                        data=json.dumps(res).encode()
                        self.send_response(200); cors_headers(); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(data)
                    return
            elif path in ('/api/stream','/api/download'):
                local=qs.get('local',[None])[0]
                if local:
                    p=pathlib.Path(local)
                    if not p.exists():
                        self.send_response(404); cors_headers(); self.end_headers(); self.wfile.write(b'Not found'); return
                    mime,_=mimetypes.guess_type(str(p))
                    self.send_response(200); cors_headers(); self.send_header('Content-Type', mime or 'application/octet-stream')
                    if 'download' in path: self.send_header('Content-Disposition', f'attachment; filename="{p.name}"')
                    self.send_header('Content-Length', str(p.stat().st_size))
                    self.end_headers()
                    with open(p,'rb') as f: shutil.copyfileobj(f, self.wfile)
                    return
            elif path=='/api/read':
                local=qs.get('local',[None])[0]
                if local:
                    try:
                        txt=pathlib.Path(local).read_text(errors='ignore')[:1000000]
                        data=json.dumps({"content":txt}).encode()
                        self.send_response(200); cors_headers(); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(data)
                    except Exception as e:
                        data=json.dumps({"error":str(e)}).encode()
                        self.send_response(500); cors_headers(); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(data)
                    return
        
        # Static
        if path=='/' or path=='/index.html':
            fp=STATIC/'index.html'
        elif path=='/config' or path=='/config.html':
            fp=STATIC/'config.html'
        else:
            fp=STATIC / path.lstrip('/')
        mime,_=mimetypes.guess_type(str(fp))
        mime=mime or 'application/octet-stream'
        if fp.exists() and fp.is_file():
            self.send_response(200); cors_headers(); self.send_header('Content-Type', mime); self.end_headers()
            self.wfile.write(fp.read_bytes())
        else:
            self.send_response(404); cors_headers(); self.end_headers(); self.wfile.write(b'Not found')

    def do_POST(self):
        parsed=urllib.parse.urlparse(self.path)
        path=parsed.path
        length=int(self.headers.get('Content-Length',0))
        body=self.rfile.read(length) if length else b''
        try: j=json.loads(body.decode()) if body else {}
        except: j={}
        
        def send_json(obj, code=200):
            data=json.dumps(obj).encode()
            self.send_response(code); self.send_header('Content-Type','application/json'); self.send_header('Access-Control-Allow-Origin','*'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
        
        if path=='/api/config':
            global config
            for k,v in j.items(): config[k]=v
            save_config(config)
            send_json({"ok":True})
        elif path=='/api/mkdir':
            if 'local' in j: pathlib.Path(j['local']).mkdir(parents=True, exist_ok=True)
            send_json({"ok":True})
        elif path=='/api/delete':
            if 'local' in j:
                p=pathlib.Path(j['local'])
                if p.is_dir(): shutil.rmtree(str(p), ignore_errors=True)
                else: p.unlink(missing_ok=True)
            send_json({"ok":True})
        elif path=='/api/rename':
            if 'src_local' in j: pathlib.Path(j['src_local']).rename(j['dst_local'])
            send_json({"ok":True})
        elif path=='/api/zip':
            try:
                base=pathlib.Path(j['local_base']); files=j['files']; zip_name=j['zip_name']; zip_path=base/zip_name
                with zipfile.ZipFile(str(zip_path),'w') as zf:
                    for fn in files:
                        fp=base/fn
                        if fp.is_dir():
                            for sub in fp.rglob('*'): zf.write(str(sub), str(sub.relative_to(base)))
                        else: zf.write(str(fp), fp.name)
                send_json({"ok":True})
            except Exception as e: send_json({"error":str(e)},500)
        elif path=='/api/unzip':
            try:
                p=pathlib.Path(j['local_path'])
                with zipfile.ZipFile(str(p),'r') as zf: zf.extractall(str(p.parent))
                send_json({"ok":True})
            except Exception as e: send_json({"error":str(e)},500)
        elif path=='/api/upload':
            parsed_q=urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            local=parsed_q.get('local',[None])[0]
            fname=self.headers.get('X-File-Name','upload.bin')
            fname="".join(c for c in fname if c.isalnum() or c in "._- ")[:100]
            if local and body:
                (pathlib.Path(local)/fname).write_bytes(body)
                send_json({"ok":True})
            else: send_json({"error":"Need local"},400)
        else:
            send_json({"ok":True})

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', '*')
        self.end_headers()

    def log_message(self, format, *args): return

if __name__=='__main__':
    cfg=load_config()
    addr="0.0.0.0"
    port=int(str(cfg.get('listen_port','8080')).strip() or 8080)
    print(f"[*] Forced listen_addr to {addr} for Tailscale same-mobile support")
    print(f"[*] Starting on {addr}:{port}")
    ts=get_tailscale()
    print(f"[*] Tailscale: {ts}")
    print(f"[*] Local: http://127.0.0.1:{port}/")
    if ts['ip']:
        print(f"[*] Tailscale URL (same device + other): http://{ts['ip']}:{port}/")
    else:
        print(f"[*] Tailscale OFF")
    HTTPServer.allow_reuse_address = True
    server=HTTPServer((addr,port), Handler)
    try:
        server.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    except: pass
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped")
