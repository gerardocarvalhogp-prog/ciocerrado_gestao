// =====================================================================
// SISTEMA DE GESTAO CIO CERRADO
// Envia o que esta parado na fila de notificacoes, via Resend.
//
// POR QUE ISTO EXISTE
//
// A tabela `notificacoes` sempre enfileirou (aprovacao de inscricao,
// rooming confirmado, convite do evento) com status 'enfileirada' — e
// nada nunca enviou. A fila enchia e ficava. Esta e a peca que faltava.
//
// CONFIGURACAO NECESSARIA (sem isso a funcao recusa rodar, de proposito
// — melhor falhar visivel do que fingir que enviou):
//
//   supabase secrets set RESEND_API_KEY=re_...
//   supabase secrets set REMETENTE="CIO Cerrado <eventos@ciocerrado.com.br>"
//
// O dominio precisa estar verificado no Resend, senao o Resend aceita a
// chamada e o e-mail nao chega.
//
// COMO CHAMAR
//
//   POST /functions/v1/enviar-notificacoes
//   Authorization: Bearer <token de um usuario staff/admin>
//
// A funcao NAO usa service_role: ela repassa o token de quem chamou, e
// as RPCs (notificacoes_pendentes / notificacao_marcar) checam papel na
// primeira linha, como todo o resto do schema. Assim nao existe caminho
// para disparar e-mail sem estar logado como equipe.
// =====================================================================

const RESEND_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const REMETENTE  = Deno.env.get("REMETENTE") ?? "CIO Cerrado <onboarding@resend.dev>";
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

// Chama uma RPC do schema gestao com o token de quem pediu o envio.
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

  if (!RESEND_KEY) {
    return json({ erro: "RESEND_API_KEY nao configurada no projeto." }, 500);
  }

  const autorizacao = req.headers.get("Authorization") ?? "";
  if (!autorizacao) {
    return json({ erro: "Sem token: faca login como equipe." }, 401);
  }

  try {
    const limite = 50;
    const fila = await rpc("notificacoes_pendentes", { p_limite: limite }, autorizacao);

    if (!Array.isArray(fila) || fila.length === 0) {
      return json({ ok: true, enviadas: 0, com_erro: 0, mensagem: "Nada na fila." });
    }

    let enviadas = 0, comErro = 0;

    for (const n of fila) {
      // corpo pode estar vazio nas notificacoes antigas, enfileiradas
      // antes de existir a coluna — cai num texto minimo em vez de
      // mandar e-mail em branco
      const corpo = (n.corpo && String(n.corpo).trim())
        ? String(n.corpo)
        : `${n.assunto}\n\nEquipe CIO Cerrado`;

      try {
        const envio = await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: {
            "Authorization": `Bearer ${RESEND_KEY}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            from: REMETENTE,
            to: [n.destinatario],
            subject: n.assunto ?? "CIO Cerrado",
            text: corpo,
          }),
        });

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
        // falha de rede numa mensagem nao pode derrubar o lote inteiro
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
