// Acesso ao PostgREST — mesmo padrao da classe Supa em integracao.py
// (headers Accept-Profile/Content-Profile pro schema gestao, chave
// service_role). Reescrito em JS aqui porque Baileys e' Node/TS puro,
// sem equivalente Python maduro — ver Fase 1 do modulo.
import { config } from "./config.js";

// Sem timeout, um PostgREST que trava (rede instavel, banco sob carga)
// pendura a requisicao pra sempre — e como o daemon (index.js) faz
// await sequencial de rpc() dentro do laco de poll, isso trava o
// processo inteiro, sem log, sem crash, so um daemon morto em pe.
const TIMEOUT_MS = 20_000;

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
  const controlador = new AbortController();
  const timeout = setTimeout(() => controlador.abort(), TIMEOUT_MS);
  let r;
  try {
    r = await fetch(url, { ...opcoes, headers: { ...headers(), ...(opcoes.headers || {}) }, signal: controlador.signal });
  } catch (e) {
    if (e.name === "AbortError") {
      throw new Error(`${caminho}: sem resposta do PostgREST em ${TIMEOUT_MS}ms`);
    }
    throw new Error(`${caminho}: falha de rede — ${e.message}`);
  } finally {
    clearTimeout(timeout);
  }
  const texto = await r.text();
  if (!r.ok) {
    throw new Error(`${caminho}: HTTP ${r.status} — ${texto.slice(0, 500)}`);
  }
  return texto ? JSON.parse(texto) : null;
}

export async function rpc(nome, args = {}) {
  return chamar(`rpc/${nome}`, { method: "POST", body: JSON.stringify(args) });
}
