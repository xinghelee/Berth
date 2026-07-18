// Berth 官网交互:下载按钮状态 + 语言偏好记忆

const LANG = (document.documentElement.lang || 'en').toLowerCase().startsWith('zh') ? 'zh' : 'en'

const T = {
  en: {
    note: (v) => `v${v} · Apple Silicon & Intel · Developer ID signed & notarized`,
    noRelease: 'Release in the works · check back soon',
  },
  zh: {
    note: (v) => `v${v} · Apple Silicon & Intel · Developer ID 签名与公证`,
    noRelease: '正式版打包中 · 敬请期待',
  },
}[LANG]

// ---------- 下载按钮:根据发布状态切换 ----------

async function setupDownload() {
  let release = { available: false }
  try {
    release = await (await fetch('/api/release')).json()
  } catch { /* 保持默认 */ }

  const note = document.querySelector('[data-release-note]')
  if (release.available && release.version && note) {
    note.textContent = T.note(release.version)
  }
  if (!release.available) {
    if (note) note.textContent = T.noRelease
    document.querySelectorAll('[data-download]').forEach((el) => {
      el.addEventListener('click', (e) => {
        e.preventDefault()
        note?.scrollIntoView({ behavior: 'smooth', block: 'center' })
      })
    })
  }
}

// ---------- 语言切换:记住手动选择,首访自动跳转只在未选择时生效 ----------

function setupLangSwitch() {
  document.querySelectorAll('[data-lang-switch]').forEach((el) => {
    el.addEventListener('click', () => {
      try { localStorage.setItem('berth-lang', el.dataset.langSwitch) } catch { /* 隐私模式忽略 */ }
    })
  })
}

setupDownload()
setupLangSwitch()
