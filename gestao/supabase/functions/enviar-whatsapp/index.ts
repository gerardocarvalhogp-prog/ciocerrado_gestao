// =====================================================================
// SISTEMA DE GESTAO CIO CERRADO
// Envia o que esta parado na fila de notificacoes com canal=whatsapp,
// via WhatsApp Cloud API (Meta) — irma de enviar-notificacoes, que faz
// o mesmo pro e-mail via Resend.
//
// NAO FUNCIONA AINDA. Falta, fora deste codigo:
//
//   1. Verificacao de negocio no WhatsApp Business Platform (Meta
//      Business Manager) — pode levar dias, e pode ser recusada.
//   2. Numero de telefone dedicado, aprovado dentro dessa conta.
//   3. Pelo menos um TEMPLATE de mensagem aprovado pelo Meta. Toda
//      mensagem fora de uma janela de 24h iniciada pelo destinatario
//      PRECISA ser um template pre-aprovado — nao existe "mandar texto
//      livre" pra cobranca proativa, diferente do e-mail.
//   4. Opt-in explicito de quem recebe (LGPD + politica do WhatsApp).
//
// Enquanto isso nao existir, esta funcao so falha com uma mensagem
// clara — de proposito, igual a enviar-notificacoes recusa sem
// RESEND_API_KEY. Nao inventa sucesso.
//
// CONFIGURACAO NECESSARIA QUANDO A CONTA EXISTIR:
//
//   supabase secrets set WHATSAPP_TOKEN=...          (token de acesso permanente)
//   supabase secrets set WHATSAPP_PHONE_NUMBER_ID=... (id do numero, nao o numero em si)
//
// Cada notificacao de canal=whatsapp precisa ter template_nome
// preenchido (nome exato do template aprovado) e template_params
// (array na ordem que o template espera, ex: ["Fulano", "3 dias"]) —
// quem enfileira monta isso; esta funcao so repassa pro Meta.
//
// COMO CHAMAR (mesmo padrao de enviar-notificacoes)
//
//   POST /functions/v1/enviar-whatsapp
//   Authorization: Bearer <token de um usuario staff/admin>
//   Body opcional: { "id": "<uuid de uma notificacao so>" }
// =====================================================================

const WHATSAPP_TOKEN = Deno.env.get("WHATSAPP_TOKEN") ?? "";
const PHONE_NUMBER_ID = Deno.env.get("WHATSAPP_PHONE_NUMBER_ID") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const json = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

async function rpc(nome: string, params: unknown, autorizacao: string) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${nome}`, {
    method: "POST",
    headers: {
      "apikey": SUPABASE_ANON,
      "Authorization": autorizacao,
      "Content-Type": "application/json",
      "Accept-Profile": "gestao",
      "Content-Profile": "gestao",
    },
    body: JSON.stringify(params),
  });
  const texto = await r.text();
  if (!r.ok) throw new Error(`${nome}: ${texto}`);
  return texto ? JSON.parse(texto) : null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  if (!WHATSAPP_TOKEN || !PHONE_NUMBER_ID) {
    return json({
      erro: "WhatsApp ainda nao configurado neste projeto — falta WHATSAPP_TOKEN e/ou " +
        "WHATSAPP_PHONE_NUMBER_ID. Isso depende da verificacao de negocio no Meta Business " +
        "Manager, que e um processo externo (ver comentario no topo deste arquivo).",
    }, 500);
  }

  const autorizacao = req.headers.get("Authorization") ?? "";
  if (!autorizacao) {
    return json({ erro: "Sem token: faca login como equipe." }, 401);
  }

  try {
    let alvo: string | null = null;
    try {
      const body = await req.json();
      alvo = body?.id ?? null;
    } catch { /* sem body = fila inteira, comportamento padrao */ }

    const fila = await rpc(
      "notificacoes_pendentes",
      { p_limite: 50, p_id: alvo, p_canal: "whatsapp" },
      autorizacao,
    );

    if (!Array.isArray(fila) || fila.length === 0) {
      return json({ ok: true, enviadas: 0, com_erro: 0, mensagem: "Nada na fila de WhatsApp." });
    }

    let enviadas = 0, comErro = 0;

    for (const n of fila) {
      if (!n.template_nome) {
        await rpc("notificacao_marcar",
          { p_id: n.id, p_ok: false, p_erro: "Sem template_nome — mensagem de WhatsApp precisa de template aprovado." },
          autorizacao);
        comErro++;
        continue;
      }

      try {
        // Formato da Cloud API do Meta — ver
        // https://developers.facebook.com/docs/whatsapp/cloud-api/reference/messages
        const envio = await fetch(
          `https://graph.facebook.com/v20.0/${PHONE_NUMBER_ID}/messages`,
          {
            method: "POST",
            headers: {
              "Authorization": `Bearer ${WHATSAPP_TOKEN}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              messaging_product: "whatsapp",
              to: n.destinatario, // E.164, ex: 5562999999999
              type: "template",
              template: {
                name: n.template_nome,
                language: { code: "pt_BR" },
                components: [{
                  type: "body",
                  parameters: (n.template_params ?? []).map((v: string) => ({ type: "text", text: v })),
                }],
              },
            }),
          },
        );

        if (!envio.ok) {
          const detalhe = await envio.text();
          await rpc("notificacao_marcar",
            { p_id: n.id, p_ok: false, p_erro: detalhe.slice(0, 400) }, autorizacao);
          comErro++;
          continue;
        }

        await rpc("notificacao_marcar", { p_id: n.id, p_ok: true }, autorizacao);
        enviadas++;
      } catch (e) {
        await rpc("notificacao_marcar",
          { p_id: n.id, p_ok: false, p_erro: String(e).slice(0, 400) }, autorizacao);
        comErro++;
      }
    }

    return json({ ok: true, enviadas, com_erro: comErro, lidas: fila.length });
  } catch (e) {
    return json({ erro: String(e) }, 500);
  }
});
