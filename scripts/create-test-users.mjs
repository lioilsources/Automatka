#!/usr/bin/env node
// Vytvoří testovací dospělé přes Supabase Auth Admin API. Děti účet nemají.
// Použití:
//   node --env-file=.env scripts/create-test-users.mjs

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SECRET_KEY;

if (!url || !key) {
  console.error('Chybí SUPABASE_URL nebo SUPABASE_SECRET_KEY');
  process.exit(1);
}

const password = 'Automatka123!';
const users = ['jana', 'petr', 'babi'].map((n) => ({ email: `${n}@automatka.test`, password }));

// sb_secret_… není JWT, patří jen do apikey; legacy service_role JWT chce i Bearer.
const headers = {
  apikey: key,
  ...(key.startsWith('eyJ') ? { Authorization: `Bearer ${key}` } : {}),
  'Content-Type': 'application/json',
};

async function existing() {
  const res = await fetch(`${url}/auth/v1/admin/users?per_page=200`, { headers });
  if (!res.ok) throw new Error(`Výpis uživatelů selhal: ${res.status} ${await res.text()}`);
  const body = await res.json();
  return new Map((body.users ?? []).map((u) => [u.email, u.id]));
}

const already = await existing();
let created = 0;

for (const u of users) {
  if (already.has(u.email)) {
    console.log(`= ${u.email.padEnd(24)} už existuje  ${already.get(u.email)}`);
    continue;
  }
  const res = await fetch(`${url}/auth/v1/admin/users`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ email: u.email, password: u.password, email_confirm: true }),
  });
  const body = await res.json();
  if (!res.ok) {
    console.error(`! ${u.email.padEnd(24)} SELHALO  ${JSON.stringify(body)}`);
    process.exitCode = 1;
    continue;
  }
  console.log(`+ ${u.email.padEnd(24)} vytvořen     ${body.id}`);
  created++;
}

console.log(`\nHotovo — ${created} nových, ${users.length - created} už existovalo.`);
console.log('Další krok: spusť supabase/seed.sql (dohledá si UUID podle e-mailu).');
