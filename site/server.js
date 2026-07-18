import { Hono } from 'hono'
import { serve } from '@hono/node-server'
import { serveStatic } from '@hono/node-server/serve-static'
import { addToWaitlist, recordEvent, lookupLicense, stats } from './db.js'

const PORT = Number(process.env.PORT || 8787)
// 发布 DMG 后配置(比如指向 GitHub Releases 或对象存储);未配置时前端显示"即将发布"
const DOWNLOAD_URL = process.env.DOWNLOAD_URL || ''
const APP_VERSION = process.env.APP_VERSION || ''
const ADMIN_TOKEN = process.env.ADMIN_TOKEN || ''

const app = new Hono()

// ---------- API ----------

app.get('/api/health', (c) => c.json({ ok: true }))

/// 发布信息:前端据此决定下载按钮形态
app.get('/api/release', (c) =>
  c.json({
    available: Boolean(DOWNLOAD_URL),
    version: APP_VERSION || null,
    requires: 'macOS 15+',
  })
)

/// 下载:计数后 302 到真实分发地址
app.get('/download', (c) => {
  recordEvent('download', { ua: c.req.header('user-agent') ?? '' })
  if (!DOWNLOAD_URL) return c.redirect('/')
  return c.redirect(DOWNLOAD_URL)
})

/// 邮箱候补:支付/发布开放时通知
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/
const rateBucket = new Map() // ip -> { count, resetAt }
function rateLimited(ip) {
  const now = Date.now()
  const slot = rateBucket.get(ip)
  if (!slot || now > slot.resetAt) {
    rateBucket.set(ip, { count: 1, resetAt: now + 60_000 })
    return false
  }
  slot.count += 1
  return slot.count > 5
}

app.post('/api/waitlist', async (c) => {
  const ip = c.req.header('x-forwarded-for')?.split(',')[0]?.trim() || 'local'
  if (rateLimited(ip)) return c.json({ ok: false, error: 'Too many requests — try again shortly' }, 429)

  let body
  try {
    body = await c.req.json()
  } catch {
    return c.json({ ok: false, error: 'Invalid request' }, 400)
  }
  const email = String(body?.email ?? '').trim().toLowerCase()
  if (!EMAIL_RE.test(email) || email.length > 254) {
    return c.json({ ok: false, error: 'Invalid email address' }, 400)
  }
  const added = addToWaitlist(email, String(body?.source ?? 'landing').slice(0, 32))
  return c.json({ ok: true, already: !added })
})

/// 许可校验:app 端激活时调用。支付接入前永远 not_found,但接口形状已定。
app.get('/api/license/verify', (c) => {
  const key = c.req.query('key')?.trim().toUpperCase() ?? ''
  if (!/^BERTH(-[A-Z0-9]{4}){3}$/.test(key)) {
    return c.json({ valid: false, reason: 'malformed' }, 400)
  }
  const license = lookupLicense(key)
  if (!license || license.status !== 'active') {
    return c.json({ valid: false, reason: 'not_found' }, 404)
  }
  return c.json({ valid: true, email: license.email, seats: license.seats })
})

// ---------- 支付占位(接入 Stripe/Paddle 时替换) ----------

app.post('/api/checkout', (c) =>
  c.json({ ok: false, error: 'Payments are not open yet — join the email list instead' }, 501)
)

app.post('/api/webhooks/payment', (c) => c.json({ ok: false, error: 'not implemented' }, 501))

// ---------- 运营 ----------

app.get('/api/admin/stats', (c) => {
  if (!ADMIN_TOKEN) return c.json({ error: 'admin disabled' }, 404)
  const auth = c.req.header('authorization') ?? ''
  if (auth !== `Bearer ${ADMIN_TOKEN}`) return c.json({ error: 'unauthorized' }, 401)
  return c.json(stats())
})

// ---------- 静态站点 ----------

app.use('/*', serveStatic({ root: './public' }))

serve({ fetch: app.fetch, port: PORT }, (info) => {
  console.log(`Berth site listening on http://localhost:${info.port}`)
  if (!DOWNLOAD_URL) console.log('DOWNLOAD_URL 未配置:下载按钮走候补模式')
  if (!ADMIN_TOKEN) console.log('ADMIN_TOKEN 未配置:/api/admin/stats 关闭')
})
