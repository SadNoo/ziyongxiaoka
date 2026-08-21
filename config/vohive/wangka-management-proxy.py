#!/usr/bin/python3
"""Protected VoHive reverse proxy and narrowly scoped device settings portal."""

from __future__ import annotations

import argparse
import http.client
import json
import os
import secrets
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Optional
from urllib.parse import urlsplit


BACKEND_HOST = os.environ.get("WANGKA_VOHIVE_HOST", "127.0.0.1")
BACKEND_PORT = int(os.environ.get("WANGKA_VOHIVE_PORT", "17575"))
STATE_DIR = Path(os.environ.get("WANGKA_STATE_DIR", "/var/lib/wangka-management"))
STATE_FILE = STATE_DIR / "state.json"
LAST_EPOCH_FILE = STATE_DIR / "last-trusted-epoch"
SSH_USER = "user"
HOTSPOT_CONNECTION = "hotspot"
MAX_REQUEST_BODY = 32 * 1024
HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}


INJECT_SCRIPT = r"""
<style id="wangka-shell-style">
.wangka-system-link{display:flex;align-items:center;gap:10px;height:44px;padding:0 20px;margin:4px 8px;border-radius:10px;color:inherit;cursor:pointer;font-size:14px}.wangka-system-link:hover{background:rgba(91,91,214,.12);color:#5b5bd6}.wangka-system-link b{font-size:18px}.wangka-system-link span{white-space:nowrap}
</style>
<script id="wangka-shell-script">
(() => {
  const systemUrl = '/wangka/system-device';
  function hardenAndLink() {
    document.querySelectorAll('button').forEach((button) => {
      if ((button.textContent || '').includes('拒绝并卸载')) button.remove();
    });
    document.querySelectorAll('p').forEach((node) => {
      if ((node.textContent || '').includes('拒绝，本软件将立即触发自毁')) {
        node.textContent = '如不同意，请直接关闭页面；设备程序、配置和短信数据不会被删除。';
      }
    });
    document.querySelectorAll('.sidebar-menu').forEach((menu) => {
      if (menu.querySelector('[data-wangka-system-link]')) return;
      const item = document.createElement('li');
      item.className = 'wangka-system-link';
      item.dataset.wangkaSystemLink = '1';
      item.innerHTML = '<b>⚙</b><span>系统设备</span>';
      item.addEventListener('click', () => window.location.assign(systemUrl));
      menu.appendChild(item);
    });
  }
  const observer = new MutationObserver(hardenAndLink);
  observer.observe(document.documentElement, { childList: true, subtree: true });
  hardenAndLink();
  async function enforceOnboarding() {
    if (location.pathname.startsWith('/wangka/')) return;
    const token = localStorage.getItem('token') || '';
    if (!token || document.querySelector('.disclaimer-overlay')) return;
    try {
      const response = await fetch('/wangka/api/status', {
        headers: { Authorization: `Bearer ${token}` }, cache: 'no-store'
      });
      if (!response.ok) return;
      const status = await response.json();
      if (!status.initialized) window.location.replace(systemUrl);
    } catch (_) {}
  }
  setInterval(enforceOnboarding, 1200);
  enforceOnboarding();
})();
</script>
"""


SYSTEM_DEVICE_HTML = r"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>系统设备 · VoHive</title>
<style>
:root{color-scheme:light dark;--bg:#f5f6fa;--card:#fff;--text:#17181c;--muted:#687083;--line:#e5e7ef;--brand:#5b5bd6;--ok:#159a67;--warn:#b7791f}*{box-sizing:border-box}body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:var(--bg);color:var(--text)}header{height:58px;background:var(--card);border-bottom:1px solid var(--line);display:flex;align-items:center;justify-content:space-between;padding:0 22px;position:sticky;top:0;z-index:2}header strong{font-size:18px}a{color:var(--brand);text-decoration:none}.wrap{max-width:1080px;margin:24px auto;padding:0 16px 48px}.banner,.card{background:var(--card);border:1px solid var(--line);border-radius:16px;box-shadow:0 8px 28px rgba(25,28,45,.05)}.banner{padding:18px 20px;margin-bottom:16px;border-left:5px solid var(--warn)}.banner.done{border-left-color:var(--ok)}.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:14px}.card{padding:20px;margin-bottom:16px}.grid .card{margin:0}.label{font-size:12px;color:var(--muted);margin-bottom:7px}.value{font-weight:700}.section-title{font-size:18px;margin:0 0 5px}.section-desc{color:var(--muted);font-size:13px;margin:0 0 18px}.row{display:grid;grid-template-columns:1fr 1fr;gap:14px}.field{margin-bottom:14px}label{display:block;font-size:13px;font-weight:650;margin-bottom:7px}input{width:100%;height:42px;padding:0 12px;border:1px solid var(--line);border-radius:10px;background:transparent;color:inherit;font-size:15px}.targets{display:flex;gap:16px;flex-wrap:wrap;margin:6px 0 16px}.targets label{font-weight:500}.targets input{width:auto;height:auto;margin-right:5px}.actions{display:flex;gap:10px;flex-wrap:wrap}.button{border:0;border-radius:10px;padding:11px 17px;font-weight:700;cursor:pointer;background:#ececfb;color:#3e3ea8}.button.primary{background:var(--brand);color:#fff}.button:disabled{opacity:.5;cursor:not-allowed}.button.small{padding:6px 9px;margin-top:10px;font-size:12px}.notice{padding:12px 14px;border-radius:10px;background:#f0f1ff;color:#3e3ea8;font-size:13px;margin:12px 0;white-space:pre-wrap}.error{background:#fff0f0;color:#b42318}.network{display:flex;gap:12px}.mode{flex:1;border:1px solid var(--line);border-radius:12px;padding:15px}.mode.active{border-color:var(--ok)}.pill{display:inline-block;font-size:11px;padding:3px 8px;border-radius:99px;background:#eaf8f2;color:#087a50}.pill.wait{background:#fff5df;color:#9a6700}@media(max-width:820px){.grid{grid-template-columns:1fr 1fr}.row{grid-template-columns:1fr}.network{flex-direction:column}}@media(max-width:520px){.grid{grid-template-columns:1fr}header{padding:0 14px}}
@media(prefers-color-scheme:dark){:root{--bg:#101014;--card:#18181f;--text:#f2f2f6;--muted:#999aab;--line:#30303b}.notice{background:#262640}.error{background:#401f22}}
</style>
</head>
<body>
<header><strong>VoHive · 系统设备</strong><a href="/">返回短信管理</a></header>
<main class="wrap">
  <div id="banner" class="banner"><strong>正在读取设备状态…</strong></div>
  <section class="grid">
    <div class="card"><div class="label">SSH 账号</div><div class="value">user</div></div>
    <div class="card"><div class="label">VoHive 账号</div><div class="value">user</div></div>
    <div class="card"><div class="label">Wi-Fi</div><div id="ssidValue" class="value">Wangka-UFI103S</div></div>
    <div class="card"><div class="label">系统时间</div><div id="timeValue" class="value">正在校时…</div><button id="syncTime" class="button small">用本机时间校准</button></div>
  </section>
  <section class="card" style="margin-top:16px">
    <h2 class="section-title">首次初始化与密码</h2>
    <p class="section-desc">默认可把同一个新密码应用到 SSH、Wi-Fi 和 VoHive；取消勾选即可分别修改。</p>
    <div class="targets">
      <label><input id="targetSsh" type="checkbox" checked>SSH</label>
      <label><input id="targetWifi" type="checkbox" checked>Wi-Fi</label>
      <label><input id="targetVohive" type="checkbox" checked>VoHive</label>
    </div>
    <div class="row">
      <div class="field"><label for="currentPassword">当前 VoHive 密码</label><input id="currentPassword" type="password" autocomplete="current-password" placeholder="修改 VoHive 时填写"></div>
      <div class="field"><label for="wifiSsid">Wi-Fi 名称</label><input id="wifiSsid" maxlength="32" value="Wangka-UFI103S"></div>
    </div>
    <div class="row">
      <div class="field"><label for="newPassword">新密码</label><input id="newPassword" type="text" autocomplete="new-password" placeholder="8～63 位可打印字符"></div>
      <div class="field"><label for="confirmPassword">确认新密码</label><input id="confirmPassword" type="text" autocomplete="new-password"></div>
    </div>
    <div class="actions">
      <button id="generate" class="button">生成新密码</button>
      <button id="copy" class="button" disabled>复制新密码</button>
      <button id="apply" class="button primary">保存并应用</button>
    </div>
    <div id="message" class="notice" hidden></div>
  </section>
  <section class="card">
    <h2 class="section-title">USB 网络方向</h2>
    <p class="section-desc">开关位置已纳入系统设备页；host-uplink 后端将在批次 2 安装后启用。</p>
    <div class="network">
      <div class="mode active"><span class="pill">当前</span><h3>device-uplink</h3><p class="section-desc">设备通过 SIM/LTE 向 USB/Wi-Fi 客户端共享网络。</p></div>
      <div class="mode"><span class="pill wait">待安装</span><h3>host-uplink</h3><p class="section-desc">Debian 通过 USB 借用 Mac/PC 网络。</p><button class="button" disabled>批次 2 后启用</button></div>
    </div>
  </section>
  <section class="card">
    <h2 class="section-title">VoHive 维护保护</h2>
    <p class="section-desc">网页卸载接口已被服务端拒绝。修复和重新登记只允许通过本机受控维护工具执行。</p>
    <div id="serviceValue" class="notice">正在检查…</div>
  </section>
</main>
<script>
const $ = (id) => document.getElementById(id);
const token = () => localStorage.getItem('token') || '';
async function api(path, options={}) {
  options.headers = Object.assign({'Authorization': `Bearer ${token()}`}, options.headers || {});
  if (options.body) options.headers['Content-Type'] = 'application/json';
  const response = await fetch(path, options);
  const data = await response.json().catch(() => ({}));
  if (response.status === 401) { localStorage.removeItem('token'); location.href='/#/login'; throw new Error('登录已失效'); }
  if (!response.ok) throw new Error(data.message || data.error || `请求失败 ${response.status}`);
  return data;
}
function show(message, error=false) { const box=$('message'); box.hidden=false; box.textContent=message; box.className='notice'+(error?' error':''); }
async function syncClock() {
  const timezone=Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
  const result=await api('/wangka/api/time',{method:'POST',body:JSON.stringify({client_epoch:Math.floor(Date.now()/1000),timezone})});
  $('timeValue').textContent=`${result.system_time}\n${result.timezone}`;
  return result;
}
async function load() {
  if (!token()) { location.href='/#/login'; return; }
  try {
    const status=await api('/wangka/api/status');
    $('ssidValue').textContent=status.wifi_ssid || 'Wangka-UFI103S';
    $('wifiSsid').value=status.wifi_ssid || 'Wangka-UFI103S';
    $('timeValue').textContent=`${status.system_time}\n${status.timezone}`;
    $('serviceValue').textContent=`VoHive：${status.vohive_active?'运行中':'未运行'}\n卸载接口：已阻止\n管理代理：运行中`;
    const banner=$('banner');
    if(status.initialized){ banner.className='banner done'; banner.innerHTML='<strong>初始化已完成</strong><div class="section-desc">仍可在此分别修改三项密码。</div>'; }
    else { banner.innerHTML='<strong>必须完成首次初始化</strong><div class="section-desc">请修改三项默认密码，或生成一个新密码统一应用。</div>'; ['targetSsh','targetWifi','targetVohive'].forEach(id=>{$(id).checked=true;$(id).disabled=true;}); $('currentPassword').value='123456789'; }
  } catch(e) { show(e.message,true); }
  try { await syncClock(); } catch(_) {}
}
$('syncTime').onclick=async()=>{try{await syncClock();show('系统时间已用当前浏览器校准并持久保存。');}catch(e){show(e.message,true)}};
$('generate').onclick=async()=>{try{const r=await api('/wangka/api/generate',{method:'POST'});$('newPassword').value=r.password;$('confirmPassword').value=r.password;$('copy').disabled=false;show('新密码已生成。请先复制保存，再点击“保存并应用”。');}catch(e){show(e.message,true)}};
$('copy').onclick=async()=>{const value=$('newPassword').value;if(!value)return;await navigator.clipboard.writeText(value);show('新密码已复制。')} ;
$('apply').onclick=async()=>{
  const targets=['ssh','wifi','vohive'].filter(x=>$('target'+x[0].toUpperCase()+x.slice(1)).checked);
  const password=$('newPassword').value;
  if(!targets.length){show('至少选择一个修改目标。',true);return}
  if(password!==$('confirmPassword').value){show('两次输入的新密码不一致。',true);return}
  $('apply').disabled=true;
  try{
    await api('/wangka/api/credentials',{method:'POST',body:JSON.stringify({targets,new_password:password,confirm_password:$('confirmPassword').value,current_vohive_password:$('currentPassword').value,wifi_ssid:$('wifiSsid').value})});
    let text='修改成功。请保存新密码。';
    if(targets.includes('wifi')) text+='\nWi-Fi 将在约 8 秒后重启，请使用新密码重新连接。';
    if(targets.includes('vohive')){text+='\nVoHive 登录已更新，请使用 user 和新密码重新登录。';localStorage.removeItem('token')}
    show(text);
  }catch(e){show(e.message,true)}finally{$('apply').disabled=false}
};
load();
</script>
</body></html>"""


def default_state() -> dict[str, Any]:
    return {"initialized": False, "generation": 0, "uplink_mode": "device-uplink"}


def load_state() -> dict[str, Any]:
    try:
        loaded = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        state = default_state()
        if isinstance(loaded, dict):
            state.update(loaded)
        return state
    except (OSError, ValueError):
        return default_state()


def save_state(state: dict[str, Any]) -> None:
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = STATE_DIR / f".state.{os.getpid()}.{threading.get_ident()}"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(state, stream, ensure_ascii=False, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, STATE_FILE)
        os.chmod(STATE_FILE, 0o600)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def validate_password(password: str) -> None:
    if not 8 <= len(password.encode("utf-8")) <= 63:
        raise ValueError("新密码必须为 8～63 字节")
    if ":" in password or any(ord(char) < 32 or ord(char) == 127 for char in password):
        raise ValueError("新密码不能包含冒号或控制字符")


def validate_ssid(ssid: str) -> None:
    length = len(ssid.encode("utf-8"))
    if not 1 <= length <= 32 or any(ord(char) < 32 for char in ssid):
        raise ValueError("Wi-Fi 名称必须为 1～32 字节且不能包含控制字符")


def validate_client_epoch(value: Any) -> int:
    if isinstance(value, bool):
        raise ValueError("客户端时间无效")
    try:
        epoch = int(value)
    except (TypeError, ValueError):
        raise ValueError("客户端时间无效") from None
    if not 1735689600 <= epoch <= 4102444800:
        raise ValueError("客户端时间超出允许范围")
    return epoch


def validate_timezone(value: Any) -> str:
    timezone = str(value or "UTC").strip()
    if (
        not timezone
        or timezone.startswith("/")
        or ".." in Path(timezone).parts
        or any(not (char.isalnum() or char in "/_+-") for char in timezone)
    ):
        raise ValueError("时区无效")
    target = Path("/usr/share/zoneinfo") / timezone
    if not target.is_file():
        raise ValueError("设备不支持该时区")
    return timezone


def current_timezone() -> str:
    try:
        zoneinfo = Path("/usr/share/zoneinfo").resolve()
        localtime = Path("/etc/localtime").resolve()
        return str(localtime.relative_to(zoneinfo))
    except (OSError, ValueError):
        pass
    try:
        value = Path("/etc/timezone").read_text(encoding="utf-8").strip()
        return value or "UTC"
    except OSError:
        return "UTC"


def persist_trusted_epoch(epoch: int) -> None:
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = STATE_DIR / f".epoch.{os.getpid()}.{threading.get_ident()}"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="ascii") as stream:
            stream.write(f"{epoch}\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, LAST_EPOCH_FILE)
        os.chmod(LAST_EPOCH_FILE, 0o600)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def system_time_payload() -> dict[str, Any]:
    return {
        "system_time": time.strftime("%Y-%m-%d %H:%M:%S %Z"),
        "system_epoch": int(time.time()),
        "timezone": current_timezone(),
        "ntp_synchronized": Path("/run/systemd/timesync/synchronized").exists(),
        "persistent_clock": LAST_EPOCH_FILE.exists(),
    }


def run_command(args: list[str], *, input_text: Optional[str] = None) -> str:
    result = subprocess.run(
        args,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=20,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"系统操作失败：{args[0]}")
    return result.stdout.strip()


def shadow_hash(username: str) -> str:
    with open("/etc/shadow", "r", encoding="utf-8") as shadow:
        for line in shadow:
            fields = line.rstrip("\n").split(":")
            if fields[0] == username:
                return fields[1]
    raise RuntimeError("SSH 用户不存在")


def set_ssh_password(password: str) -> None:
    run_command(["/usr/sbin/chpasswd"], input_text=f"{SSH_USER}:{password}\n")


def restore_ssh_hash(password_hash: str) -> None:
    run_command(["/usr/sbin/chpasswd", "-e"], input_text=f"{SSH_USER}:{password_hash}\n")


def nm_value(property_name: str) -> str:
    return run_command(
        ["/usr/bin/nmcli", "-g", property_name, "connection", "show", HOTSPOT_CONNECTION]
    ).splitlines()[0]


def set_wifi(ssid: str, password: str) -> None:
    run_command(
        [
            "/usr/bin/nmcli",
            "connection",
            "modify",
            HOTSPOT_CONNECTION,
            "802-11-wireless.ssid",
            ssid,
            "802-11-wireless-security.psk",
            password,
        ]
    )


def schedule_wifi_restart() -> None:
    def restart() -> None:
        time.sleep(8)
        try:
            run_command(["/usr/bin/nmcli", "connection", "down", HOTSPOT_CONNECTION])
            run_command(["/usr/bin/nmcli", "connection", "up", HOTSPOT_CONNECTION])
        except (OSError, RuntimeError, subprocess.TimeoutExpired):
            pass

    threading.Thread(target=restart, name="wifi-restart", daemon=True).start()


def backend_request(
    method: str,
    path: str,
    *,
    authorization: str = "",
    payload: Optional[dict[str, Any]] = None,
    timeout: int = 15,
) -> tuple[int, bytes, list[tuple[str, str]]]:
    body = None
    headers = {"Accept": "application/json"}
    if authorization:
        headers["Authorization"] = authorization
    if payload is not None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    connection = http.client.HTTPConnection(BACKEND_HOST, BACKEND_PORT, timeout=timeout)
    try:
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        return response.status, response.read(), response.getheaders()
    finally:
        connection.close()


def authenticated(authorization: str) -> bool:
    if not authorization.startswith("Bearer "):
        return False
    try:
        status, _, _ = backend_request(
            "GET", "/api/system/info", authorization=authorization, timeout=8
        )
        return status == 200
    except OSError:
        return False


def inject_html(body: bytes) -> bytes:
    marker = b"</body>"
    if b'id="wangka-shell-script"' in body:
        return body
    injection = INJECT_SCRIPT.encode("utf-8")
    if marker in body:
        return body.replace(marker, injection + marker, 1)
    return body + injection


class WangkaHandler(BaseHTTPRequestHandler):
    server_version = "WangkaManagement/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, message: str, *args: Any) -> None:
        # Do not log request bodies or credentials.
        print(f"management-proxy {self.client_address[0]} {message % args}", flush=True)

    def send_json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def read_json(self) -> dict[str, Any]:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as exc:
            raise ValueError("无效请求长度") from exc
        if length <= 0 or length > MAX_REQUEST_BODY:
            raise ValueError("请求内容为空或过大")
        try:
            parsed = json.loads(self.rfile.read(length))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ValueError("请求不是有效 JSON") from exc
        if not isinstance(parsed, dict):
            raise ValueError("请求必须为 JSON 对象")
        return parsed

    def authorization(self) -> str:
        return self.headers.get("Authorization", "").strip()

    def require_auth(self) -> bool:
        if authenticated(self.authorization()):
            return True
        self.send_json(401, {"status": "error", "message": "登录已失效"})
        return False

    def do_GET(self) -> None:  # noqa: N802
        self.route()

    def do_POST(self) -> None:  # noqa: N802
        self.route()

    def do_PUT(self) -> None:  # noqa: N802
        self.route()

    def do_PATCH(self) -> None:  # noqa: N802
        self.route()

    def do_DELETE(self) -> None:  # noqa: N802
        self.route()

    def route(self) -> None:
        path = urlsplit(self.path).path
        if path == "/api/system/uninstall":
            self.send_json(
                403,
                {"status": "error", "code": "disabled", "message": "网页卸载已永久禁用"},
            )
            return
        if path in {"/wangka/system-device", "/wangka/system-device/"}:
            body = SYSTEM_DEVICE_HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(body)
            return
        if path.startswith("/wangka/api/"):
            self.handle_wangka_api(path)
            return
        if path.startswith("/api/") and path != "/api/auth/login" and not load_state()["initialized"]:
            self.send_json(
                428,
                {
                    "status": "error",
                    "code": "initialization_required",
                    "message": "请先在系统设备页面完成首次初始化",
                },
            )
            return
        self.proxy_to_vohive()

    def handle_wangka_api(self, path: str) -> None:
        if not self.require_auth():
            return
        if path == "/wangka/api/status" and self.command == "GET":
            state = load_state()
            try:
                ssid = nm_value("802-11-wireless.ssid")
            except (OSError, RuntimeError, subprocess.TimeoutExpired):
                ssid = "Wangka-UFI103S"
            try:
                active = run_command(["/usr/bin/systemctl", "is-active", "vohive.service"]) == "active"
            except (OSError, RuntimeError, subprocess.TimeoutExpired):
                active = False
            self.send_json(
                200,
                {
                    "initialized": bool(state.get("initialized")),
                    "generation": int(state.get("generation", 0)),
                    "ssh_username": SSH_USER,
                    "vohive_username": "user",
                    "wifi_ssid": ssid,
                    "uplink_mode": "device-uplink",
                    "host_uplink_installed": False,
                    "vohive_active": active,
                    "uninstall_blocked": True,
                    **system_time_payload(),
                },
            )
            return
        if path == "/wangka/api/time" and self.command == "POST":
            try:
                payload = self.read_json()
                client_epoch = validate_client_epoch(payload.get("client_epoch"))
                timezone = validate_timezone(payload.get("timezone", "UTC"))
                if abs(int(time.time()) - client_epoch) > 2:
                    run_command(["/usr/bin/date", "-u", f"--set=@{client_epoch}"])
                if current_timezone() != timezone:
                    run_command(["/usr/bin/timedatectl", "set-timezone", timezone])
                    if hasattr(time, "tzset"):
                        time.tzset()
                persist_trusted_epoch(int(time.time()))
                self.send_json(200, {"status": "ok", **system_time_payload()})
            except ValueError as exc:
                self.send_json(400, {"status": "error", "message": str(exc)})
            except (OSError, RuntimeError, subprocess.TimeoutExpired):
                self.send_json(500, {"status": "error", "message": "系统校时失败"})
            return
        if path == "/wangka/api/generate" and self.command == "POST":
            self.send_json(200, {"password": secrets.token_urlsafe(18)})
            return
        if path == "/wangka/api/credentials" and self.command == "POST":
            self.handle_credentials()
            return
        self.send_json(404, {"status": "error", "message": "接口不存在"})

    def handle_credentials(self) -> None:
        try:
            payload = self.read_json()
            raw_targets = payload.get("targets")
            if not isinstance(raw_targets, list):
                raise ValueError("必须选择修改目标")
            targets = {str(item) for item in raw_targets}
            if not targets or not targets.issubset({"ssh", "wifi", "vohive"}):
                raise ValueError("修改目标无效")
            state = load_state()
            if not state.get("initialized") and targets != {"ssh", "wifi", "vohive"}:
                raise ValueError("首次初始化必须同时更新 SSH、Wi-Fi 和 VoHive")
            password = str(payload.get("new_password", ""))
            if password != str(payload.get("confirm_password", "")):
                raise ValueError("两次输入的新密码不一致")
            validate_password(password)
            ssid = str(payload.get("wifi_ssid", "Wangka-UFI103S")).strip()
            validate_ssid(ssid)
            current_vohive_password = str(payload.get("current_vohive_password", ""))
            if "vohive" in targets and not current_vohive_password:
                raise ValueError("修改 VoHive 时必须填写当前 VoHive 密码")
            # Verify state storage before making credential changes.
            save_state(state)
        except ValueError as exc:
            self.send_json(400, {"status": "error", "message": str(exc)})
            return
        except OSError:
            self.send_json(500, {"status": "error", "message": "初始化状态无法保存"})
            return

        old_shadow = ""
        old_ssid = ""
        old_psk = ""
        ssh_changed = False
        wifi_changed = False
        try:
            if "ssh" in targets:
                old_shadow = shadow_hash(SSH_USER)
                set_ssh_password(password)
                ssh_changed = True
            if "wifi" in targets:
                old_ssid = nm_value("802-11-wireless.ssid")
                old_psk = nm_value("802-11-wireless-security.psk")
                set_wifi(ssid, password)
                wifi_changed = True
            if "vohive" in targets:
                status, body, _ = backend_request(
                    "POST",
                    "/api/settings/password",
                    authorization=self.authorization(),
                    payload={
                        "old_password": current_vohive_password,
                        "new_password": password,
                        "confirm_password": password,
                    },
                )
                if status != 200:
                    try:
                        detail = json.loads(body).get("message", "VoHive 密码更新失败")
                    except (ValueError, AttributeError):
                        detail = "VoHive 密码更新失败"
                    raise RuntimeError(str(detail))
            state["generation"] = int(state.get("generation", 0)) + 1
            if targets == {"ssh", "wifi", "vohive"}:
                state["initialized"] = True
            save_state(state)
            if wifi_changed:
                schedule_wifi_restart()
            self.send_json(200, {"status": "ok", "initialized": bool(state["initialized"])})
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
            if wifi_changed:
                try:
                    set_wifi(old_ssid, old_psk)
                except Exception:
                    pass
            if ssh_changed:
                try:
                    restore_ssh_hash(old_shadow)
                except Exception:
                    pass
            self.send_json(500, {"status": "error", "message": str(exc)[:180]})

    def proxy_to_vohive(self) -> None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_error(400)
            return
        if length > MAX_REQUEST_BODY * 32:
            self.send_error(413)
            return
        body = self.rfile.read(length) if length else None
        headers: dict[str, str] = {}
        for key, value in self.headers.items():
            lower = key.lower()
            if lower in HOP_HEADERS or lower in {"host", "content-length", "accept-encoding"}:
                continue
            headers[key] = value
        headers["Host"] = f"{BACKEND_HOST}:{BACKEND_PORT}"
        if body is not None:
            headers["Content-Length"] = str(len(body))
        connection = http.client.HTTPConnection(BACKEND_HOST, BACKEND_PORT, timeout=60)
        response_started = False
        try:
            connection.request(self.command, self.path, body=body, headers=headers)
            response = connection.getresponse()
            content_type = response.getheader("Content-Type", "")
            if "text/html" in content_type:
                response_body = inject_html(response.read())
                self.send_response(response.status, response.reason)
                response_started = True
                for key, value in response.getheaders():
                    if key.lower() not in HOP_HEADERS | {"content-length", "content-encoding"}:
                        self.send_header(key, value)
                self.send_header("Content-Length", str(len(response_body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(response_body)
                return
            self.send_response(response.status, response.reason)
            response_started = True
            has_length = response.getheader("Content-Length") is not None
            for key, value in response.getheaders():
                if key.lower() not in HOP_HEADERS:
                    self.send_header(key, value)
            if not has_length:
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()
            while True:
                chunk = response.read(64 * 1024)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (OSError, http.client.HTTPException):
            if not response_started and not self.wfile.closed:
                self.send_json(502, {"status": "error", "message": "VoHive 后端暂不可用"})
            else:
                self.close_connection = True
        finally:
            connection.close()


def serve_socket(sock: socket.socket) -> ThreadingHTTPServer:
    server = ThreadingHTTPServer(("127.0.0.1", 0), WangkaHandler, bind_and_activate=False)
    server.socket.close()
    server.socket = sock
    server.server_address = sock.getsockname()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def socket_activated_servers() -> list[ThreadingHTTPServer]:
    listen_pid = int(os.environ.get("LISTEN_PID", "0"))
    listen_fds = int(os.environ.get("LISTEN_FDS", "0"))
    if listen_pid != os.getpid() or listen_fds < 1:
        raise RuntimeError("systemd socket activation descriptors are missing")
    servers = []
    for fd in range(3, 3 + listen_fds):
        inherited = socket.fromfd(fd, socket.AF_INET, socket.SOCK_STREAM)
        servers.append(serve_socket(inherited))
    return servers


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket-activation", action="store_true")
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()
    save_state(load_state())
    if args.socket_activation:
        servers = socket_activated_servers()
    else:
        server = ThreadingHTTPServer((args.listen, args.port), WangkaHandler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        servers = [server]
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        for server in servers:
            server.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
