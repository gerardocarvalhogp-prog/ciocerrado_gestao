// Configuracao central — nada de credencial literal aqui, so leitura de
// variavel de ambiente, mesmo padrao do integracao.py. Ver .env.example
// pra lista completa e README.md pra onde cada uma vem.
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const AQUI = dirname(fileURLToPath(import.meta.url));

// Nenhum script deste modulo (obter-token, conectar, start) jamais leu
// o .env pra dentro do process.env — todos so' faziam process.env.X
// direto, contando com algo externo carregar o arquivo primeiro, e
// nada carregava (achado em 28/09/2026, testando de verdade fora do
// sandbox: GOOGLE_CLIENT_ID/SECRET preenchidos no .env, e o script
// via os dois como vazio). process.loadEnvFile() e' nativo do Node
// (>=20.6, por isso o bump em engines.node no package.json) e nao
// precisa de dependencia nova. Falha em silencio se o arquivo nao
// existir de proposito: na VPS (ver README, "Migracao pra VPS") as
// variaveis vem do systemd/pm2, sem .env nenhum no disco — exigir o
// arquivo ali quebraria um jeito de rodar que ja e' suportado.
try {
  process.loadEnvFile(resolve(AQUI, ".env"));
} catch (e) {
  if (e.code !== "ENOENT") throw e;
}

function obrigatoria(nome) {
  const v = process.env[nome];
  if (!v) throw new Error(`Falta a variavel de ambiente ${nome} — ver .env.example.`);
  return v;
}

// WHATSAPP_POLL_INTERVALO_MS mal formado (texto, vazio-apos-trim, etc)
// vira NaN em Number(...) — e um NaN passado pro setTimeout do loop de
// poll em index.js dispara IMEDIATAMENTE, a cada iteracao, sem nenhum
// atraso: um martelo de requisicoes no Postgres em vez de um poll a
// cada 15s. Falha alto e cedo em vez de degradar em silencio.
const pollIntervaloMs = Number(process.env.WHATSAPP_POLL_INTERVALO_MS || 15000);
if (!Number.isFinite(pollIntervaloMs) || pollIntervaloMs <= 0) {
  throw new Error(
    `WHATSAPP_POLL_INTERVALO_MS invalido: "${process.env.WHATSAPP_POLL_INTERVALO_MS}" — precisa ser um numero positivo de milissegundos.`
  );
}

export const config = Object.freeze({
  // MODO=teste (padrao, de proposito — nunca cria grupo real nem grava
  // contato real por acidente) ou MODO=producao. So producao chama a
  // API de verdade do WhatsApp e do Google.
  modo: (process.env.WHATSAPP_MODO || "teste").trim().toLowerCase(),

  supabaseUrl: process.env.SUPABASE_URL || "",
  supabaseServiceKey: process.env.SUPABASE_SERVICE_KEY || "",

  // Pasta onde a sessao do Baileys fica salva (multi-file auth state).
  // Parametrizada de proposito: na maquina do organizador aponta pra
  // uma pasta local qualquer; na migracao pra VPS so muda essa
  // variavel de ambiente pro caminho do volume persistente — nao
  // precisa reescrever nada do codigo de conexao.
  sessaoDir: resolve(AQUI, process.env.WHATSAPP_SESSAO_DIR || "./sessao"),

  // Nome/foto do perfil do numero operacional — configurado na
  // primeira conexao (ver conectar.js), pra nao aparecer como numero
  // desconhecido administrando o grupo.
  perfilNome: process.env.WHATSAPP_PERFIL_NOME || "CIO Cerrado",
  perfilFotoPath: process.env.WHATSAPP_PERFIL_FOTO_PATH || "",

  pollIntervaloMs,

  google: Object.freeze({
    clientId: process.env.GOOGLE_CLIENT_ID || "",
    clientSecret: process.env.GOOGLE_CLIENT_SECRET || "",
    // Obtido uma vez, na mao, por um consentimento OAuth de um usuario
    // real do Google Workspace do CIO Cerrado — nao da pra usar service
    // account pura aqui pelo mesmo motivo do robo-fichas no Drive (ver
    // CLAUDE.md): service account nao tem agenda de contatos propria.
    // Ver README.md secao "Google People API" pra como gerar.
    refreshToken: process.env.GOOGLE_REFRESH_TOKEN || "",
  }),
});

export function exigirConfigProducao() {
  obrigatoria("SUPABASE_URL");
  obrigatoria("SUPABASE_SERVICE_KEY");
  if (config.modo === "producao") {
    obrigatoria("GOOGLE_CLIENT_ID");
    obrigatoria("GOOGLE_CLIENT_SECRET");
    obrigatoria("GOOGLE_REFRESH_TOKEN");
  }
}
