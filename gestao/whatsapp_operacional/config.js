// Configuracao central — nada de credencial literal aqui, so leitura de
// variavel de ambiente, mesmo padrao do integracao.py. Ver .env.example
// pra lista completa e README.md pra onde cada uma vem.
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const AQUI = dirname(fileURLToPath(import.meta.url));

function obrigatoria(nome) {
  const v = process.env[nome];
  if (!v) throw new Error(`Falta a variavel de ambiente ${nome} — ver .env.example.`);
  return v;
}

export const config = {
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

  pollIntervaloMs: Number(process.env.WHATSAPP_POLL_INTERVALO_MS || 15000),

  google: {
    clientId: process.env.GOOGLE_CLIENT_ID || "",
    clientSecret: process.env.GOOGLE_CLIENT_SECRET || "",
    // Obtido uma vez, na mao, por um consentimento OAuth de um usuario
    // real do Google Workspace do CIO Cerrado — nao da pra usar service
    // account pura aqui pelo mesmo motivo do robo-fichas no Drive (ver
    // CLAUDE.md): service account nao tem agenda de contatos propria.
    // Ver README.md secao "Google People API" pra como gerar.
    refreshToken: process.env.GOOGLE_REFRESH_TOKEN || "",
  },
};

export function exigirConfigProducao() {
  obrigatoria("SUPABASE_URL");
  obrigatoria("SUPABASE_SERVICE_KEY");
  if (config.modo === "producao") {
    obrigatoria("GOOGLE_CLIENT_ID");
    obrigatoria("GOOGLE_CLIENT_SECRET");
    obrigatoria("GOOGLE_REFRESH_TOKEN");
  }
}
