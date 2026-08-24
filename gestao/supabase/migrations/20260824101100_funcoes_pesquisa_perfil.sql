-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- funcoes-pesquisa.sql  ·  pesquisa de perfil
--
-- Rodar DEPOIS de funcoes-checkin.sql.
--
-- A pesquisa vem do export "Lista de participantes" do Sympla: 73
-- colunas, sendo ~50 delas areas de investimento. O painel importa,
-- lista e agrega.
-- =====================================================================

set search_path = gestao, public;

-- =====================================================================
-- 1. IMPORTACAO
-- =====================================================================

-- Recebe as linhas ja separadas no navegador:
--   { email, faturamento, orcamento_ti, colaboradores, colaboradores_ti,
--     erp_atual, dispositivos, terceirizados, consentimento_lgpd,
--     investimentos: {"SOFTWARE - ERP": "Irá aumentar...", ...},
--     perfil:        {"COMO A SUA EMPRESA AVALIA...": "...", ...} }
--
-- O casamento e pelo e-mail do gestor dentro do evento. Quem nao esta
-- inscrito volta na lista de nao encontrados, em vez de sumir.
create or replace function admin_importar_pesquisa(
  p_evento_slug text,
  p_linhas jsonb
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid;
  v_item jsonb;
  v_part uuid;
  v_email text;
  v_ok int := 0; v_nao int := 0; v_sem_email int := 0;
  v_nao_achados jsonb := '[]'::jsonb;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p_linhas,'[]'::jsonb))
  loop
    v_email := nullif(trim(v_item ->> 'email'), '');

    if v_email is null then
      v_sem_email := v_sem_email + 1;
      continue;
    end if;

    select pa.id into v_part
    from participantes pa
    join gestores g on g.id = pa.gestor_id
    where pa.evento_id = v_evento
      and g.email_norm = norm_doc(v_email)
    limit 1;

    if v_part is null then
      v_nao := v_nao + 1;
      -- guarda so os 50 primeiros: a tela mostra a lista, nao um dump
      if jsonb_array_length(v_nao_achados) < 50 then
        v_nao_achados := v_nao_achados || jsonb_build_object(
          'email', v_email, 'nome', v_item ->> 'nome');
      end if;
      continue;
    end if;

    insert into participante_perfil (
      participante_id, faturamento, orcamento_ti, colaboradores,
      colaboradores_ti, erp_atual, respostas, consentimento_lgpd)
    values (
      v_part,
      nullif(v_item ->> 'faturamento',''),
      nullif(v_item ->> 'orcamento_ti',''),
      nullif(v_item ->> 'colaboradores',''),
      nullif(v_item ->> 'colaboradores_ti',''),
      nullif(v_item ->> 'erp_atual',''),
      jsonb_build_object(
        'investimentos', coalesce(v_item -> 'investimentos', '{}'::jsonb),
        'perfil',        coalesce(v_item -> 'perfil', '{}'::jsonb),
        'dispositivos',  v_item ->> 'dispositivos',
        'terceirizados', v_item ->> 'terceirizados'),
      -- qualquer variacao de "aceito" conta como consentimento
      (lower(coalesce(v_item ->> 'consentimento_lgpd','')) like '%aceit%')
    )
    on conflict (participante_id) do update set
      faturamento      = coalesce(excluded.faturamento, participante_perfil.faturamento),
      orcamento_ti     = coalesce(excluded.orcamento_ti, participante_perfil.orcamento_ti),
      colaboradores    = coalesce(excluded.colaboradores, participante_perfil.colaboradores),
      colaboradores_ti = coalesce(excluded.colaboradores_ti, participante_perfil.colaboradores_ti),
      erp_atual        = coalesce(excluded.erp_atual, participante_perfil.erp_atual),
      respostas        = excluded.respostas,
      consentimento_lgpd = excluded.consentimento_lgpd,
      updated_at       = now();

    v_ok := v_ok + 1;
  end loop;

  insert into importacoes (evento_id, tipo, total_linhas, atualizados,
                           erros, executado_por)
  values (v_evento, 'pesquisa',
          jsonb_array_length(coalesce(p_linhas,'[]'::jsonb)),
          v_ok, v_nao + v_sem_email, auth.jwt() ->> 'email');

  return jsonb_build_object(
    'ok', true, 'importados', v_ok,
    'nao_encontrados', v_nao, 'sem_email', v_sem_email,
    'lista_nao_encontrados', v_nao_achados);
end;
$$;

-- =====================================================================
-- 2. NORMALIZACAO DAS RESPOSTAS DE INVESTIMENTO
--
-- O formulario devolve a mesma intencao escrita de varios jeitos:
-- "Sem previsão" e "Sem Previsão", "Em estudo para os próximos 12
-- meses" e "Em Estudos nos Próximos 12 Meses". Agrupar pelo texto cru
-- criaria categorias duplicadas em todo relatorio.
-- =====================================================================

create or replace function _intencao(v text)
returns text language sql immutable as $$
  select case
    when v is null or trim(v) = '' then null
    when lower(unaccent('unaccent', v)) like '%aumentar%'  then 'aumentar'
    when lower(unaccent('unaccent', v)) like '%diminuir%'  then 'diminuir'
    when lower(unaccent('unaccent', v)) like '%estudo%'    then 'estudo'
    when lower(unaccent('unaccent', v)) like '%sem previsao%' then 'sem_previsao'
    else 'outro'
  end;
$$;

-- =====================================================================
-- 3. AGREGACAO POR AREA DE INVESTIMENTO
--
-- E o numero que interessa ao comercial: quantos CIOs vao aumentar
-- investimento em cada area nos proximos 12 meses.
-- =====================================================================

create or replace function admin_pesquisa_areas(p_evento_slug text)
returns table (
  area text, aumentar bigint, estudo bigint,
  diminuir bigint, sem_previsao bigint, respondentes bigint
) language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select
      inv.key,
      count(*) filter (where _intencao(inv.value #>> '{}') = 'aumentar'),
      count(*) filter (where _intencao(inv.value #>> '{}') = 'estudo'),
      count(*) filter (where _intencao(inv.value #>> '{}') = 'diminuir'),
      count(*) filter (where _intencao(inv.value #>> '{}') = 'sem_previsao'),
      count(*) filter (where _intencao(inv.value #>> '{}') is not null)
    from participante_perfil pp
    join participantes pa on pa.id = pp.participante_id
    join eventos e on e.id = pa.evento_id and e.slug = p_evento_slug
    cross join lateral jsonb_each(coalesce(pp.respostas -> 'investimentos','{}'::jsonb)) as inv
    where pa.status = 'aprovado'
    group by inv.key
    order by 2 desc, 1;
end;
$$;

-- Quem marcou "aumentar" numa area — a lista que o patrocinador quer.
create or replace function admin_pesquisa_por_area(
  p_evento_slug text,
  p_area text,
  p_intencao text default 'aumentar'
) returns table (nome text, empresa text, cargo text, email text,
                 segmento text, faturamento text, resposta text)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select g.nome, g.empresa, g.cargo, g.email, g.segmento,
           pp.faturamento,
           (pp.respostas -> 'investimentos' ->> p_area)
    from participante_perfil pp
    join participantes pa on pa.id = pp.participante_id
    join gestores g on g.id = pa.gestor_id
    join eventos e on e.id = pa.evento_id and e.slug = p_evento_slug
    where pa.status = 'aprovado'
      and _intencao(pp.respostas -> 'investimentos' ->> p_area) = p_intencao
    order by g.empresa, g.nome;
end;
$$;

-- =====================================================================
-- 4. RELATORIO COMPLETO
-- Substitui a versao anterior, que devolvia so 5 colunas e escondia
-- as ~50 areas de investimento dentro do jsonb.
--
-- DROP antes do CREATE OR REPLACE: o Postgres nao troca o formato de
-- saida de uma funcao ja existente so com REPLACE quando o numero ou
-- tipo das colunas muda (erro 42P13).
-- =====================================================================

drop function if exists admin_rel_pesquisa(text, integer, integer);

create or replace function admin_rel_pesquisa(
  p_evento_slug text,
  p_limite int default 500,
  p_offset int default 0
) returns table (
  nome text, empresa text, cargo text, email text, telefone text,
  segmento text, estado text, cnpj text,
  faturamento text, orcamento_ti text, colaboradores text,
  colaboradores_ti text, erp_atual text,
  dispositivos text, terceirizados text,
  consentimento_lgpd boolean,
  investimentos jsonb, perfil jsonb,
  respondeu boolean, total_geral bigint
) language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select g.nome, g.empresa, g.cargo, g.email, g.telefone,
           g.segmento, g.estado, g.cnpj,
           pp.faturamento, pp.orcamento_ti, pp.colaboradores,
           pp.colaboradores_ti, pp.erp_atual,
           pp.respostas ->> 'dispositivos',
           pp.respostas ->> 'terceirizados',
           pp.consentimento_lgpd,
           coalesce(pp.respostas -> 'investimentos', '{}'::jsonb),
           coalesce(pp.respostas -> 'perfil', '{}'::jsonb),
           (pp.participante_id is not null),
           count(*) over ()
    from participantes pa
    join gestores g on g.id = pa.gestor_id
    join eventos  e on e.id = pa.evento_id and e.slug = p_evento_slug
    left join participante_perfil pp on pp.participante_id = pa.id
    where pa.status = 'aprovado'
    order by (pp.participante_id is null), g.empresa, g.nome
    limit p_limite offset p_offset;
end;
$$;

-- Quantos ja responderam. A tela abre com isso: o numero que diz se
-- vale confiar na analise ou se falta gente.
create or replace function admin_pesquisa_resumo(p_evento_slug text)
returns jsonb language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_total int; v_resp int; v_lgpd int;
begin
  perform _exige_staff();

  select count(*) into v_total
  from participantes pa
  join eventos e on e.id = pa.evento_id and e.slug = p_evento_slug
  where pa.status = 'aprovado';

  select count(*), count(*) filter (where pp.consentimento_lgpd)
    into v_resp, v_lgpd
  from participante_perfil pp
  join participantes pa on pa.id = pp.participante_id
  join eventos e on e.id = pa.evento_id and e.slug = p_evento_slug
  where pa.status = 'aprovado';

  return jsonb_build_object(
    'aprovados', v_total,
    'responderam', v_resp,
    'faltam', greatest(v_total - v_resp, 0),
    'consentiram_lgpd', v_lgpd);
end;
$$;

grant execute on function
  admin_importar_pesquisa(text, jsonb),
  admin_pesquisa_areas(text),
  admin_pesquisa_por_area(text, text, text),
  admin_pesquisa_resumo(text),
  admin_rel_pesquisa(text, int, int),
  _intencao(text)
to authenticated;
