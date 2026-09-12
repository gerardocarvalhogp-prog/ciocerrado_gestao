// Acesso ao PostgREST — mesmo padrao da classe Supa em integracao.py
// (headers Accept-Profile/Content-Profile pro schema gestao, chave
// service_role). Reescrito em JS aqui porque Baileys e' Node/TS puro,
// sem equivalente Python maduro — ver Fase 1 do modulo.
import { config } from "./config.js";

function headers() {
  return {
    "apikey": config.supabaseServiceKey,
    "Authorization": `Bearer ${config.supabaseServiceKey}`,
    "Content-Type": "application/json",
    "Accept-Profile": "gestao",
    "Content-Profile": "gestao",
  };
}

async function chamar(caminho, opcoes = {}) {
  const url = `${config.supabaseUrl.replace(/\/$/, "")}/rest/v1/${caminho}`;
  const r = await fetch(url, { ...opcoes, headers: { ...headers(), ...(opcoes.headers || {}) } });
  const texto = await r.text();
  if (!r.ok) {
    throw new Error(`${caminho}: HTTP ${r.status} — ${texto.slice(0, 500)}`);
  }
  return texto ? JSON.parse(texto) : null;
}

export async function rpc(nome, args = {}) {
  return chamar(`rpc/${nome}`, { method: "POST", body: JSON.stringify(args) });
}

export async function get(tabela, params = {}) {
  const qs = new URLSearchParams(params).toString();
  return chamar(`${tabela}${qs ? `?${qs}` : ""}`, { method: "GET" });
}
