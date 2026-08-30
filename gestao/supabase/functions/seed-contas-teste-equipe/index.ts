// =====================================================================
// SISTEMA DE GESTAO CIO CERRADO
// TEMPORARIA — cria (ou confirma que ja existem) as 16 contas de login
// de teste da equipe (Tacio, Kelson, Amarildo, Fernanda x 4 perfis),
// com senha ja definida e ja confirmada — sem depender de magic link
// ou e-mail de verificacao, que confirmadamente NAO chega em
// enderecos "+alias@ciocerrado.com.br" (bounce testado em 31/08/2026).
//
// Por que isto precisa existir (e nao e so SQL): criar um usuario que
// consegue logar com senha exige a Admin Auth API do Supabase
// (POST /auth/v1/admin/users com email_confirm:true) — isso precisa de
// service_role, que so existe aqui dentro (variavel de ambiente que o
// Supabase ja injeta sozinho em toda Edge Function; ninguem digita essa
// chave em lugar nenhum). O restante do cadastro (papel dentro da
// gestao) fica na migration 20260831100000, rodada a parte por SQL.
//
// ESTA FUNCTION NAO GRAVA NADA NO SCHEMA GESTAO — so cria os logins.
// A associacao a admin/staff/patrocinador/CIO vem da migration.
//
// Apagar esta function (supabase functions delete seed-contas-teste-equipe)
// depois de usada — nao e infraestrutura permanente.
//
// SO RODA PRA QUEM JA E ADMIN DE VERDADE: o token de quem chama e
// validado contra is_admin() antes de criar qualquer coisa.
//
// Senha por pessoa+persona (nome + papel abreviado), nao uma senha so
// pras 16 — pedido explicito de quem aprovou isto. Fica no codigo, nao
// em parametro de chamada, pra ficar tudo visivel e auditavel aqui.
//
// Chamada:
//   POST /functions/v1/seed-contas-teste-equipe
//   Authorization: Bearer <token de um admin de verdade>
//   Body: {} (vazio — nao precisa de nada, as senhas ja estao aqui embaixo)
// =====================================================================

const SERVICE_ROLE   = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const SUPABASE_URL   = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON  = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

const CONTAS: Record<string, string> = {
  "tacio.henrique+admin@ciocerrado.com.br":        "tacioadm",
  "tacio.henrique+staff@ciocerrado.com.br":        "taciostaff",
  "tacio.henrique+patrocinador@ciocerrado.com.br": "taciopatro",
  "tacio.henrique+cio@ciocerrado.com.br":          "taciocio",

  "kelson.duarte+admin@ciocerrado.com.br":         "kelsonadm",
  "kelson.duarte+staff@ciocerrado.com.br":         "kelsonstaff",
  "kelson.duarte+patrocinador@ciocerrado.com.br":  "kelsonpatro",
  "kelson.duarte+cio@ciocerrado.com.br":           "kelsoncio",

  "amarildo.moraes+admin@ciocerrado.com.br":        "amarildoadm",
  "amarildo.moraes+staff@ciocerrado.com.br":        "amarildostaff",
  "amarildo.moraes+patrocinador@ciocerrado.com.br": "amarildopatro",
  "amarildo.moraes+cio@ciocerrado.com.br":          "amarildocio",

  "comunicacao+admin@ciocerrado.com.br":        "fernandaadm",
  "comunicacao+staff@ciocerrado.com.br":        "fernandastaff",
  "comunicacao+patrocinador@ciocerrado.com.br": "fernandapatro",
  "comunicacao+cio@ciocerrado.com.br":          "fernandacio",
};

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (!SERVICE_ROLE) return json({ erro: "SUPABASE_SERVICE_ROLE_KEY indisponivel nesta function." }, 500);

  const autorizacao = req.headers.get("Authorization") ?? "";
  if (!autorizacao) return json({ erro: "Sem token: faca login como admin." }, 401);

  // confirma que quem chama e admin de verdade, repassando o token dele
  // pra RPC is_admin() — a mesma checagem que protege o resto do schema
  const chk = await fetch(`${SUPABASE_URL}/rest/v1/rpc/is_admin`, {
    method: "POST",
    headers: {
      apikey: SUPABASE_ANON, Authorization: autorizacao, "Content-Type": "application/json",
      "Accept-Profile": "gestao", "Content-Profile": "gestao",
    },
    body: "{}",
  });
  if (!chk.ok || (await chk.json()) !== true) {
    return json({ erro: "Só administrador pode rodar isto." }, 403);
  }

  const resultado: Record<string, string> = {};
  for (const [email, senha] of Object.entries(CONTAS)) {
    const r = await fetch(`${SUPABASE_URL}/auth/v1/admin/users`, {
      method: "POST",
      headers: {
        apikey: SERVICE_ROLE, Authorization: `Bearer ${SERVICE_ROLE}`, "Content-Type": "application/json",
      },
      body: JSON.stringify({ email, password: senha, email_confirm: true }),
    });
    if (r.ok) { resultado[email] = "criado"; continue; }

    const corpo = await r.text();
    // idempotente: rodar de novo nao e erro, e o estado final que importa
    if (r.status === 422 && corpo.toLowerCase().includes("already been registered")) {
      resultado[email] = "já existia";
      continue;
    }
    resultado[email] = `ERRO: ${corpo.slice(0, 300)}`;
  }

  const falhou = Object.values(resultado).some(v => v.startsWith("ERRO"));
  return json({ ok: !falhou, resultado }, falhou ? 500 : 200);
});
