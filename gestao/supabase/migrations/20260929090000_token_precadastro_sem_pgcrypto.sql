-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- admin_criar_convite_pre_cadastro: token deixa de depender de pgcrypto.
--
-- Achado em producao: "function gen_random_bytes(integer) does not
-- exist" ao clicar "Gerar novo link" (aba Aprovacoes). gen_random_bytes
-- vem da extensao pgcrypto (ver migrations/20260824110000_extensoes.sql)
-- — instalada em algum schema que nao esta no search_path que as
-- funcoes deste sistema usam (`set search_path = gestao, public`), ou
-- simplesmente nao aplicada no hospedado por algum motivo que nao da
-- pra confirmar sem acesso direto ao banco (fora do alcance deste
-- sandbox). gen_random_uuid(), ao contrario, e' nativo do Postgres
-- desde a versao 13 — nao depende de extensao nenhuma, e ja e usado
-- como default de quase toda chave primaria do schema sem problema.
--
-- Um UUID v4 tem 122 bits de aleatoriedade — de sobra pro que o token
-- precisa ser (link de convite de uso unico e nao adivinhavel, nao uma
-- chave criptografica de longo prazo). Um UUID sem os tracos ja da os
-- mesmos 32 caracteres hexadecimais do encode(gen_random_bytes(16),
-- 'hex') anterior — nao precisa de dois.
--
-- Mesma assinatura — CREATE OR REPLACE basta.
-- =====================================================================

set search_path = gestao, public;

create or replace function admin_criar_convite_pre_cadastro(p_evento_slug text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_evento uuid; v_id uuid; v_token text;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode = 'P0002';
  end if;

  v_token := replace(gen_random_uuid()::text, '-', '');

  insert into pre_cadastros (evento_id, token, criado_por)
  values (v_evento, v_token, auth.jwt() ->> 'email')
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id, 'token', v_token);
end;
$$;

revoke execute on function admin_criar_convite_pre_cadastro(text) from public, anon;
grant execute on function admin_criar_convite_pre_cadastro(text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Self-check: gera um convite de verdade e confere que o token saiu
-- (32 caracteres hexadecimais, sem depender de pgcrypto).
-- ---------------------------------------------------------------------
do $$
declare v_slug text; v_resultado jsonb; v_token text; v_id uuid;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);

  select slug into v_slug from eventos limit 1;
  if v_slug is null then
    raise notice 'Nenhum evento no banco — self-check pulado (nada pra testar contra).';
    return;
  end if;

  v_resultado := admin_criar_convite_pre_cadastro(v_slug);
  v_token := v_resultado ->> 'token';
  v_id := (v_resultado ->> 'id')::uuid;

  if v_token !~ '^[0-9a-f]{32}$' then
    raise exception 'token gerado fora do formato esperado: %', v_token;
  end if;

  delete from pre_cadastros where id = v_id;
end $$;
