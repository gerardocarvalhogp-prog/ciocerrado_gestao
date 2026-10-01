// =====================================================================
// SISTEMA DE GESTAO CIO CERRADO
// Recebe o callback do Autentique quando um documento e assinado, e
// marca o contrato como "assinado" no painel sem precisar mais rodar
// `integracao.py --status` na mao. Pedido do organizador em 01/10/2026
// ("contrato assinado ainda nao refletiu no painel").
//
// Formato do payload e nomes de evento conferidos na documentacao oficial
// (https://docs.autentique.com.br/api/integration-basics/webhooks) em
// 01/10/2026. Dois formatos de payload aparecem nos exemplos da propria
// doc para evento de documento (versoes diferentes da API, aparentemente):
//
//   evento.data.object.id   (exemplo mais antigo da doc)
//   evento.data.id          (exemplo mais recente da doc, "Document Object")
//
// extrairDocumentoId() tenta os dois. O ID do documento NAO e um UUID com
// hifen (ex.: "1cf7d351a96696fdf450ba893f6720463599dd8c34e0aeda803d") —
// o tipo GraphQL se chama "UUID" mas aceita essa string, confirmado pelo
// `document(id: UUID!)` que ler_status ja usa com sucesso em producao.
//
// Eventos de assinatura (signature.accepted etc.) trazem o documento pai
// como string solta em `evento.data.document`, nao aninhado.
//
// POR QUE AINDA RECONSULTA A API EM VEZ DE CONFIAR SO NO PAYLOAD
//
// Mesmo com o formato confirmado, o payload recebido continua sendo
// tratado so como um AVISO de "va conferir", nao como prova — a function
// sempre reconsulta a API GraphQL do Autentique (a MESMA consulta que
// ler_status, em integracao.py, ja usa) antes de marcar qualquer coisa.
// Isso mantem o MESMO criterio de "assinado" dos dois caminhos (webhook e
// --status manual): quando QUALQUER signatario assinou — nao so quando o
// documento inteiro fecha (document.finished exige TODOS, inclusive a
// testemunha/parte fixas desde 01/10/2026, o que demoraria mais que o
// necessario pra avisar o CIO). Tambem protege contra reentrega fora de
// ordem — a doc e explicita que a ordem de entrega NAO e garantida.
//
// AUTENTICACAO DO POST
//
// Duas camadas, ambas opcionais apenas na falta de configuracao — pelo
// menos uma tem que estar ativa (a function recusa rodar sem nenhuma):
//
//   1. Segredo compartilhado na URL (?chave=...) — funciona em qualquer
//      plano. Configure:
//        supabase secrets set AUTENTIQUE_WEBHOOK_SECRET=<valor-aleatorio-longo>
//      e cadastre a mesma URL+chave no painel do Autentique.
//   2. Assinatura HMAC-SHA256 no header `x-autentique-signature` — e a
//      forma que a doc deles recomenda, mas a opcao "Autenticacao" na
//      tela de cadastro do endpoint aparecia marcada como "Pro" (print
//      do organizador em 01/10/2026) — pode nao estar disponivel no
//      plano atual. Se um dia ativar, configure:
//        supabase secrets set AUTENTIQUE_WEBHOOK_SIGNING_SECRET=<o-secret-que-o-autentique-mostrar>
//      e a function passa a EXIGIR a assinatura valida (nao so aceitar
//      se vier), em vez de so conferir o ?chave= da URL.
//
// Devolve 200 ate para evento que nao reconhece (ID nao encontrado,
// contrato nao encontrado) — a doc deles reentrega automaticamente em
// 60s/120s/300s quando a resposta nao e 2xx, e reentregar nao resolveria
// um ID genuinamente desconhecido. So segredo/assinatura invalidos
// devolvem 401; falta de configuracao do servidor devolve 500 (essa sim
// vale a pena reentregar depois de configurar o secret).
// =====================================================================

const SUPABASE_URL      = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE      = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const AUTENTIQUE_TOKEN  = Deno.env.get("AUTENTIQUE_TOKEN") ?? "";
const WEBHOOK_SECRET    = Deno.env.get("AUTENTIQUE_WEBHOOK_SECRET") ?? "";
const WEBHOOK_SIGNING_SECRET = Deno.env.get("AUTENTIQUE_WEBHOOK_SIGNING_SECRET") ?? "";
const AUTENTIQUE_API    = "https://api.autentique.com.br/v2/graphql";

const json = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { "Content-Type": "application/json" } });

// Comparacao em tempo constante simples (sem depender de import externo) —
// relevante so pra assinatura HMAC; o ?chave= da URL nao precisa disso,
// e' so' um token de acesso, nao um segredo criptografico comparado contra
// dado controlado por quem ataca.
function comparaSeguro(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function assinaturaValida(corpoBruto: string, assinaturaHeader: string): Promise<boolean> {
  const chave = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(WEBHOOK_SIGNING_SECRET),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", chave, new TextEncoder().encode(corpoBruto));
  const calculada = Array.from(new Uint8Array(mac))
    .map(b => b.toString(16).padStart(2, "0")).join("");
  return comparaSeguro(calculada, assinaturaHeader.toLowerCase());
}

// Extrai o ID do documento conforme o tipo do evento — ver comentario no
// topo do arquivo sobre os dois formatos confirmados na doc oficial.
function extrairDocumentoId(corpo: any): string | null {
  const evento = corpo?.event;
  const tipo: string = evento?.type ?? "";
  const dados = evento?.data;

  if (tipo.startsWith("signature.")) {
    return typeof dados?.document === "string" ? dados.document : null;
  }
  // document.* e qualquer tipo nao reconhecido: tenta os dois formatos
  const id = dados?.object?.id ?? dados?.id;
  return typeof id === "string" && id.length > 0 ? id : null;
}

async function autentiqueConsultar(documentoId: string): Promise<{ assinado: boolean; pdfAssinadoUrl: string | null }> {
  const r = await fetch(AUTENTIQUE_API, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${AUTENTIQUE_TOKEN}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      query: `query($id: UUID!) {
        document(id: $id) {
          id
          signatures { signed { created_at } }
          files { signed }
        }
      }`,
      variables: { id: documentoId },
    }),
  });
  const corpo = await r.json();
  if (corpo.errors) {
    throw new Error(corpo.errors[0]?.message ?? "erro desconhecido do Autentique");
  }
  const documento = corpo?.data?.document;
  const assinaturas = documento?.signatures ?? [];
  return {
    assinado: assinaturas.some((s: any) => s?.signed),
    // so existe depois que pelo menos uma assinatura fecha o arquivo —
    // pode vir null mesmo com assinado=true se o Autentique ainda nao
    // gerou o PDF final nesse instante
    pdfAssinadoUrl: typeof documento?.files?.signed === "string" ? documento.files.signed : null,
  };
}

async function marcarAssinado(autentiqueId: string, pdfAssinadoUrl: string | null) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/webhook_contrato_assinado`, {
    method: "POST",
    headers: {
      apikey: SERVICE_ROLE,
      Authorization: `Bearer ${SERVICE_ROLE}`,
      "Content-Type": "application/json",
      "Accept-Profile": "gestao",
      "Content-Profile": "gestao",
    },
    body: JSON.stringify({ p_autentique_id: autentiqueId, p_pdf_assinado_url: pdfAssinadoUrl }),
  });
  const texto = await r.text();
  if (!r.ok) throw new Error(`webhook_contrato_assinado: ${texto}`);
  return texto ? JSON.parse(texto) : null;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ erro: "So aceita POST." }, 405);

  if (!SUPABASE_URL || !SERVICE_ROLE) {
    return json({ erro: "SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY indisponivel nesta function." }, 500);
  }
  if (!AUTENTIQUE_TOKEN) {
    return json({ erro: "AUTENTIQUE_TOKEN nao configurado (supabase secrets set AUTENTIQUE_TOKEN=...)." }, 500);
  }
  if (!WEBHOOK_SECRET && !WEBHOOK_SIGNING_SECRET) {
    return json({ erro: "Configure AUTENTIQUE_WEBHOOK_SECRET (?chave= na URL) e/ou AUTENTIQUE_WEBHOOK_SIGNING_SECRET (assinatura HMAC)." }, 500);
  }

  // corpo bruto primeiro: a verificacao HMAC precisa dos bytes exatos
  // recebidos, reserializar com JSON.stringify depois do parse pode dar
  // uma string byte-a-byte diferente (espacos, ordem de chaves)
  const corpoBruto = await req.text();

  if (WEBHOOK_SIGNING_SECRET) {
    const header = req.headers.get("x-autentique-signature") ?? "";
    if (!header || !(await assinaturaValida(corpoBruto, header))) {
      return json({ erro: "Assinatura HMAC invalida." }, 401);
    }
  } else {
    // sem signing secret configurado, cai pro segredo da URL
    const chave = new URL(req.url).searchParams.get("chave");
    if (chave !== WEBHOOK_SECRET) {
      return json({ erro: "Segredo invalido." }, 401);
    }
  }

  let corpo: any = null;
  try {
    corpo = JSON.parse(corpoBruto);
  } catch {
    return json({ ok: true, ignorado: "corpo nao e JSON valido" });
  }

  const tipoEvento = corpo?.event?.type ?? "(desconhecido)";
  const documentoId = extrairDocumentoId(corpo);
  if (!documentoId) {
    console.log(`autentique-webhook: evento ${tipoEvento} sem ID de documento reconhecivel:`, corpoBruto.slice(0, 2000));
    return json({ ok: true, evento: tipoEvento, ignorado: "ID de documento nao encontrado no payload" });
  }

  try {
    const { assinado, pdfAssinadoUrl } = await autentiqueConsultar(documentoId);
    if (!assinado) {
      return json({ ok: true, evento: tipoEvento, documento: documentoId, assinado: false });
    }
    const resultado = await marcarAssinado(documentoId, pdfAssinadoUrl);
    return json({ ok: true, evento: tipoEvento, documento: documentoId, assinado: true, pdfAssinadoUrl, resultado });
  } catch (e) {
    const msg = String(e);
    // contrato/documento que esta function nao conhece nao e erro
    // operacional (reentregar nao resolveria) — so registra e segue
    if (msg.includes("Nenhum contrato com autentique_id")) {
      console.log("autentique-webhook:", msg);
      return json({ ok: true, evento: tipoEvento, documento: documentoId, ignorado: msg });
    }
    console.error("autentique-webhook: erro ao processar", documentoId, msg);
    return json({ erro: msg }, 500);
  }
});
