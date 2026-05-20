const state = {
  url: localStorage.getItem('vice.supabaseUrl') || 'https://ltbsxbvfsxtnharjvqcm.supabase.co',
  key: localStorage.getItem('vice.supabaseKey') || '',
}

const elements = {
  status: document.querySelector('#status'),
  url: document.querySelector('#supabase-url'),
  key: document.querySelector('#supabase-key'),
  save: document.querySelector('#save-config'),
  refresh: document.querySelector('#refresh'),
  districtCount: document.querySelector('#district-count'),
  avgHeat: document.querySelector('#avg-heat'),
  avgPolice: document.querySelector('#avg-police'),
  agentCount: document.querySelector('#agent-count'),
  districtTable: document.querySelector('#district-table'),
  marketTable: document.querySelector('#market-table'),
  cryptoTable: document.querySelector('#crypto-table'),
  incidentTable: document.querySelector('#incident-table'),
  agentRoles: document.querySelector('#agent-roles'),
}

elements.url.value = state.url
elements.key.value = state.key

function setStatus(message) {
  elements.status.textContent = message
}

function api(path) {
  const url = `${state.url.replace(/\/$/, '')}/rest/v1/${path}`
  return fetch(url, {
    headers: {
      apikey: state.key,
      Authorization: `Bearer ${state.key}`,
    },
  }).then(async (response) => {
    const payload = await response.json().catch(() => null)
    if (!response.ok) {
      throw new Error(payload?.message || payload?.hint || response.statusText)
    }
    return payload
  })
}

function number(value) {
  return Number(value ?? 0)
}

function average(rows, field) {
  if (!rows.length) return 0
  return Math.round(rows.reduce((sum, row) => sum + number(row[field]), 0) / rows.length)
}

function classForPressure(value) {
  if (value >= 70) return 'danger'
  if (value >= 40) return 'warn'
  return 'ok'
}

function money(value) {
  return new Intl.NumberFormat('en-US').format(number(value))
}

function renderDistricts(rows) {
  elements.districtCount.textContent = rows.length
  elements.avgHeat.textContent = average(rows, 'heat_level')
  elements.avgPolice.textContent = average(rows, 'police_presence')
  elements.districtTable.innerHTML = rows.map((row) => `
    <tr>
      <td><strong>${row.name}</strong></td>
      <td><span class="pill ${classForPressure(row.heat_level)}">${row.heat_level}</span></td>
      <td><span class="pill ${classForPressure(row.crime_pressure)}">${row.crime_pressure}</span></td>
      <td><span class="pill ${classForPressure(row.police_presence)}">${row.police_presence}</span></td>
      <td><span class="pill ${classForPressure(row.checkpoint_level)}">${row.checkpoint_level}</span></td>
      <td>${Number(row.supply_disruption).toFixed(3)}</td>
    </tr>
  `).join('')
}

function renderMarket(rows) {
  elements.marketTable.innerHTML = rows.map((row) => `
    <tr>
      <td><strong>${row.display_name}</strong></td>
      <td>${row.category}</td>
      <td>${money(row.current_price)}</td>
      <td>${row.legal ? 'yes' : 'no'}</td>
    </tr>
  `).join('')
}

function renderCrypto(rows) {
  elements.cryptoTable.innerHTML = rows.map((row) => `
    <tr>
      <td><strong>${row.from_currency}/${row.to_currency}</strong></td>
      <td>${Number(row.rate).toFixed(6)}</td>
      <td>${number(row.spread_bps) / 100}%</td>
    </tr>
  `).join('')
}

function renderIncidents(rows) {
  elements.incidentTable.innerHTML = rows.map((row) => `
    <tr>
      <td><strong>${row.district_id}</strong></td>
      <td>${row.incident_type}</td>
      <td><span class="pill ${classForPressure(row.severity)}">${row.severity}</span></td>
      <td>${new Date(row.created_at).toLocaleString()}</td>
    </tr>
  `).join('')
}

function renderAgents(rows) {
  elements.agentCount.textContent = rows.length
  const counts = rows.reduce((acc, row) => {
    acc[row.role] = (acc[row.role] || 0) + 1
    return acc
  }, {})
  const max = Math.max(...Object.values(counts), 1)
  elements.agentRoles.innerHTML = Object.entries(counts)
    .sort((a, b) => b[1] - a[1])
    .map(([role, count]) => `
      <div class="role-row">
        <strong>${role}</strong>
        <div class="bar"><span style="width:${(count / max) * 100}%"></span></div>
        <span>${count}</span>
      </div>
    `)
    .join('')
}

async function refresh() {
  if (!state.url || !state.key) {
    setStatus('Paste Supabase URL and publishable key to connect.')
    return
  }

  setStatus('Loading live economy state...')
  const [districts, market, crypto, incidents, agents] = await Promise.all([
    api('districts?select=district_id,name,heat_level,crime_pressure,police_presence,checkpoint_level,supply_disruption&order=district_id.asc'),
    api('market_items?select=item_id,display_name,category,current_price,legal&active=eq.true&order=item_id.asc'),
    api('crypto_exchange_rates?select=from_currency,to_currency,rate,spread_bps&active=eq.true&order=from_currency.asc'),
    api('police_incidents?select=district_id,incident_type,severity,created_at&order=created_at.desc&limit=10'),
    api('agents?select=id,role,district_id&active=eq.true'),
  ])

  renderDistricts(districts)
  renderMarket(market)
  renderCrypto(crypto)
  renderIncidents(incidents)
  renderAgents(agents)
  setStatus(`Live as of ${new Date().toLocaleTimeString()}`)
}

elements.save.addEventListener('click', () => {
  state.url = elements.url.value.trim()
  state.key = elements.key.value.trim()
  localStorage.setItem('vice.supabaseUrl', state.url)
  localStorage.setItem('vice.supabaseKey', state.key)
  refresh().catch((error) => setStatus(`Load failed: ${error.message}`))
})

elements.refresh.addEventListener('click', () => {
  refresh().catch((error) => setStatus(`Load failed: ${error.message}`))
})

refresh().catch((error) => setStatus(`Load failed: ${error.message}`))
