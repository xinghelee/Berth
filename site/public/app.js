// Berth 官网交互:hero 终端演示 + 下载按钮状态 + 候补表单

// ---------- hero 终端打字演示 ----------
// 剧本还原真实使用流:连接(Touch ID + 通道复用)→ 执行命令 → OSC 133 退出码
const SCRIPT = [
  { text: '正在连接 daowei-prod:22 …', cls: 't-info', mode: 'instant', pause: 700 },
  { text: '🔑 Touch ID 已验证 · id_ed25519', cls: 't-info', mode: 'instant', pause: 500 },
  { text: '✓ 已连接 · 复用现有通道 · 84ms', cls: 't-ok', mode: 'instant', pause: 900 },
  { text: ' ', cls: 't-muted', mode: 'instant', pause: 100 },
  { prompt: 'zc@daowei-prod:~ ❯ ', text: 'docker compose up -d', mode: 'type', pause: 600 },
  { text: '[+] Running 3/3', cls: 't-muted', mode: 'instant', pause: 250 },
  { text: ' ✔ Container web      Started', cls: 't-muted', mode: 'instant', pause: 200 },
  { text: ' ✔ Container postgres Started', cls: 't-muted', mode: 'instant', pause: 200 },
  { text: ' ✔ Container redis    Started', cls: 't-muted', mode: 'instant', pause: 500 },
  { text: '✓ 0 · 2.1s', cls: 't-ok', mode: 'instant', pause: 1400 },
]

function runTerminal() {
  const term = document.getElementById('term-live')
  if (!term) return
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches

  const finalRender = () => {
    term.replaceChildren()
    for (const step of SCRIPT) appendLine(term, step, step.text)
    appendCursorLine(term)
  }
  if (reduced) return finalRender()

  let i = 0
  const next = () => {
    if (i >= SCRIPT.length) {
      appendCursorLine(term)
      return
    }
    const step = SCRIPT[i++]
    if (step.mode === 'type') {
      const line = appendLine(term, step, '')
      const target = line.querySelector('.typed')
      let pos = 0
      const tick = () => {
        target.textContent = step.text.slice(0, ++pos)
        if (pos < step.text.length) setTimeout(tick, 34 + Math.random() * 40)
        else setTimeout(next, step.pause)
      }
      tick()
    } else {
      appendLine(term, step, step.text)
      setTimeout(next, step.pause)
    }
  }
  setTimeout(next, 600)
}

function appendLine(term, step, text) {
  const line = document.createElement('span')
  line.className = 't-line' + (step.cls ? ` ${step.cls}` : '')
  if (step.prompt) {
    const p = document.createElement('span')
    p.className = 't-prompt'
    p.textContent = step.prompt
    line.appendChild(p)
    const t = document.createElement('span')
    t.className = 'typed'
    t.textContent = text
    line.appendChild(t)
  } else {
    line.textContent = text
  }
  term.appendChild(line)
  return line
}

function appendCursorLine(term) {
  const line = document.createElement('span')
  line.className = 't-line'
  const p = document.createElement('span')
  p.className = 't-prompt'
  p.textContent = 'zc@daowei-prod:~ ❯ '
  const c = document.createElement('span')
  c.className = 'cursor'
  line.append(p, c)
  term.appendChild(line)
}

// ---------- 下载按钮:根据发布状态切换 ----------

async function setupDownload() {
  let release = { available: false }
  try {
    release = await (await fetch('/api/release')).json()
  } catch { /* 保持默认 */ }

  const note = document.querySelector('[data-release-note]')
  if (release.available && release.version && note) {
    note.textContent = `v${release.version} · Apple Silicon & Intel · Developer ID 签名与公证`
  }
  if (!release.available) {
    if (note) note.textContent = '正式版打包中 · 留下邮箱第一时间获取'
    document.querySelectorAll('[data-download]').forEach((el) => {
      el.addEventListener('click', (e) => {
        e.preventDefault()
        document.getElementById('waitlist')?.scrollIntoView({ behavior: 'smooth', block: 'center' })
        document.getElementById('wl-email')?.focus({ preventScroll: true })
      })
    })
  }
}

// ---------- 候补表单 ----------

function setupWaitlist() {
  const form = document.getElementById('waitlist')
  if (!form) return
  const msg = form.querySelector('.waitlist-msg')
  form.addEventListener('submit', async (e) => {
    e.preventDefault()
    const email = form.email.value.trim()
    msg.classList.remove('error')
    msg.textContent = '提交中…'
    try {
      const res = await fetch('/api/waitlist', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ email, source: 'landing' }),
      })
      const data = await res.json()
      if (data.ok) {
        msg.textContent = data.already ? '这个邮箱已经在列表里了,发布时会通知你。' : '已加入,发布时第一时间通知你。'
        form.email.value = ''
      } else {
        msg.classList.add('error')
        msg.textContent = data.error || '提交失败,请稍后再试'
      }
    } catch {
      msg.classList.add('error')
      msg.textContent = '网络异常,请稍后再试'
    }
  })
}

runTerminal()
setupDownload()
setupWaitlist()
