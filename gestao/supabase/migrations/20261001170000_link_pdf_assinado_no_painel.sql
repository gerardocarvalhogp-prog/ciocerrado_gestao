-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- O painel mostrava "Assinado" mas nao tinha link nenhum pro PDF —
-- achado pelo organizador testando o webhook em 01/10/2026
-- ("não achei o pdf assinado"). `contratos.autentique_url` sempre
-- existiu (gravado no envio, enviar_contratos em integracao.py), mas:
--
--   1. apontava pra PAGINA do documento no painel do Autentique
--      (https://app.autentique.com.br/documentos/<id>), que exige
--      login na conta deles — nao o PDF em si;
--   2. v_painel_participantes/admin_rel_painel nunca expunham essa
--      coluna, entao nem o link de login aparecia em lugar nenhum do
--      admin.html.
--
-- Dois consertos juntos:
--
--   A. v_painel_participantes e admin_rel_painel passam a devolver
--      autentique_url — admin.html (proximo commit) vira o badge de
--      status num link quando ela existir.
--   B. webhook_contrato_assinado ganha um parametro opcional
--      p_pdf_assinado_url: quando a Edge Function manda o link do
--      ARQUIVO assinado (campo files.signed da API do Autentique,
--      disponivel so depois que fecha a assinatura), esse link
--      SUBSTITUI o autentique_url generico — a partir dai o painel
--      aponta direto pro PDF, sem precisar logar em lugar nenhum.
--      integracao.py (ler_status, caminho manual) ganha o mesmo
--      comportamento no mesmo commit, pra nao desalinhar os dois
--      caminhos que levam a "assinado".
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- A1. VIEW: autentique_url
--
-- coluna nova VAI NO FIM da lista — "create or replace view" so aceita
-- adicionar coluna no fim; inserir no meio (onde ela faria mais sentido
-- de leitura) quebra com "cannot change name of view column" porque
-- desloca o nome de tudo que vem depois.
--
-- security_invoker = true reafirmado logo depois: foi ligado em
-- 20260824120000 pra fechar um vazamento de verdade (anon lia nome,
-- empresa e status de todo mundo sem login nenhum, so com a chave
-- publicada nos .html). CREATE OR REPLACE VIEW nao deveria resetar
-- reloptions, mas reafirmar custa nada e tira qualquer duvida — essa
-- propriedade e seguranca, nao esteiica, nao da pra confiar "deveria".
-- ---------------------------------------------------------------------
create or replace view v_painel_participantes as
select pa.evento_id,
       pa.id as participante_id,
       g.nome,
       g.empresa,
       g.email,
       pa.status as status_inscricao,
       coalesce(ct.status, 'nao_enviado') as status_contrato,
       case
         when r.id is null then 'nao_iniciado'
         when r.status = 'completo' then 'completo'
         else 'parcial'
       end as status_rooming,
       r.usa_transfer,
       q.numero as quarto,
       ct.autentique_url
from participantes pa
join gestores g on g.id = pa.gestor_id
left join contratos ct on ct.participante_id = pa.id
left join reservas r on r.participante_id = pa.id and r.status <> 'cancelado'
left join quartos q on q.id = r.quarto_id;

alter view v_painel_participantes set (security_invoker = true);

-- ---------------------------------------------------------------------
-- A2. admin_rel_painel: devolve autentique_url
--
-- _exige_staff_do_evento_slug (nao o _exige_staff generico) — a versao
-- que esta rodando de verdade e a de 20260831160000 (staff escopado por
-- evento), que esta funcao estava usando. Repetir aqui so pelo nome
-- antigo teria regredido esse escopo sem querer.
-- ---------------------------------------------------------------------
drop function if exists admin_rel_painel(text, integer, integer);

create or replace function admin_rel_painel(
  p_evento_slug text, p_limite integer default 500, p_offset integer default 0
) returns table (
  participante_id uuid, nome text, empresa text, email text,
  status_inscricao text, status_contrato text, autentique_url text,
  status_rooming text, usa_transfer boolean, quarto text, total_geral bigint
) language plpgsql stable security definer
set search_path to 'gestao', 'public' as $$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select v.participante_id, v.nome, v.empresa, v.email,
           v.status_inscricao, v.status_contrato, v.autentique_url,
           v.status_rooming, v.usa_transfer, v.quarto,
           count(*) over ()
    from v_painel_participantes v
    join eventos e on e.id = v.evento_id and e.slug = p_evento_slug
    order by v.empresa, v.nome
    limit p_limite offset p_offset;
end;
$$;

revoke execute on function admin_rel_painel(text, integer, integer) from public, anon;
grant execute on function admin_rel_painel(text, integer, integer) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- B. webhook_contrato_assinado: aceita o link do PDF ja assinado
-- ---------------------------------------------------------------------
create or replace function webhook_contrato_assinado(
  p_autentique_id text, p_pdf_assinado_url text default null
) returns jsonb language plpgsql security definer
set search_path to 'gestao', 'public' as $$
declare
  v_contrato_id uuid;
  v_status_atual text;
  v_participante_id uuid;
  v_evento_id uuid;
  v_email text;
begin
  perform _exige_staff();

  if coalesce(trim(p_autentique_id),'') = '' then
    raise exception 'autentique_id vazio' using errcode='22023';
  end if;

  select ct.id, ct.status, ct.participante_id, pa.evento_id
    into v_contrato_id, v_status_atual, v_participante_id, v_evento_id
  from contratos ct
  join participantes pa on pa.id = ct.participante_id
  where ct.autentique_id = p_autentique_id
  limit 1;

  if v_contrato_id is null then
    raise exception 'Nenhum contrato com autentique_id %', p_autentique_id
      using errcode='P0002';
  end if;

  -- ja estava assinado (reentrega do webhook, ou --status rodou antes):
  -- so completa o link do PDF se ainda nao tiver (nunca sobrescreve um
  -- link ja gravado), nao reaplica nem manda aviso de novo
  if v_status_atual = 'assinado' then
    if coalesce(trim(p_pdf_assinado_url),'') <> '' then
      update contratos set autentique_url = coalesce(autentique_url, p_pdf_assinado_url)
       where id = v_contrato_id and autentique_url is null;
    end if;
    return jsonb_build_object('ok', true, 'ja_estava_assinado', true,
                               'contrato_id', v_contrato_id);
  end if;

  update contratos set
    status = 'assinado',
    assinado_em = now(),
    autentique_url = coalesce(nullif(trim(p_pdf_assinado_url),''), autentique_url)
  where id = v_contrato_id;

  select g.email into v_email
  from participantes pa join gestores g on g.id = pa.gestor_id
  where pa.id = v_participante_id;

  if coalesce(trim(v_email),'') <> '' then
    insert into notificacoes (evento_id, destinatario, tipo, assunto, status)
    values (v_evento_id, v_email, 'contrato_assinado',
            'Contrato assinado — complete sua hospedagem', 'enfileirada');
  end if;

  return jsonb_build_object('ok', true, 'ja_estava_assinado', false,
                             'contrato_id', v_contrato_id);
end;
$$;

revoke execute on function webhook_contrato_assinado(text, text) from public, anon, authenticated;
grant execute on function webhook_contrato_assinado(text, text) to service_role;

-- a sobrecarga antiga (so autentique_id) fica orfa — ninguem mais chama
-- com 1 parametro depois que a Edge Function for atualizada no mesmo
-- commit, mas apagar aqui evitaria qualquer chamada antiga pendurada
-- de dar erro de "function nao existe" em vez de so nao fazer nada
drop function if exists webhook_contrato_assinado(text);

-- ---------------------------------------------------------------------
-- autoconfere
-- ---------------------------------------------------------------------
do $$
declare
  v_tem_coluna boolean;
  v_invoker boolean;
  v_pode_authenticated boolean;
  v_pode_service boolean;
begin
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'gestao' and table_name = 'v_painel_participantes'
      and column_name = 'autentique_url'
  ) into v_tem_coluna;
  if not v_tem_coluna then
    raise exception 'v_painel_participantes deveria ter autentique_url';
  end if;

  -- security_invoker tem que continuar ligado (fecha vazamento de
  -- 20260824120000) — confere de verdade em vez de so confiar que o
  -- "alter view" acima rodou sem erro
  select coalesce((
    select (option_value = 'true')
    from pg_options_to_table(
      (select reloptions from pg_class
        where relname = 'v_painel_participantes'
          and relnamespace = 'gestao'::regnamespace))
    where option_name = 'security_invoker'
  ), false) into v_invoker;
  if not v_invoker then
    raise exception 'v_painel_participantes perdeu security_invoker=true — vazamento de dado pra anon';
  end if;

  select has_function_privilege('authenticated', 'gestao.webhook_contrato_assinado(text,text)', 'execute')
    into v_pode_authenticated;
  select has_function_privilege('service_role', 'gestao.webhook_contrato_assinado(text,text)', 'execute')
    into v_pode_service;
  if v_pode_authenticated then
    raise exception 'webhook_contrato_assinado nao deveria ser executavel por authenticated';
  end if;
  if not v_pode_service then
    raise exception 'webhook_contrato_assinado deveria ser executavel por service_role';
  end if;

  raise notice 'v_painel_participantes.autentique_url e webhook_contrato_assinado(2 args) conferidos.';
end $$;
