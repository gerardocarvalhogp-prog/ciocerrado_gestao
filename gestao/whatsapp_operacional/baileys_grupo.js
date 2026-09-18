// Camada Baileys — SO cria grupo, vira admin, gera link. Nunca chama
// nada de envio de mensagem: essa capacidade nem e usada aqui de
// proposito, e o pacote inteiro so existe nesta maquina/processo pra
// isso (ver Fase 1: numero 1, Cloud API, e quem manda mensagem).
import { makeWASocket, useMultiFileAuthState, DisconnectReason, fetchLatestBaileysVersion }
  from "@whiskeysockets/baileys";
import pino from "pino";
import qrcodeTerminal from "qrcode-terminal";
import { config } from "./config.js";

const logger = pino({ level: process.env.WHATSAPP_LOG_LEVEL || "warn" });

// Backoff exponencial com teto e jitter pra reconexao — sem isso, uma
// rejeicao instantanea do WhatsApp (numero limitado/suspenso,
// instabilidade do lado deles) vira um laco fechado de reconexao na
// velocidade maxima do event loop, martelando os servidores deles.
// Isso e' exatamente o tipo de comportamento que aumenta o risco de
// banimento do numero — o oposto do que este modulo inteiro existe
// pra evitar (achado na auditoria de 18/09/2026).
const RECONEXAO_BASE_MS = 2000;
const RECONEXAO_TETO_MS = 5 * 60 * 1000;
let tentativasReconexao = 0;

function proximoAtrasoReconexao() {
  const exponencial = RECONEXAO_BASE_MS * 2 ** tentativasReconexao;
  const comTeto = Math.min(exponencial, RECONEXAO_TETO_MS);
  const jitter = comTeto * (0.5 + Math.random() * 0.5); // 50%-100% do valor, pra nao sincronizar retries
  tentativasReconexao++;
  return Math.round(jitter);
}

/**
 * Conecta (ou reconecta) o numero operacional. Em modo teste nao chama
 * isso nunca — quem decide e o chamador (index.js/conectar.js).
 * @param {{aoConectar?: () => void, aoPrecisarQR?: (qr: string) => void, aoCair?: (motivo: string) => void}} eventos
 */
export async function conectar(eventos = {}) {
  const { state, saveCreds } = await useMultiFileAuthState(config.sessaoDir);
  const { version } = await fetchLatestBaileysVersion();

  const sock = makeWASocket({
    auth: state,
    logger,
    version,
    // QR tratado na mao (sock.ev abaixo) em vez de printQRInTerminal —
    // opcao ficou inconsistente entre versoes do Baileys, isto funciona
    // em qualquer uma.
  });

  sock.ev.on("creds.update", saveCreds);

  sock.ev.on("connection.update", (update) => {
    const { connection, lastDisconnect, qr } = update;

    if (qr) {
      qrcodeTerminal.generate(qr, { small: true });
      eventos.aoPrecisarQR?.(qr);
    }

    if (connection === "open") {
      tentativasReconexao = 0; // conexao de verdade reseta o contador de backoff
      eventos.aoConectar?.(sock);
    }

    if (connection === "close") {
      const codigo = lastDisconnect?.error?.output?.statusCode;
      const deslogado = codigo === DisconnectReason.loggedOut;
      eventos.aoCair?.(deslogado ? "deslogado" : `codigo_${codigo}`);
      // Deslogado (QR revogado no aparelho, etc.) exige nova primeira
      // conexao na mao — nao adianta reconectar sozinho. Qualquer outro
      // motivo (rede, restart) reconecta automatico, reaproveitando a
      // sessao salva, sem pedir QR de novo — mas so' depois do atraso
      // de backoff, nunca na hora.
      if (!deslogado) {
        const atraso = proximoAtrasoReconexao();
        logger.warn({ atraso, tentativa: tentativasReconexao }, "reconectando apos atraso de backoff");
        setTimeout(() => { conectar(eventos); }, atraso);
      }
    }
  });

  return sock;
}

/**
 * Cria um grupo com o numero operacional como UNICO membro inicial —
 * ninguem entra por automacao, ingresso e sempre por link (regra
 * central do desenho, ver Fase 1). O Baileys aceita array de
 * participantes vazio (o criador sempre vira membro/admin sozinho);
 * NAO testado contra o WhatsApp de verdade nesta sessao de
 * desenvolvimento (sandbox sem acesso a numero real) — se uma versao
 * futura do Baileys passar a exigir >=1 participante, isso aparece
 * aqui como excecao clara, nunca como grupo criado errado.
 *
 * @param {import("@whiskeysockets/baileys").WASocket} sock
 * @param {string} nomeDoGrupo
 * @returns {Promise<{jid: string, inviteLink: string}>}
 */
export async function criarGrupoVazio(sock, nomeDoGrupo) {
  const metadata = await sock.groupCreate(nomeDoGrupo, []);
  const codigo = await sock.groupInviteCode(metadata.id);
  return { jid: metadata.id, inviteLink: `https://chat.whatsapp.com/${codigo}` };
}

/**
 * Define nome e foto de perfil do numero operacional. A foto e' sempre
 * lida do disco e enviada como buffer — a assinatura de
 * updateProfilePicture aceita `{ url }` OU `{ buffer }`, nunca os dois
 * ao mesmo tempo; passar ambos e' comportamento nao documentado que
 * depende de qual chave a versao instalada do Baileys checa primeiro
 * (achado na auditoria de 18/09/2026).
 */
export async function definirPerfil(sock) {
  if (config.perfilNome) {
    await sock.updateProfileName(config.perfilNome);
  }
  if (config.perfilFotoPath) {
    const { readFileSync } = await import("node:fs");
    await sock.updateProfilePicture(sock.user.id, { buffer: readFileSync(config.perfilFotoPath) });
  }
}
