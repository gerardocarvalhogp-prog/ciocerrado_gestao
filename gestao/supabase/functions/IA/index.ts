// =====================================================================
// SISTEMA DE GESTAO CIO CERRADO
// supabase/functions/ia/index.ts  ·  proxy para a API do Claude
//
// Por que existe: o painel roda em host estatico (Netlify). Chamar a
// Anthropic direto do navegador exigiria a chave no arquivo publicado,
// onde qualquer um leria. Aqui a chave fica no servidor.
//
// Deploy:
//   supabase functions deploy ia
//   supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
//
// Chamada a partir do painel:
//   sb.functions.invoke("ia", { body: { prompt, buscar_web } })
// =====================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
const SUPABASE_URL  = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

const MODELO = "claude-sonnet-4-6";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(corpo: unknown, status = 200) {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  if (!ANTHROPIC_KEY) {
    return json({ erro: "ANTHROPIC_API_KEY não configurada no projeto." }, 500);
  }

  // ------------------------------------------------------------------
  // Só a equipe pode gastar chamada de IA. Sem esta checagem, qualquer
  // pessoa com a chave anon (que está no HTML publicado) usaria a nossa
  // conta da Anthropic à vontade.
  // ------------------------------------------------------------------
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) {
    return json({ erro: "Sem credencial." }, 401);
  }

  const sb = createClient(SUPABASE_URL, SUPABASE_ANON, {
    global: { headers: { Authorization: auth } },
    db: { schema: "gestao" },
  });

  const { data: ehAdmin, error: erroAuth } = await sb.rpc("is_admin");
  if (erroAuth || !ehAdmin) {
    return json({ erro: "Acesso restrito a administradores." }, 403);
  }

  // ------------------------------------------------------------------
  // Corpo
  // ------------------------------------------------------------------
  let corpo: {
    prompt?: string;
    buscar_web?: boolean;
    max_tokens?: number;
    json?: boolean;
  };

  try {
    corpo = await req.json();
  } catch {
    return json({ erro: "Corpo inválido." }, 400);
  }

  const prompt = (corpo.prompt ?? "").trim();
  if (!prompt) return json({ erro: "Prompt vazio." }, 400);

  // teto de tamanho: evita que um lote grande demais estoure custo
  if (prompt.length > 60_000) {
    return json({ erro: "Prompt muito grande. Divida em lotes menores." }, 400);
  }

  const payload: Record<string, unknown> = {
    model: MODELO,
    max_tokens: Math.min(corpo.max_tokens ?? 2000, 4000),
    messages: [{ role: "user", content: prompt }],
  };

  if (corpo.buscar_web) {
    payload.tools = [{ type: "web_search_20250305", name: "web_search" }];
  }

  // ------------------------------------------------------------------
  // Chamada
  // ------------------------------------------------------------------
  try {
    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": ANTHROPIC_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify(payload),
    });

    const dados = await r.json();

    if (dados.error) {
      return json({ erro: dados.error.message ?? "Erro na API do Claude." }, 502);
    }

    // Com web_search a resposta vem em vários blocos; só os de texto
    // interessam — os de tool_use são o rastro da busca.
    const texto = (dados.content ?? [])
      .filter((b: { type: string }) => b.type === "text")
      .map((b: { text: string }) => b.text)
      .join("\n")
      .trim();

    if (!corpo.json) return json({ texto });

    // Quando pedimos JSON, o modelo às vezes devolve com cerca de
    // markdown ou uma frase antes. Recorta do primeiro colchete ao
    // último em vez de falhar.
    const limpo = texto.replace(/```json|```/g, "").trim();
    const a = limpo.indexOf("[");
    const b = limpo.lastIndexOf("]");
    const o = limpo.indexOf("{");
    const c = limpo.lastIndexOf("}");

    let recorte = limpo;
    if (a >= 0 && b > a) recorte = limpo.slice(a, b + 1);
    else if (o >= 0 && c > o) recorte = limpo.slice(o, c + 1);

    try {
      return json({ dados: JSON.parse(recorte) });
    } catch {
      // devolve o texto cru para a tela mostrar o que veio, em vez de
      // um "erro ao processar" que não ajuda a diagnosticar
      return json({ erro: "A resposta não veio em JSON válido.", texto }, 502);
    }
  } catch (e) {
    return json({ erro: String(e) }, 502);
  }
});
