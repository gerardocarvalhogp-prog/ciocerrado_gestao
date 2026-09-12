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

let socketAtual = null;

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
      eventos.aoConectar?.(sock);
    }

    if (connection === "close") {
      const codigo = lastDisconnect?.error?.output?.statusCode;
      const deslogado = codigo === DisconnectReason.loggedOut;
      eventos.aoCair?.(deslogado ? "deslogado" : `codigo_${codigo}`);
      // Deslogado (QR revogado no aparelho, etc.) exige nova primeira
      // conexao na mao — nao adianta reconectar sozinho. Qualquer outro
      // motivo (rede, restart) reconecta automatico, reaproveitando a
      // sessao salva, sem pedir QR de novo.
      if (!deslogado) {
        conectar(eventos).then((s) => { socketAtual = s; });
      }
    }
  });

  socketAtual = sock;
  return sock;
}

export function socketConectado() {
  return socketAtual;
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

export async function definirPerfil(sock) {
  if (config.perfilNome) {
    await sock.updateProfileName(config.perfilNome);
  }
  if (config.perfilFotoPath) {
    const { readFileSync } = await import("node:fs");
    await sock.updateProfilePicture(sock.user.id, { url: config.perfilFotoPath, buffer: readFileSync(config.perfilFotoPath) });
  }
}
