-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Corrige na raiz o achado documentado na migration anterior: is_admin()
-- e is_staff() so' reconhecem e-mail cadastrado em `admins`
-- (auth.jwt()->>'email') — e o token service_role, que integracao.py
-- ja usa pra tudo, e' um JWT sem claim de e-mail nenhuma. Toda funcao
-- que chama _exige_admin()/_exige_staff() (a maioria do schema) recusa
-- uma chamada autenticada so' como service_role, mesmo sendo a chave
-- mais privilegiada que existe.
--
-- NAO E' UMA BRECHA NOVA: service_role JA bypassa RLS por completo em
-- qualquer chamada direta a tabela (.get/.insert/.patch, e' assim que
-- integracao.py sempre operou). O que faltava era o MESMO nivel de
-- confianca valer tambem pra chamada de RPC guardada por
-- _exige_admin()/_exige_staff() — hoje, ironicamente, a chave mais
-- privilegiada e' a UNICA que nao consegue chamar essas funcoes.
--
-- current_user NAO SERVE AQUI — tentei primeiro, quebrou na validacao
-- local: dentro de uma funcao SECURITY DEFINER, current_user vira o
-- DONO da funcao (postgres), nao o papel de quem chamou. Como
-- _exige_admin()/_exige_staff() (SECURITY DEFINER) chamam is_admin()/
-- is_staff() (tambem SECURITY DEFINER), current_user ja' teria trocado
-- DUAS vezes antes de chegar no teste — sempre 'postgres', nunca
-- 'service_role', nao importa a chave usada de verdade.
--
-- auth.jwt()->>'role' funciona: le a claim `role` do JWT decodificado
-- pelo PostgREST, guardada num GUC de sessao (request.jwt.claims) —
-- nao depende de current_user, entao sobrevive a quantas camadas de
-- SECURITY DEFINER houver no meio. O JWT do service_role carrega
-- {"role":"service_role"} mesmo sem e-mail nenhum, e foi assim que a
-- ausencia de e-mail causou o bug original.
--
-- EFEITO PRATICO: jantar_importar_convidados_sympla (que
-- integracao.py --jantares ja chama hoje) passa a funcionar de
-- verdade com a service_role — hoje ela pode estar falhando
-- silenciosamente em producao, sem que ninguem tivesse motivo de
-- notar (o log do Agendador de Tarefas e' o unico lugar onde isso
-- apareceria).
--
-- CREATE OR REPLACE basta aqui: is_admin()/is_staff() nao mudam
-- assinatura, so o corpo.
-- =====================================================================

set search_path = gestao, public;

create or replace function is_admin() returns boolean
language sql stable security definer
set search_path = gestao, public as $$
  select auth.jwt() ->> 'role' = 'service_role' or exists (
    select 1 from admins
    where email_norm = norm_doc(auth.jwt() ->> 'email')
      and role = 'admin' and ativo
  );
$$;

create or replace function is_staff() returns boolean
language sql stable security definer
set search_path = gestao, public as $$
  select auth.jwt() ->> 'role' = 'service_role' or exists (
    select 1 from admins
    where email_norm = norm_doc(auth.jwt() ->> 'email')
      and ativo
  );
$$;

-- As duas funcoes da migration anterior usavam um guard proprio
-- (is_admin() OR current_user = 'service_role') porque is_admin()
-- ainda nao cobria isso sozinha. Agora cobre — simplifica pro mesmo
-- padrao _exige_admin() de todo o resto do schema, sem perder
-- comportamento nenhum.
create or replace function jantar_listar_para_sympla()
returns table (
  id uuid, patrocinador_nome text, data date, horario time without time zone,
  local text, capacidade integer, mensagem text, logo_storage_path text,
  sympla_status text, sympla_url text
) language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_admin();

  return query
    select j.id, j.patrocinador_nome, j.data, j.horario, j.local,
           j.capacidade, j.mensagem, j.logo_storage_path, j.sympla_status, j.sympla_url
    from jantares j
    where j.status in ('planejado','confirmado')
      and (
        (j.sympla_status = 'pendente' and j.logo_storage_path is not null
           and j.mensagem is not null and j.data is not null)
        or j.sympla_status = 'criado'
      )
    order by j.data nulls last;
end;
$$;

create or replace function jantar_marcar_sympla(p_id uuid, p_sympla_url text, p_status text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
begin
  perform _exige_admin();

  if p_status not in ('criado','convites_enviados') then
    raise exception 'Status invalido: %', p_status using errcode='22023';
  end if;

  update jantares set
    sympla_url = coalesce(nullif(trim(p_sympla_url),''), sympla_url),
    sympla_status = p_status,
    sympla_criado_em = case when p_status = 'criado' then now() else sympla_criado_em end
  where id = p_id;

  if not found then
    raise exception 'Jantar nao encontrado' using errcode='P0002';
  end if;

  return jsonb_build_object('ok', true);
end;
$$;
