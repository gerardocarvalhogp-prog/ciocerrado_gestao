// Daemon de vida longa: poll em jantar_grupos, sincroniza contato no
// Google, cria o grupo (ou simula, em modo teste), enfileira o link
// pro numero 1 (Cloud API) entregar. Nunca manda mensagem daqui.
//
// USO:  npm start   (depois de `npm run conectar` pelo menos uma vez,
//                     se WHATSAPP_MODO=producao)
import { config, exigirConfigProducao } from "./config.js";
import { rpc } from "./supa.js";
import { sincronizarContatos } from "./google_contacts.js";
import { conectar, criarGrupoVazio } from "./baileys_grupo.js";

exigirConfigProducao();

const emTeste = config.modo !== "producao";
console.log(`Daemon iniciando em modo ${emTeste ? "TESTE (nada real é criado/enviado)" : "PRODUÇÃO"}.`);

let sock = null;
if (!emTeste) {
  sock = await conectar({
    aoConectar() { console.log("Conectado ao WhatsApp."); },
    aoCair(motivo) { console.log(`Conexão caiu (${motivo}) — Baileys tenta reconectar sozinho quando não é logout.`); },
  });
}

async function registrarLog(jantarId, acao, detalhe) {
  console.log(`[log] ${acao}`, detalhe ? JSON.stringify(detalhe) : "");
  await rpc("whatsapp_log_registrar", { p_jantar_id: jantarId, p_acao: acao, p_detalhe: detalhe ?? null })
    .catch((e) => console.warn("Não consegui gravar log (seguindo mesmo assim):", e.message));
}

async function processarSincronizacao(jantar) {
  const convidados = await rpc("jantar_grupo_convidados_para_sincronizar", { p_jantar_id: jantar.jantar_id });

  const semTelefone = convidados.filter((c) => !c.telefone_e164);
  const pendentes = convidados.filter((c) => c.telefone_e164 && !c.ja_sincronizado);

  if (semTelefone.length > 0) {
    await registrarLog(jantar.jantar_id, "convidados_sem_telefone", {
      quantidade: semTelefone.length,
      nomes: semTelefone.map((c) => c.nome),
    });
  }

  const resultados = await sincronizarContatos(
    pendentes.map((c) => ({ jantar_convidado_id: c.jantar_convidado_id, nome: c.nome, telefone_e164: c.telefone_e164 })),
    (acao, detalhe) => registrarLog(jantar.jantar_id, acao, detalhe)
  );

  for (const r of resultados) {
    await rpc("jantar_convidado_marcar_contato_sincronizado", {
      p_id: r.jantar_convidado_id, p_resource_name: r.resource_name,
    });
  }

  await rpc("jantar_grupo_daemon_avancar", { p_jantar_id: jantar.jantar_id, p_status: "criando_grupo" });
  await registrarLog(jantar.jantar_id, "contatos_sincronizados", {
    sincronizados_agora: resultados.length, sem_telefone: semTelefone.length,
  });
}

async function processarCriacaoDeGrupo(jantar) {
  const nomeDoGrupo = `Jantar CIO Cerrado — ${jantar.patrocinador_nome}`;

  let jid, inviteLink;
  if (emTeste) {
    jid = `TESTE-${jantar.jantar_id.slice(0, 8)}@g.us`;
    inviteLink = `https://chat.whatsapp.com/TESTE-${jantar.jantar_id.slice(0, 8)}`;
    await registrarLog(jantar.jantar_id, "grupo_criado", { modo: "teste", nome: nomeDoGrupo, jid, inviteLink });
  } else {
    ({ jid, inviteLink } = await criarGrupoVazio(sock, nomeDoGrupo));
    await registrarLog(jantar.jantar_id, "grupo_criado", { nome: nomeDoGrupo, jid, inviteLink });
  }

  await rpc("jantar_grupo_daemon_avancar", {
    p_jantar_id: jantar.jantar_id, p_status: "criado", p_group_jid: jid, p_invite_link: inviteLink,
  });

  const n = await rpc("jantar_grupo_enfileirar_convites", { p_jantar_id: jantar.jantar_id });
  await registrarLog(jantar.jantar_id, "convites_enfileirados", { quantidade: n, modo: emTeste ? "teste" : "producao" });
}

async function processarPendentes() {
  const pendentes = await rpc("jantar_grupos_pendentes");
  for (const jantar of pendentes) {
    try {
      if (jantar.status === "sincronizando_contatos") await processarSincronizacao(jantar);
      else if (jantar.status === "criando_grupo") await processarCriacaoDeGrupo(jantar);
    } catch (e) {
      console.error(`Erro processando jantar ${jantar.jantar_id} (${jantar.status}):`, e);
      await rpc("jantar_grupo_daemon_avancar", {
        p_jantar_id: jantar.jantar_id, p_status: "erro", p_erro: String(e.message || e).slice(0, 500),
      }).catch(() => {});
      await registrarLog(jantar.jantar_id, "grupo_erro", { etapa: jantar.status, erro: String(e.message || e) });
    }
  }
}

console.log(`Poll a cada ${config.pollIntervaloMs}ms. Ctrl+C pra parar.`);
// eslint-disable-next-line no-constant-condition
while (true) {
  await processarPendentes().catch((e) => console.error("Erro no ciclo de poll:", e));
  await new Promise((r) => setTimeout(r, config.pollIntervaloMs));
}
