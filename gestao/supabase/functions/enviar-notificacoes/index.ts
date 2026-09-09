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
//
// So isso: o remetente (contato@ciocerrado.com.br) ja e o padrao no
// codigo. A conta do Resend e a do gerardocarvalhogp@gmail.com.
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
//
// MODO DE TESTE (regra do projeto: nenhum disparo real fora de
// producao). Por padrao AMBIENTE nao e 'producao' — a funcao MONTA os
// e-mails, devolve no JSON de resposta (para conferencia), e marca
// cada notificacao como enviada SEM chamar o Resend. So sai e-mail de
// verdade com:
//
//   supabase secrets set AMBIENTE=producao
//
// igual ao --producao do integracao.py: producao e sempre flag
// explicita, nunca o padrao.
// =====================================================================

const RESEND_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const PRODUCAO = (Deno.env.get("AMBIENTE") ?? "").trim().toLowerCase() === "producao";

// Remetente oficial. Fica como padrao no codigo para nao depender de
// mais um secret — REMETENTE so precisa existir se um dia mudar.
//
// ATENCAO: ciocerrado.com.br precisa estar VERIFICADO no Resend (os
// registros SPF/DKIM no DNS). Sem isso o Resend aceita a chamada,
// devolve 200, e o e-mail nao chega em ninguem — falha silenciosa, a
// pior de todas. O dominio fica na Skymail, entao os registros entram
// no painel de DNS de la, nao no Google.
const REMETENTE  = Deno.env.get("REMETENTE") ?? "CIO Cerrado <contato@ciocerrado.com.br>";
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

  if (PRODUCAO && !RESEND_KEY) {
    return json({ erro: "RESEND_API_KEY nao configurada no projeto." }, 500);
  }

  const autorizacao = req.headers.get("Authorization") ?? "";
  if (!autorizacao) {
    return json({ erro: "Sem token: faca login como equipe." }, 401);
  }

  try {
    // body.id opcional: envia SO aquela notificacao. Serve para testar
    // a configuracao sem despejar a fila acumulada em cima de gente
    // real, e para reenviar uma que falhou.
    let alvo: string | null = null;
    try {
      const body = await req.json();
      alvo = body?.id ?? null;
    } catch { /* sem body = fila inteira, comportamento padrao */ }

    const fila = await rpc(
      "notificacoes_pendentes",
      { p_limite: 50, p_id: alvo },
      autorizacao,
    );

    if (!Array.isArray(fila) || fila.length === 0) {
      return json({ ok: true, enviadas: 0, com_erro: 0, mensagem: "Nada na fila." });
    }

    // Fora de producao: monta e devolve os e-mails no JSON, sem chamar
    // o Resend e sem marcar nada como enviado — a fila fica intacta
    // para quando AMBIENTE=producao estiver de fato configurado.
    if (!PRODUCAO) {
      const previa = fila.map((n: any) => ({
        id: n.id,
        destinatario: n.destinatario,
        assunto: n.assunto ?? "CIO Cerrado",
        corpo: (n.corpo && String(n.corpo).trim())
          ? String(n.corpo)
          : `${n.assunto}\n\nEquipe CIO Cerrado`,
      }));
      return json({
        ok: true, modo: "teste", enviadas: 0, com_erro: 0,
        mensagem: `Modo de teste: ${previa.length} e-mail(s) montado(s), nenhum enviado. ` +
          "Configure AMBIENTE=producao para disparar de verdade.",
        previa,
      });
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
