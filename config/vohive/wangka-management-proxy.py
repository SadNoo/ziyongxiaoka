#!/usr/bin/python3
"""Protected VoHive reverse proxy and narrowly scoped device settings portal."""

from __future__ import annotations

import argparse
import fcntl
import http.client
import ipaddress
import json
import os
import secrets
import socket
import stat
import subprocess
import threading
import time
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Optional
from urllib.parse import urlsplit


BACKEND_HOST = os.environ.get("WANGKA_VOHIVE_HOST", "127.0.0.1")
BACKEND_PORT = int(os.environ.get("WANGKA_VOHIVE_PORT", "17575"))
STATE_DIR = Path(os.environ.get("WANGKA_STATE_DIR", "/var/lib/wangka-management"))
STATE_FILE = STATE_DIR / "state.json"
STATE_LOCK_FILE = STATE_DIR / "state.lock"
LOCAL_AUTH_FILE = STATE_DIR / "vohive-local-auth.json"
LAST_EPOCH_FILE = STATE_DIR / "last-trusted-epoch"
SSH_USER = "user"
HOTSPOT_CONNECTION = "hotspot"
HOTSPOT_PROFILE = Path(
    os.environ.get(
        "WANGKA_HOTSPOT_PROFILE",
        "/etc/NetworkManager/system-connections/hotspot.nmconnection",
    )
)
HOST_UPLINK_CONFIG = Path(
    os.environ.get("WANGKA_HOST_UPLINK_CONFIG", "/etc/wangka/host-uplink.json")
)
UPLINK_COMMAND = os.environ.get("WANGKA_UPLINK_COMMAND", "/usr/local/sbin/wangka-uplink")
WORK_MODE_COMMAND = os.environ.get(
    "WANGKA_WORK_MODE_COMMAND", "/usr/local/sbin/wangka-work-mode"
)
LED_COMMAND = os.environ.get("WANGKA_LED_COMMAND", "/usr/local/sbin/wangka-led")
LED_RUNTIME_FILE = Path(
    os.environ.get("WANGKA_LED_RUNTIME", "/run/wangka-led/status.json")
)
THERMAL_ROOT = Path(os.environ.get("WANGKA_THERMAL_ROOT", "/sys/class/thermal"))
ACCESS_MODES = {"login-required", "trusted-network"}
LOCAL_BROWSER_TOKEN = "wangka-local-access"
THERMAL_WARNING_C = 85.0
THERMAL_CRITICAL_C = 92.0
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
_BACKEND_SESSION_LOCK = threading.Lock()
_BACKEND_SESSION_TOKEN = ""
_STATE_THREAD_LOCK = threading.RLock()


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


AUTH_BOOTSTRAP_SCRIPT = r"""<script id="wangka-auth-bootstrap">
try {
  localStorage.setItem('token', 'wangka-local-access');
  if ((location.hash || '').startsWith('#/login')) location.hash = '#/';
} catch (_) {}
</script>"""


EXPERIENCE_SCRIPT = r"""
<style id="wangka-experience-style">
.wangka-feature-panel{margin:0 0 24px;padding:18px;border:1px solid rgba(128,128,150,.28);border-radius:16px;background:var(--el-bg-color,#fff);box-shadow:0 8px 24px rgba(25,28,45,.04)}
.wangka-feature-head{display:flex;align-items:flex-start;justify-content:space-between;gap:14px;margin-bottom:14px}.wangka-feature-title{font-size:16px;font-weight:800}.wangka-feature-subtitle{font-size:12px;color:#8b8d9b;margin-top:4px}.wangka-mode-buttons{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:10px}.wangka-mode-button{border:1px solid rgba(128,128,150,.28);border-radius:12px;padding:12px;background:transparent;color:inherit;text-align:left;cursor:pointer}.wangka-mode-button strong,.wangka-mode-button span{display:block}.wangka-mode-button span{font-size:12px;color:#8b8d9b;margin-top:4px}.wangka-mode-button.active{border-color:#6366f1;background:rgba(99,102,241,.12);box-shadow:inset 0 0 0 1px #6366f1}.wangka-mode-button:disabled{opacity:.55;cursor:wait}.wangka-mode-status{font-size:12px;color:#8b8d9b;margin-top:12px;white-space:pre-wrap}.wangka-led-row{display:flex;align-items:center;justify-content:space-between;gap:16px;margin-top:14px;padding-top:14px;border-top:1px solid rgba(128,128,150,.20)}.wangka-led-state{display:flex;align-items:center;gap:10px;min-width:0}.wangka-led-dot{width:18px;height:18px;flex:0 0 18px;border-radius:50%;border:1px solid rgba(128,128,150,.4);box-shadow:0 0 8px rgba(80,80,95,.25)}.wangka-led-copy{font-size:12px;color:#8b8d9b;white-space:pre-wrap}.wangka-led-controls{display:flex;align-items:center;gap:14px;flex-wrap:wrap}.wangka-led-controls label{display:flex;align-items:center;gap:6px;font-size:12px;cursor:pointer}.wangka-led-controls input{width:16px;height:16px}.wangka-temp-row{display:flex;gap:7px;flex-wrap:wrap;justify-content:flex-end}.wangka-temp{font-size:12px;border-radius:999px;padding:5px 9px;background:rgba(22,163,74,.12);color:#15803d}.wangka-temp.warning{background:rgba(217,119,6,.14);color:#b45309}.wangka-temp.critical{background:rgba(220,38,38,.14);color:#dc2626}.wangka-sms-hint{margin:0 0 16px;padding:11px 14px;border-radius:12px;background:rgba(99,102,241,.10);color:#5558c9;font-size:13px}.wangka-access-row{display:flex;align-items:center;justify-content:space-between;gap:20px}.wangka-access-copy{max-width:680px}.wangka-access-toggle{border:0;border-radius:10px;padding:10px 16px;background:#5b5bd6;color:#fff;font-weight:750;cursor:pointer}.wangka-access-toggle:disabled{opacity:.55}.wangka-access-badge{display:inline-block;margin-left:8px;padding:3px 8px;border-radius:99px;font-size:11px;background:rgba(22,163,74,.12);color:#15803d}.wangka-access-badge.off{background:rgba(217,119,6,.14);color:#b45309}@media(max-width:700px){.wangka-mode-buttons{grid-template-columns:1fr}.wangka-feature-head,.wangka-access-row,.wangka-led-row{flex-direction:column}.wangka-temp-row{justify-content:flex-start}.wangka-led-row{align-items:flex-start}}
@media(prefers-color-scheme:dark){.wangka-feature-panel{background:#1c1c22}.wangka-temp{color:#4ade80}.wangka-temp.warning{color:#fbbf24}.wangka-temp.critical{color:#f87171}.wangka-sms-hint{color:#b8b9ff}}
</style>
<script id="wangka-experience-script">
(() => {
  const LOCAL_TOKEN = 'wangka-local-access';
  const modeCopy = {
    dual: ['双模式', '上网与短信同时运行'],
    data: ['网卡模式', '上网运行，短信引擎停用'],
    sms: ['短信模式', '短信运行，蜂窝数据停用']
  };
  const ledColors = {off:'transparent',red:'#ef4444',green:'#22c55e',blue:'#3b82f6',yellow:'#eab308',cyan:'#06b6d4',magenta:'#d946ef',white:'#ffffff'};
  let capabilities = null;
  let latestStatus = null;
  const token = () => { try { return localStorage.getItem('token') || ''; } catch (_) { return ''; } };
  async function request(path, options={}) {
    options.headers = Object.assign({}, options.headers || {});
    if (token()) options.headers.Authorization = `Bearer ${token()}`;
    if (options.body) options.headers['Content-Type'] = 'application/json';
    const response = await fetch(path, Object.assign({cache:'no-store'}, options));
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(data.message || `请求失败 ${response.status}`);
    return data;
  }
  function pageHeader(title) {
    const heading = [...document.querySelectorAll('h1,h2')].find((node) => (node.textContent || '').trim() === title);
    if (!heading) return null;
    let current = heading;
    while (current.parentElement && current.parentElement.parentElement) {
      if (current.nextElementSibling) return current;
      current = current.parentElement;
    }
    return current;
  }
  async function loadCapabilities() {
    try {
      capabilities = await request('/wangka/api/capabilities');
      if (!capabilities.auth_required) {
        try { localStorage.setItem('token', LOCAL_TOKEN); } catch (_) {}
        document.querySelectorAll('.ui-panel-muted').forEach((node) => {
          if ((node.textContent || '').includes('Administrator')) node.remove();
        });
        if ((location.hash || '').startsWith('#/login')) location.hash = '#/';
      }
    } catch (_) {}
  }
  function temperatureChips(thermal) {
    const row = document.createElement('div');
    row.className = 'wangka-temp-row';
    const sensors = thermal && Array.isArray(thermal.sensors) ? thermal.sensors : [];
    if (!sensors.length) {
      const chip = document.createElement('span'); chip.className='wangka-temp'; chip.textContent='温度暂不可用'; row.appendChild(chip); return row;
    }
    sensors.slice(0, 4).forEach((sensor) => {
      const chip = document.createElement('span');
      chip.className = `wangka-temp ${sensor.level || ''}`;
      chip.textContent = `${sensor.name || '温度'} ${Number(sensor.temperature_c).toFixed(1)}°C`;
      row.appendChild(chip);
    });
    return row;
  }
  function renderModePanel(status) {
    latestStatus = status;
    const panel = document.getElementById('wangka-work-mode-panel');
    if (!panel) return;
    panel.querySelectorAll('[data-work-mode]').forEach((button) => {
      button.classList.toggle('active', button.dataset.workMode === status.work_mode.mode);
      button.disabled = !!status.work_mode.transition;
    });
    const temp = panel.querySelector('[data-temperature]');
    temp.replaceChildren(temperatureChips(status.thermal));
    const state = panel.querySelector('[data-mode-state]');
    let text = status.work_mode.transition ? `正在切换到：${modeCopy[status.work_mode.transition][0]}` : `当前：${modeCopy[status.work_mode.mode][0]}`;
    if (status.work_mode.last_error) text += `\n提示：${status.work_mode.last_error}`;
    state.textContent = text;
    renderLED(status.led || {});
  }
  function renderLED(led) {
    const copy=document.querySelector('[data-led-state]'); const dot=document.querySelector('[data-led-dot]');
    const enabled=document.querySelector('[data-led-enabled]'); const night=document.querySelector('[data-led-night]');
    if (!copy || !dot || !enabled || !night) return;
    const modeColor=led.mode_color_label || '读取中'; const actual=`${led.color_label || '未知'}${led.pattern_label || ''}`;
    copy.textContent=`模式颜色：${modeColor} · 当前：${actual}\n${led.meaning || '正在读取状态灯含义…'}`;
    dot.style.background=ledColors[led.color] || 'transparent';
    dot.style.boxShadow=led.color==='off'?'none':`0 0 10px ${ledColors[led.color] || '#888'}`;
    enabled.checked=led.enabled !== false; night.checked=led.night_mode === true;
  }
  async function setLED() {
    const enabled=document.querySelector('[data-led-enabled]'); const night=document.querySelector('[data-led-night]');
    if (!enabled || !night) return;
    enabled.disabled=true; night.disabled=true;
    try {
      const led=await request('/wangka/api/led',{method:'POST',body:JSON.stringify({enabled:enabled.checked,night_mode:night.checked})});
      renderLED(led); await refreshStatus();
    } catch(error) { alert(error.message); await refreshStatus(); }
    finally { enabled.disabled=false; night.disabled=false; }
  }
  async function refreshStatus() {
    if (!document.getElementById('wangka-work-mode-panel') && !document.getElementById('wangka-sms-hint')) return;
    try { renderModePanel(await request('/wangka/api/status')); } catch (_) {}
  }
  async function switchMode(mode) {
    const copy = modeCopy[mode];
    if (!copy || (latestStatus && latestStatus.work_mode.mode === mode)) return;
    if (!confirm(`确认切换到“${copy[0]}”？\n${copy[1]}`)) return;
    const panel = document.getElementById('wangka-work-mode-panel');
    panel.querySelector('[data-mode-state]').textContent = `正在切换到：${copy[0]}`;
    panel.querySelectorAll('button').forEach((button) => button.disabled = true);
    try {
      await request('/wangka/api/work-mode', {method:'POST', body:JSON.stringify({mode})});
      await refreshStatus();
    } catch (error) {
      panel.querySelector('[data-mode-state]').textContent = error.message;
      panel.querySelectorAll('button').forEach((button) => button.disabled = false);
    }
  }
  function ensureModePanel() {
    if (document.getElementById('wangka-work-mode-panel')) return;
    const header = pageHeader('设备监控');
    if (!header || !header.parentElement) return;
    const panel = document.createElement('section'); panel.id='wangka-work-mode-panel'; panel.className='wangka-feature-panel';
    const head = document.createElement('div'); head.className='wangka-feature-head';
    const copy = document.createElement('div'); copy.innerHTML='<div class="wangka-feature-title">工作模式</div><div class="wangka-feature-subtitle">选择上网与短信的运行组合，切换失败会自动恢复</div>';
    const temps = document.createElement('div'); temps.dataset.temperature='1'; head.append(copy, temps); panel.appendChild(head);
    const buttons = document.createElement('div'); buttons.className='wangka-mode-buttons';
    Object.entries(modeCopy).forEach(([mode, text]) => { const button=document.createElement('button'); button.className='wangka-mode-button'; button.dataset.workMode=mode; const strong=document.createElement('strong'); strong.textContent=text[0]; const span=document.createElement('span'); span.textContent=text[1]; button.append(strong,span); button.onclick=()=>switchMode(mode); buttons.appendChild(button); });
    const state = document.createElement('div'); state.className='wangka-mode-status'; state.dataset.modeState='1'; state.textContent='正在读取当前模式…'; panel.append(buttons,state);
    const ledRow=document.createElement('div'); ledRow.className='wangka-led-row';
    const ledState=document.createElement('div'); ledState.className='wangka-led-state'; const dot=document.createElement('span'); dot.className='wangka-led-dot'; dot.dataset.ledDot='1'; const ledCopy=document.createElement('div'); ledCopy.className='wangka-led-copy'; ledCopy.dataset.ledState='1'; ledCopy.textContent='正在读取状态灯…'; ledState.append(dot,ledCopy);
    const controls=document.createElement('div'); controls.className='wangka-led-controls'; const enabledLabel=document.createElement('label'); const enabled=document.createElement('input'); enabled.type='checkbox'; enabled.dataset.ledEnabled='1'; enabled.onchange=setLED; enabledLabel.append(enabled,document.createTextNode('开启状态灯')); const nightLabel=document.createElement('label'); const night=document.createElement('input'); night.type='checkbox'; night.dataset.ledNight='1'; night.onchange=setLED; nightLabel.append(night,document.createTextNode('夜间模式')); controls.append(enabledLabel,nightLabel); ledRow.append(ledState,controls); panel.appendChild(ledRow);
    header.parentElement.insertBefore(panel, header.nextElementSibling);
    refreshStatus();
  }
  function ensureSmsHint() {
    if (document.getElementById('wangka-sms-hint')) return;
    const header = pageHeader('短信中心');
    if (!header || !header.parentElement) return;
    const hint=document.createElement('div'); hint.id='wangka-sms-hint'; hint.className='wangka-sms-hint'; hint.textContent='向普通手机号码发送短信时，请使用“+国家/地区码 + 手机号码”格式。例如中国大陆使用 +86。运营商短号码可直接填写。';
    header.parentElement.insertBefore(hint, header.nextElementSibling);
  }
  async function setAccessMode(next) {
    const label = next === 'login-required' ? '开启' : '关闭';
    const warning = next === 'trusted-network' ? '\n关闭后，连接到设备 Wi-Fi 或 USB 的人都可以直接管理。' : '';
    if (!confirm(`确认${label}管理登录保护？${warning}`)) return;
    const button=document.querySelector('[data-access-toggle]'); if(button) button.disabled=true;
    try {
      await request('/wangka/api/access-mode',{method:'POST',body:JSON.stringify({mode:next})});
      if (next === 'login-required') { try { localStorage.removeItem('token'); } catch (_) {} location.hash='#/login'; location.reload(); }
      else { try { localStorage.setItem('token',LOCAL_TOKEN); } catch (_) {} location.hash='#/'; location.reload(); }
    } catch(error) { alert(error.message); if(button) button.disabled=false; }
  }
  function ensureAccessPanel() {
    if (document.getElementById('wangka-access-panel') || !capabilities) return;
    const header = pageHeader('系统设置');
    if (!header || !header.parentElement) return;
    const panel=document.createElement('section'); panel.id='wangka-access-panel'; panel.className='wangka-feature-panel';
    const row=document.createElement('div'); row.className='wangka-access-row';
    const copy=document.createElement('div'); copy.className='wangka-access-copy';
    const title=document.createElement('div'); title.className='wangka-feature-title'; title.textContent='管理登录保护';
    const badge=document.createElement('span'); badge.className='wangka-access-badge'+(capabilities.auth_required?'':' off'); badge.textContent=capabilities.auth_required?'已开启':'已关闭'; title.appendChild(badge);
    const desc=document.createElement('div'); desc.className='wangka-feature-subtitle'; desc.textContent=capabilities.auth_required?'浏览器和 Mac App 需要登录；Mac App 退出后不会保留凭据。':'连接到设备 Wi-Fi 或 USB 后可直接管理，无需输入用户名和密码。'; copy.append(title,desc);
    const button=document.createElement('button'); button.className='wangka-access-toggle'; button.dataset.accessToggle='1'; button.textContent=capabilities.auth_required?'关闭登录保护':'开启登录保护'; button.onclick=()=>setAccessMode(capabilities.auth_required?'trusted-network':'login-required'); row.append(copy,button); panel.appendChild(row);
    header.parentElement.insertBefore(panel,header.nextElementSibling);
  }
  function ensureFeatures() { ensureModePanel(); ensureSmsHint(); ensureAccessPanel(); }
  const observer=new MutationObserver(ensureFeatures); observer.observe(document.documentElement,{childList:true,subtree:true});
  loadCapabilities().then(ensureFeatures); ensureFeatures();
  setInterval(()=>{ loadCapabilities().then(ensureAccessPanel); refreshStatus(); },10000);
})();
</script>
"""


SYSTEM_DEVICE_HTML = r"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>系统设备 · VoHive</title>
<style>
:root{color-scheme:light dark;--bg:#f5f6fa;--card:#fff;--text:#17181c;--muted:#687083;--line:#e5e7ef;--brand:#5b5bd6;--ok:#159a67;--warn:#b7791f}*{box-sizing:border-box}body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:var(--bg);color:var(--text)}header{height:58px;background:var(--card);border-bottom:1px solid var(--line);display:flex;align-items:center;justify-content:space-between;padding:0 22px;position:sticky;top:0;z-index:2}header strong{font-size:18px}a{color:var(--brand);text-decoration:none}.wrap{max-width:1080px;margin:24px auto;padding:0 16px 48px}.banner,.card{background:var(--card);border:1px solid var(--line);border-radius:16px;box-shadow:0 8px 28px rgba(25,28,45,.05)}.banner{padding:18px 20px;margin-bottom:16px;border-left:5px solid var(--warn)}.banner.done{border-left-color:var(--ok)}.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:14px}.card{padding:20px;margin-bottom:16px}.grid .card{margin:0}.label{font-size:12px;color:var(--muted);margin-bottom:7px}.value{font-weight:700}.section-title{font-size:18px;margin:0 0 5px}.section-desc{color:var(--muted);font-size:13px;margin:0 0 18px}.row{display:grid;grid-template-columns:1fr 1fr;gap:14px}.field{margin-bottom:14px}label{display:block;font-size:13px;font-weight:650;margin-bottom:7px}input{width:100%;height:42px;padding:0 12px;border:1px solid var(--line);border-radius:10px;background:transparent;color:inherit;font-size:15px}.targets{display:flex;gap:16px;flex-wrap:wrap;margin:6px 0 16px}.targets label{font-weight:500}.targets input{width:auto;height:auto;margin-right:5px}.actions{display:flex;gap:10px;flex-wrap:wrap}.button{border:0;border-radius:10px;padding:11px 17px;font-weight:700;cursor:pointer;background:#ececfb;color:#3e3ea8}.button.primary{background:var(--brand);color:#fff}.button:disabled{opacity:.5;cursor:not-allowed}.button.small{padding:6px 9px;margin-top:10px;font-size:12px}.notice{padding:12px 14px;border-radius:10px;background:#f0f1ff;color:#3e3ea8;font-size:13px;margin:12px 0;white-space:pre-wrap}.error{background:#fff0f0;color:#b42318}.network{display:flex;gap:12px}.mode{flex:1;border:1px solid var(--line);border-radius:12px;padding:15px}.mode.active{border:2px solid var(--ok)}.pill{display:inline-block;font-size:11px;padding:3px 8px;border-radius:99px;background:#eaf8f2;color:#087a50}.pill.wait{background:#fff5df;color:#9a6700}.helper-state{margin-top:14px}@media(max-width:820px){.grid{grid-template-columns:1fr 1fr}.row{grid-template-columns:1fr}.network{flex-direction:column}}@media(max-width:520px){.grid{grid-template-columns:1fr}header{padding:0 14px}}
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
    <p class="section-desc">显式选择网络方向；切换不会改变 USB 管理地址，失败时会自动恢复 device-uplink。</p>
    <div class="network">
      <div id="deviceMode" class="mode"><span id="devicePill" class="pill wait">可选择</span><h3>device-uplink</h3><p class="section-desc">设备通过 SIM/LTE 向 USB/Wi-Fi 客户端共享网络。</p><button id="selectDevice" class="button">切换到设备上行</button></div>
      <div id="hostMode" class="mode"><span id="hostPill" class="pill wait">正在检查</span><h3>host-uplink</h3><p class="section-desc">仅 Debian 本机通过 USB 借用当前 Mac 网络；不会转发 Wi-Fi 客户端。</p><button id="selectHost" class="button primary" disabled>切换到 Mac 上行</button></div>
    </div>
    <div id="uplinkValue" class="notice helper-state">正在检查 Mac 助手…</div>
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
function renderUplink(status) {
  const mode=status.uplink_mode || 'device-uplink';
  const uplink=status.uplink || {};
  $('deviceMode').classList.toggle('active',mode==='device-uplink');
  $('hostMode').classList.toggle('active',mode==='host-uplink');
  $('devicePill').textContent=mode==='device-uplink'?'当前':'可选择';
  $('hostPill').textContent=mode==='host-uplink'?'当前':(uplink.installed?'可选择':'未配对');
  $('selectDevice').disabled=mode==='device-uplink';
  $('selectHost').disabled=!uplink.installed || !uplink.helper_reachable || mode==='host-uplink';
  let text=`当前模式：${mode}\nMac 助手：${uplink.helper_reachable?'已连接':(uplink.installed?'未连接':'未安装或未配对')}`;
  if(uplink.helper && uplink.helper.upstream_interface) text+=`\nMac 当前上游：${uplink.helper.upstream_interface}`;
  if(uplink.last_result && uplink.last_result!=='never') text+=`\n最近结果：${uplink.last_result}`;
  if(uplink.last_error) text+=`\n提示：${uplink.last_error}`;
  $('uplinkValue').textContent=text;
  $('uplinkValue').className='notice helper-state'+(uplink.last_error?' error':'');
}
async function switchUplink(mode) {
  const label=mode==='host-uplink'?'Mac 上行':'设备上行';
  if(!confirm(`确认切换到 ${label}？管理地址 192.168.5.1 将保持不变。`)) return;
  $('selectDevice').disabled=true;$('selectHost').disabled=true;
  $('uplinkValue').textContent='正在切换并检查回滚条件…';
  try { await api('/wangka/api/uplink',{method:'POST',body:JSON.stringify({mode})}); const status=await api('/wangka/api/status'); renderUplink(status); }
  catch(e) { show(e.message,true); try { renderUplink(await api('/wangka/api/status')); } catch(_) {} }
}
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
    renderUplink(status);
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
$('selectDevice').onclick=()=>switchUplink('device-uplink');
$('selectHost').onclick=()=>switchUplink('host-uplink');
load();
</script>
</body></html>"""


def default_state() -> dict[str, Any]:
    return {
        "initialized": False,
        "generation": 0,
        "uplink_mode": "device-uplink",
        "work_mode": "dual",
        "access_mode": "login-required",
        "led_enabled": True,
        "led_night_mode": False,
    }


def load_state() -> dict[str, Any]:
    try:
        loaded = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        state = default_state()
        if isinstance(loaded, dict):
            state.update(loaded)
        if state.get("work_mode") not in {"dual", "data", "sms"}:
            state["work_mode"] = "dual"
        if state.get("access_mode") not in ACCESS_MODES:
            state["access_mode"] = "login-required"
        if not isinstance(state.get("led_enabled"), bool):
            state["led_enabled"] = True
        if not isinstance(state.get("led_night_mode"), bool):
            state["led_night_mode"] = False
        return state
    except (OSError, ValueError):
        return default_state()


def write_state_unlocked(state: dict[str, Any]) -> None:
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


@contextmanager
def locked_state() -> Any:
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(STATE_DIR, 0o700)
    with _STATE_THREAD_LOCK:
        fd = os.open(STATE_LOCK_FILE, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            os.chmod(STATE_LOCK_FILE, 0o600)
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)


def save_state(state: dict[str, Any]) -> None:
    with locked_state():
        write_state_unlocked(state)


def update_state_fields(fields: dict[str, Any]) -> dict[str, Any]:
    with locked_state():
        state = load_state()
        state.update(fields)
        write_state_unlocked(state)
        return state


def mark_credentials_applied(initialized: bool) -> dict[str, Any]:
    with locked_state():
        state = load_state()
        state["generation"] = int(state.get("generation", 0)) + 1
        if initialized:
            state["initialized"] = True
        write_state_unlocked(state)
        return state


def save_local_auth(password: str) -> None:
    """Synchronize root-only local API auth after VoHive accepts a rotation."""
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(STATE_DIR, 0o700)
    temporary = STATE_DIR / f".vohive-local-auth.{os.getpid()}.{threading.get_ident()}"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(
                {"password": password, "username": "user"},
                stream,
                ensure_ascii=False,
                sort_keys=True,
            )
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, LOCAL_AUTH_FILE)
        os.chmod(LOCAL_AUTH_FILE, 0o600)
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


def hotspot_ssid() -> str:
    """Read the NetworkManager keyfile without starting nmcli."""
    try:
        if HOTSPOT_PROFILE.stat().st_size > 64 * 1024:
            return "Wangka-UFI103S"
        text = HOTSPOT_PROFILE.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return "Wangka-UFI103S"
    section = ""
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip().lower()
            continue
        if section not in {"wifi", "802-11-wireless"}:
            continue
        key, separator, value = line.partition("=")
        if separator and key.strip().lower() == "ssid":
            candidate = value.strip()
            if candidate:
                return candidate
    return "Wangka-UFI103S"


def backend_reachable() -> bool:
    """Check the loopback listener without forking systemctl."""
    try:
        with socket.create_connection((BACKEND_HOST, BACKEND_PORT), timeout=0.25):
            return True
    except OSError:
        return False


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


def uplink_status() -> dict[str, Any]:
    state = load_state()
    mode = str(state.get("uplink_mode", "device-uplink"))
    if mode != "host-uplink":
        # The device-owned path needs no live Mac probe. Building this result
        # from the atomic state file avoids spawning Python on every browser
        # and App status refresh.
        return {
            "status": "ok",
            "mode": "device-uplink",
            "installed": HOST_UPLINK_CONFIG.is_file(),
            "helper_reachable": False,
            "helper_enabled": False,
            "helper_checked": False,
            "last_result": state.get("uplink_last_result", "never"),
            "last_error": state.get("uplink_last_error", ""),
            "changed_at": state.get("uplink_changed_at", 0),
        }
    try:
        raw = run_command([UPLINK_COMMAND, "status"])
        payload = json.loads(raw)
        if not isinstance(payload, dict) or payload.get("status") != "ok":
            raise ValueError("invalid uplink status")
        return payload
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired):
        state = load_state()
        return {
            "status": "error",
            "mode": state.get("uplink_mode", "device-uplink"),
            "installed": False,
            "helper_reachable": False,
            "helper_enabled": False,
            "last_result": state.get("uplink_last_result", "unavailable"),
            "last_error": "USB 网络方向助手暂不可用",
        }


def switch_uplink(mode: str) -> dict[str, Any]:
    if mode not in {"device-uplink", "host-uplink"}:
        raise ValueError("网络方向无效")
    result = subprocess.run(
        [UPLINK_COMMAND, mode],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=30,
        check=False,
    )
    try:
        payload = json.loads(result.stdout)
    except ValueError as exc:
        raise RuntimeError("网络方向助手返回无效结果") from exc
    if result.returncode != 0 or not isinstance(payload, dict) or payload.get("status") != "ok":
        message = payload.get("message", "网络方向切换失败") if isinstance(payload, dict) else "网络方向切换失败"
        raise RuntimeError(str(message)[:240])
    return payload


def work_mode_status() -> dict[str, Any]:
    # Work-mode writes every transition atomically. Reading it directly keeps
    # high-frequency UI refreshes from creating a process queue on MSM8916.
    state = load_state()
    mode = str(state.get("work_mode", "dual"))
    if mode not in {"dual", "data", "sms"}:
        mode = "dual"
    transition = str(state.get("work_mode_transition", ""))
    if transition not in {"dual", "data", "sms"}:
        transition = ""
    return {
        "status": "ok",
        "mode": mode,
        "transition": transition,
        "data_enabled": mode in {"dual", "data"},
        "sms_enabled": mode in {"dual", "sms"},
        "last_result": state.get("work_mode_last_result", "never"),
        "last_error": state.get("work_mode_last_error", ""),
        "changed_at": int(state.get("work_mode_changed_at", 0) or 0),
    }


def switch_work_mode(mode: str) -> dict[str, Any]:
    if mode not in {"dual", "data", "sms"}:
        raise ValueError("工作模式无效")
    result = subprocess.run(
        [WORK_MODE_COMMAND, "switch", mode],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=150,
        check=False,
    )
    try:
        payload = json.loads(result.stdout)
    except ValueError as exc:
        raise RuntimeError("工作模式助手返回无效结果") from exc
    if result.returncode != 0 or not isinstance(payload, dict) or payload.get("status") != "ok":
        message = payload.get("message", "工作模式切换失败") if isinstance(payload, dict) else "工作模式切换失败"
        raise RuntimeError(str(message)[:240])
    return payload


def thermal_level(temperature_c: float) -> str:
    if temperature_c >= THERMAL_CRITICAL_C:
        return "critical"
    if temperature_c >= THERMAL_WARNING_C:
        return "warning"
    return "normal"


def thermal_name(raw_name: str) -> str:
    lowered = raw_name.lower()
    for needle, label in (
        ("modem", "基带"),
        ("gpu", "GPU"),
        ("cpu", "CPU"),
        ("battery", "电池"),
        ("wlan", "Wi-Fi"),
    ):
        if needle in lowered:
            return label
    cleaned = "".join(char for char in raw_name if char.isalnum() or char in "-_ ").strip()
    return cleaned[:32] or "系统"


def thermal_status() -> dict[str, Any]:
    sensors: list[dict[str, Any]] = []
    try:
        zones = sorted(THERMAL_ROOT.glob("thermal_zone*"), key=lambda item: item.name)
    except OSError:
        zones = []
    for zone in zones:
        try:
            raw_name = (zone / "type").read_text(encoding="utf-8").strip()
            raw_value = (zone / "temp").read_text(encoding="ascii").strip()
            value = float(raw_value)
            if abs(value) >= 1000:
                value /= 1000.0
            if not -40.0 <= value <= 150.0:
                continue
        except (OSError, UnicodeError, ValueError):
            continue
        sensors.append(
            {
                "name": thermal_name(raw_name),
                "temperature_c": round(value, 1),
                "level": thermal_level(value),
            }
        )
    # Keep one item per friendly sensor name and prefer the highest reading.
    by_name: dict[str, dict[str, Any]] = {}
    for sensor in sensors:
        name = str(sensor["name"])
        if name not in by_name or float(sensor["temperature_c"]) > float(by_name[name]["temperature_c"]):
            by_name[name] = sensor
    selected = sorted(by_name.values(), key=lambda item: str(item["name"]))
    maximum = max((float(item["temperature_c"]) for item in selected), default=None)
    return {
        "status": "ok" if selected else "unavailable",
        "level": thermal_level(maximum) if maximum is not None else "unavailable",
        "maximum_c": round(maximum, 1) if maximum is not None else None,
        "warning_c": THERMAL_WARNING_C,
        "critical_c": THERMAL_CRITICAL_C,
        "sensors": selected,
    }


def fallback_led_status(
    state: dict[str, Any], work_mode: dict[str, Any], thermal: dict[str, Any]
) -> dict[str, Any]:
    mode = str(work_mode.get("transition") or work_mode.get("mode") or "dual")
    if mode not in {"dual", "data", "sms"}:
        mode = "dual"
    colors = {"dual": ("white", "白色"), "data": ("green", "绿色"), "sms": ("blue", "蓝色")}
    labels = {"dual": "双模式", "data": "网卡模式", "sms": "短信模式"}
    mode_color, mode_color_label = colors[mode]
    enabled = state.get("led_enabled") is not False
    night_mode = state.get("led_night_mode") is True
    color, color_label, pattern, pattern_label = mode_color, mode_color_label, "steady", "常亮"
    meaning = f"{labels[mode]}运行正常"
    source = "work-mode"
    maximum = thermal.get("maximum_c")
    if not enabled:
        color, color_label, pattern, pattern_label = "off", "熄灭", "off", "熄灭"
        meaning, source = "状态灯已关闭", "setting"
    elif isinstance(maximum, (int, float)) and maximum >= THERMAL_CRITICAL_C:
        color, color_label, pattern, pattern_label = "red", "红色", "fast-blink", "快闪"
        meaning, source = f"严重过热（{maximum:.1f}°C），请停止使用并降温", "thermal-critical"
    elif isinstance(maximum, (int, float)) and maximum >= THERMAL_WARNING_C:
        color, color_label, pattern, pattern_label = "yellow", "黄色", "slow-blink", "慢闪"
        meaning, source = f"温度警告（{maximum:.1f}°C）", "thermal-warning"
    elif work_mode.get("transition"):
        if night_mode:
            color, color_label, pattern, pattern_label = "off", "熄灭", "off", "熄灭"
            meaning, source = f"夜间模式：正在切换到{labels[mode]}，正常状态不亮灯", "night-transition"
        else:
            pattern, pattern_label = "slow-blink", "慢闪"
            meaning, source = f"正在切换到{labels[mode]}", "transition"
    elif night_mode:
        color, color_label, pattern, pattern_label = "off", "熄灭", "off", "熄灭"
        meaning, source = f"夜间模式：{labels[mode]}运行正常，仅异常时亮灯", "night-mode"
    return {
        "status": "pending",
        "available": True,
        "enabled": enabled,
        "night_mode": night_mode,
        "mode": mode,
        "mode_label": labels[mode],
        "mode_color": mode_color,
        "mode_color_label": mode_color_label,
        "color": color,
        "color_label": color_label,
        "pattern": pattern,
        "pattern_label": pattern_label,
        "meaning": meaning,
        "source": source,
    }


def led_status(
    state: dict[str, Any], work_mode: dict[str, Any], thermal: dict[str, Any]
) -> dict[str, Any]:
    fallback = fallback_led_status(state, work_mode, thermal)
    try:
        if LED_RUNTIME_FILE.stat().st_size > 16 * 1024:
            return fallback
        loaded = json.loads(LED_RUNTIME_FILE.read_text(encoding="utf-8"))
        if not isinstance(loaded, dict):
            return fallback
        required = {"enabled", "night_mode", "mode_color", "color", "pattern", "meaning"}
        if not required.issubset(loaded):
            return fallback
        if loaded.get("enabled") != fallback["enabled"] or loaded.get("night_mode") != fallback["night_mode"]:
            return fallback
        expected_mode = str(work_mode.get("transition") or work_mode.get("mode") or "dual")
        if loaded.get("mode") != expected_mode:
            return fallback
        return loaded
    except (OSError, ValueError):
        return fallback


def apply_led_settings(enabled: bool, night_mode: bool) -> dict[str, Any]:
    update_state_fields(
        {
            "led_enabled": enabled,
            "led_night_mode": night_mode,
            "led_settings_changed_at": int(time.time()),
        }
    )
    raw = run_command([LED_COMMAND, "apply"])
    try:
        payload = json.loads(raw)
    except ValueError as exc:
        raise RuntimeError("状态灯助手返回无效结果") from exc
    if not isinstance(payload, dict) or payload.get("status") != "ok":
        raise RuntimeError("状态灯暂不可用")
    return payload


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


def local_backend_credentials() -> tuple[str, str]:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(LOCAL_AUTH_FILE, flags)
    with os.fdopen(fd, "r", encoding="utf-8") as stream:
        info = os.fstat(stream.fileno())
        if (
            not stat.S_ISREG(info.st_mode)
            or stat.S_IMODE(info.st_mode) & 0o077
            or info.st_size > 16 * 1024
        ):
            raise RuntimeError("本地认证存储无效")
        loaded = json.load(stream)
    if not isinstance(loaded, dict):
        raise RuntimeError("本地认证存储无效")
    username = str(loaded.get("username", ""))
    password = str(loaded.get("password", ""))
    if username != "user" or not password:
        raise RuntimeError("本地认证存储无效")
    return username, password


def invalidate_backend_session() -> None:
    global _BACKEND_SESSION_TOKEN
    with _BACKEND_SESSION_LOCK:
        _BACKEND_SESSION_TOKEN = ""


def backend_session_authorization() -> str:
    global _BACKEND_SESSION_TOKEN
    with _BACKEND_SESSION_LOCK:
        if _BACKEND_SESSION_TOKEN:
            return f"Bearer {_BACKEND_SESSION_TOKEN}"
        username, password = local_backend_credentials()
        status, body, _ = backend_request(
            "POST",
            "/api/auth/login",
            payload={"username": username, "password": password},
            timeout=10,
        )
        if status != 200:
            raise RuntimeError("设备内部认证失败")
        try:
            token = str(json.loads(body).get("token", ""))
        except (ValueError, AttributeError) as exc:
            raise RuntimeError("设备内部认证返回无效结果") from exc
        if not token or len(token) > 16 * 1024:
            raise RuntimeError("设备内部认证返回无效结果")
        _BACKEND_SESSION_TOKEN = token
        return f"Bearer {token}"


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
    if load_state().get("access_mode") == "trusted-network":
        head = b"<head>"
        bootstrap = AUTH_BOOTSTRAP_SCRIPT.encode("utf-8")
        if head in body and b'id="wangka-auth-bootstrap"' not in body:
            body = body.replace(head, head + bootstrap, 1)
    injection = (INJECT_SCRIPT + EXPERIENCE_SCRIPT).encode("utf-8")
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

    def management_client(self) -> bool:
        try:
            address = ipaddress.ip_address(self.client_address[0])
        except ValueError:
            return False
        return (
            address.is_loopback
            or address in ipaddress.ip_network("192.168.4.0/24")
            or address in ipaddress.ip_network("192.168.5.0/24")
        )

    def require_auth(self) -> bool:
        if authenticated(self.authorization()):
            return True
        self.send_json(401, {"status": "error", "message": "登录已失效"})
        return False

    def require_access(self) -> bool:
        if not self.management_client():
            self.send_json(403, {"status": "error", "message": "仅允许从设备管理网络访问"})
            return False
        if load_state().get("access_mode") == "trusted-network":
            return True
        return self.require_auth()

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
        state = load_state()
        if (
            path == "/api/auth/login"
            and self.command == "POST"
            and state.get("access_mode") == "trusted-network"
        ):
            try:
                self.read_json()
            except ValueError:
                pass
            self.send_json(200, {"token": LOCAL_BROWSER_TOKEN, "access_mode": "trusted-network"})
            return
        if path == "/api/system/uninstall":
            self.send_json(
                403,
                {"status": "error", "code": "disabled", "message": "网页卸载已永久禁用"},
            )
            return
        if path == "/api/devices/onboard-qmi" and self.command == "DELETE":
            self.send_json(
                403,
                {"status": "error", "code": "disabled", "message": "板载设备删除已永久禁用"},
            )
            return
        if path == "/api/sms/send" and self.command == "POST":
            if state.get("work_mode", "dual") == "data":
                self.send_json(
                    409,
                    {"status": "error", "code": "sms_disabled", "message": "当前为网卡模式，短信引擎已停用"},
                )
                return
        if path == "/api/settings/password":
            self.send_json(
                409,
                {
                    "status": "error",
                    "code": "use_system_device",
                    "message": "请在“系统设备”页面修改 VoHive 密码",
                },
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
        if path.startswith("/api/") and path != "/api/auth/login" and not state["initialized"]:
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
        if path == "/wangka/api/capabilities" and self.command == "GET":
            if not self.management_client():
                self.send_json(403, {"status": "error", "message": "仅允许从设备管理网络访问"})
                return
            state = load_state()
            self.send_json(
                200,
                {
                    "status": "ok",
                    "auth_required": state.get("access_mode") != "trusted-network",
                    "access_mode": state.get("access_mode", "login-required"),
                    "work_modes": ["dual", "data", "sms"],
                    "led_control": True,
                    "keychain_used": False,
                },
            )
            return
        if path == "/wangka/api/access-mode" and self.command == "POST":
            if not self.require_access():
                return
            try:
                payload = self.read_json()
                mode = str(payload.get("mode", ""))
                if mode not in ACCESS_MODES:
                    raise ValueError("登录保护模式无效")
                update_state_fields(
                    {
                        "access_mode": mode,
                        "access_mode_changed_at": int(time.time()),
                    }
                )
                self.send_json(
                    200,
                    {
                        "status": "ok",
                        "access_mode": mode,
                        "auth_required": mode == "login-required",
                    },
                )
            except ValueError as exc:
                self.send_json(400, {"status": "error", "message": str(exc)})
            except OSError:
                self.send_json(500, {"status": "error", "message": "登录保护状态无法保存"})
            return
        if not self.require_access():
            return
        if path == "/wangka/api/status" and self.command == "GET":
            state = load_state()
            uplink = uplink_status()
            work_mode = work_mode_status()
            thermal = thermal_status()
            ssid = hotspot_ssid()
            active = backend_reachable()
            self.send_json(
                200,
                {
                    "initialized": bool(state.get("initialized")),
                    "generation": int(state.get("generation", 0)),
                    "ssh_username": SSH_USER,
                    "vohive_username": "user",
                    "wifi_ssid": ssid,
                    "uplink_mode": uplink.get("mode", state.get("uplink_mode", "device-uplink")),
                    "host_uplink_installed": bool(uplink.get("installed")),
                    "uplink": uplink,
                    "work_mode": work_mode,
                    "thermal": thermal,
                    "led": led_status(state, work_mode, thermal),
                    "access_mode": state.get("access_mode", "login-required"),
                    "auth_required": state.get("access_mode") != "trusted-network",
                    "vohive_active": active,
                    "uninstall_blocked": True,
                    **system_time_payload(),
                },
            )
            return
        if path == "/wangka/api/led" and self.command == "POST":
            try:
                payload = self.read_json()
                enabled = payload.get("enabled")
                night_mode = payload.get("night_mode")
                if not isinstance(enabled, bool) or not isinstance(night_mode, bool):
                    raise ValueError("状态灯设置必须为布尔值")
                self.send_json(200, apply_led_settings(enabled, night_mode))
            except ValueError as exc:
                self.send_json(400, {"status": "error", "message": str(exc)})
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
                self.send_json(500, {"status": "error", "message": str(exc)[:240]})
            return
        if path == "/wangka/api/work-mode" and self.command == "POST":
            try:
                payload = self.read_json()
                result = switch_work_mode(str(payload.get("mode", "")))
                self.send_json(200, result)
            except ValueError as exc:
                self.send_json(400, {"status": "error", "message": str(exc)})
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
                self.send_json(500, {"status": "error", "message": str(exc)[:240]})
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
        if path == "/wangka/api/uplink" and self.command == "POST":
            try:
                payload = self.read_json()
                mode = str(payload.get("mode", ""))
                result = switch_uplink(mode)
                self.send_json(200, result)
            except ValueError as exc:
                self.send_json(400, {"status": "error", "message": str(exc)})
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
                self.send_json(500, {"status": "error", "message": str(exc)[:240]})
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
            update_state_fields({})
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
                authorization = self.authorization()
                if load_state().get("access_mode") == "trusted-network":
                    authorization = backend_session_authorization()
                status, body, _ = backend_request(
                    "POST",
                    "/api/settings/password",
                    authorization=authorization,
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
                # The upstream service keeps its changed password outside the
                # original YAML. Keep the root-only local CLI credential in
                # sync immediately after the backend accepts the change.
                save_local_auth(password)
                invalidate_backend_session()
            state = mark_credentials_applied(targets == {"ssh", "wifi", "vohive"})
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
        if (
            urlsplit(self.path).path.startswith("/api/")
            and load_state().get("access_mode") == "trusted-network"
        ):
            try:
                headers["Authorization"] = backend_session_authorization()
            except (OSError, RuntimeError, ValueError, json.JSONDecodeError):
                self.send_json(502, {"status": "error", "message": "设备内部认证暂不可用"})
                return
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
    update_state_fields({})
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
