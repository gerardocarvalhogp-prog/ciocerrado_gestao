// =====================================================================
// SISTEMA DE GESTAO CIO CERRADO
// Recebe o callback do Autentique quando um documento e assinado, e
// marca o contrato como "assinado" no painel sem precisar mais rodar
// `integracao.py --status` na mao. Pedido do organizador em 01/10/2026
// ("contrato assinado ainda nao refletiu no painel").
//
// AVISO DE CONFIANCA — LEIA ANTES DE CONFIGURAR
//
// Nao ha, nesta sessao, acesso a internet para confirmar ao vivo (a)
// se a conta/plano do Autentique em uso tem a opcao de configurar uma
// URL de webhook no painel deles, e (b) o formato exato do corpo que
// eles enviam nesse POST. O design abaixo foi pensado para ser
// tolerante a essa incerteza, em duas camadas:
//
//   1. O payload do webhook NUNCA e tratado como prova de que o
//      documento foi assinado — so como um aviso de "va conferir".
//      Esta function extrai so o ID do documento do corpo (tentando
//      varios caminhos comuns) e consulta de novo a API GraphQL do
//      Autentique (a MESMA consulta que ler_status, em integracao.py,
//      ja usa e que o organizador ja confirmou que funciona) para
//      saber se esta assinado de verdade. Um payload forjado ou um
//      formato diferente do esperado, na pior hipotese, faz a function
//      ignorar o evento (nao reconhece o ID) ou reconsultar um
//      documento que nao esta assinado (nao muda nada) — nunca marca
//      um contrato como assinado so por confiar no POST recebido.
//   2. Autenticacao do POST em si e por segredo compartilhado na URL
//      (?chave=...), nao por verificacao de assinatura HMAC — porque o
//      mecanismo de assinatura de webhook do Autentique (se existir)
//      nao esta confirmado. Configure o mesmo valor em dois lugares:
//
//        supabase secrets set AUTENTIQUE_WEBHOOK_SECRET=<valor-aleatorio-longo>
//
//      e na URL cadastrada no painel do Autentique:
//
//        https://<project-ref>.functions.supabase.co/autentique-webhook?chave=<mesmo-valor>
//
// Se o Autentique nao tiver opcao de configurar URL de webhook (so
// notificacao por e-mail, por exemplo), esta function fica pronta mas
// inerte — `integracao.py --status` continua sendo o caminho que
// funciona, sem problema nenhum em rodar os dois.
//
// Devolve 200 ate para evento que nao reconhece (ID nao encontrado,
// contrato nao encontrado) — webhook que responde erro demais costuma
// ser desativado pelo provedor depois de algumas falhas, e novas
// tentativas nao resolveriam um ID genuinamente desconhecido. So o
// segredo errado devolve 401; falha de configuracao do servidor (sem
// AUTENTIQUE_TOKEN) devolve 500, porque essa sim vale a pena reentregar
// depois que alguem configurar o secret.
// =====================================================================

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE     = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const AUTENTIQUE_TOKEN = Deno.env.get("AUTENTIQUE_TOKEN") ?? "";
const WEBHOOK_SECRET   = Deno.env.get("AUTENTIQUE_WEBHOOK_SECRET") ?? "";
const AUTENTIQUE_API   = "https://api.autentique.com.br/v2/graphql";

const json = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { "Content-Type": "application/json" } });

// Varre o payload por um ID de documento, tentando os formatos mais
// comuns de webhook primeiro; se nenhum bater, cai para procurar
// qualquer string em formato UUID no JSON inteiro — os autentique_id
// gravados em `contratos` sao UUIDs (a mesma consulta GraphQL usa
// `document(id: UUID!)`).
function extrairDocumentoId(corpo: any): string | null {
  const caminhos = [
    corpo?.document?.id,
    corpo?.data?.document?.id,
    corpo?.document_id,
    corpo?.data?.id,
    corpo?.id,
  ];
  for (const c of caminhos) {
    if (typeof c === "string" && c.length > 0) return c;
  }
  const texto = JSON.stringify(corpo ?? {});
  const m = texto.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
  return m ? m[0] : null;
}

async function autentiqueAssinado(documentoId: string): Promise<boolean> {
  const r = await fetch(AUTENTIQUE_API, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${AUTENTIQUE_TOKEN}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      query: `query($id: UUID!) {
        document(id: $id) { id signatures { signed { created_at } } }
      }`,
      variables: { id: documentoId },
    }),
  });
  const corpo = await r.json();
  if (corpo.errors) {
    throw new Error(corpo.errors[0]?.message ?? "erro desconhecido do Autentique");
  }
  const assinaturas = corpo?.data?.document?.signatures ?? [];
  return assinaturas.some((s: any) => s?.signed);
}

async function marcarAssinado(autentiqueId: string) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/webhook_contrato_assinado`, {
    method: "POST",
    headers: {
      apikey: SERVICE_ROLE,
      Authorization: `Bearer ${SERVICE_ROLE}`,
      "Content-Type": "application/json",
      "Accept-Profile": "gestao",
      "Content-Profile": "gestao",
    },
    body: JSON.stringify({ p_autentique_id: autentiqueId }),
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
  if (!WEBHOOK_SECRET) {
    return json({ erro: "AUTENTIQUE_WEBHOOK_SECRET nao configurado nesta function." }, 500);
  }

  const chave = new URL(req.url).searchParams.get("chave");
  if (chave !== WEBHOOK_SECRET) {
    return json({ erro: "Segredo invalido." }, 401);
  }

  let corpo: any = null;
  try {
    corpo = await req.json();
  } catch {
    return json({ ok: true, ignorado: "corpo nao e JSON valido" });
  }

  const documentoId = extrairDocumentoId(corpo);
  if (!documentoId) {
    console.log("autentique-webhook: nao achou ID de documento no payload:", JSON.stringify(corpo));
    return json({ ok: true, ignorado: "ID de documento nao encontrado no payload" });
  }

  try {
    const assinado = await autentiqueAssinado(documentoId);
    if (!assinado) {
      return json({ ok: true, documento: documentoId, assinado: false });
    }
    const resultado = await marcarAssinado(documentoId);
    return json({ ok: true, documento: documentoId, assinado: true, resultado });
  } catch (e) {
    const msg = String(e);
    // contrato/documento que esta function nao conhece nao e erro
    // operacional (reentregar nao resolveria) — so registra e segue
    if (msg.includes("Nenhum contrato com autentique_id")) {
      console.log("autentique-webhook:", msg);
      return json({ ok: true, documento: documentoId, ignorado: msg });
    }
    console.error("autentique-webhook: erro ao processar", documentoId, msg);
    return json({ erro: msg }, 500);
  }
});
