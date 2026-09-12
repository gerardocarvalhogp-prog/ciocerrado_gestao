// Sincronizacao com a agenda Google (People API) — so cria quem esta
// ausente. Compara por telefone E.164, ja normalizado no banco
// (gestores.telefone_e164, gerado por norm_telefone_e164 no Postgres).
//
// [PREENCHER] GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET / GOOGLE_REFRESH_TOKEN.
// Nao da pra usar uma service account pura aqui: ela nao tem agenda de
// contatos propria pra escrever, mesmo gotcha ja documentado no
// CLAUDE.md pro robo-fichas do Drive (403 storageQuotaExceeded).
// O caminho e OAuth de um usuario real do Workspace do CIO Cerrado,
// consentido uma vez, com o refresh token guardado aqui — ver
// README.md secao "Primeira autorizacao do Google People API".
import { google } from "googleapis";
import { config } from "./config.js";

function clienteOAuth() {
  const oauth2 = new google.auth.OAuth2(config.google.clientId, config.google.clientSecret);
  oauth2.setCredentials({ refresh_token: config.google.refreshToken });
  return oauth2;
}

// Le TODOS os contatos com telefone de uma vez (pessoas, nao paginas) —
// mais confiavel que people.searchContacts pra achar por telefone exato:
// o indice de busca do Google pode demorar a refletir contato recem-
// criado, e aqui a decisao "existe ou nao" precisa ser exata, nao
// aproximada. Cacheia por chamada do sync (nao entre chamadas — a
// agenda muda entre um jantar e outro).
async function mapaDeTelefones(people) {
  const mapa = new Map(); // telefone_e164 (so digitos) -> resourceName
  let pageToken;
  do {
    const { data } = await people.people.connections.list({
      resourceName: "people/me",
      personFields: "phoneNumbers,names",
      pageSize: 1000,
      pageToken,
    });
    for (const pessoa of data.connections || []) {
      for (const tel of pessoa.phoneNumbers || []) {
        const digitos = (tel.value || "").replace(/\D/g, "");
        // ultimos 10-11 digitos cobrem o numero em si, sem depender de
        // o contato ja estar salvo com +55 na frente ou nao
        const chave = digitos.slice(-11);
        if (chave) mapa.set(chave, pessoa.resourceName);
      }
    }
    pageToken = data.nextPageToken;
  } while (pageToken);
  return mapa;
}

/**
 * @param {{jantar_convidado_id: string, nome: string, telefone_e164: string}[]} convidados
 *   ja filtrado pra quem tem telefone e ainda nao foi sincronizado.
 * @param {(acao: string, detalhe: object) => void} log
 * @returns {Promise<{jantar_convidado_id: string, resource_name: string}[]>}
 */
export async function sincronizarContatos(convidados, log) {
  if (convidados.length === 0) return [];

  if (config.modo !== "producao") {
    log("contato_sincronizado", { modo: "teste", quantidade: convidados.length,
      nota: "nenhuma chamada real ao Google People API — resource_name simulado" });
    return convidados.map(c => ({
      jantar_convidado_id: c.jantar_convidado_id,
      resource_name: `TESTE-contato-${c.jantar_convidado_id.slice(0, 8)}`,
    }));
  }

  const auth = clienteOAuth();
  const people = google.people({ version: "v1", auth });

  const existentes = await mapaDeTelefones(people);
  const resultado = [];

  for (const c of convidados) {
    const chave = c.telefone_e164.slice(-11);
    const jaExiste = existentes.get(chave);

    if (jaExiste) {
      resultado.push({ jantar_convidado_id: c.jantar_convidado_id, resource_name: jaExiste });
      continue;
    }

    const { data } = await people.people.createContact({
      requestBody: {
        names: [{ givenName: c.nome }],
        phoneNumbers: [{ value: `+${c.telefone_e164}` }],
      },
    });
    log("contato_criado", { nome: c.nome, resource_name: data.resourceName });
    resultado.push({ jantar_convidado_id: c.jantar_convidado_id, resource_name: data.resourceName });
  }

  return resultado;
}
