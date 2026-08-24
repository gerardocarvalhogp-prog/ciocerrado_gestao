-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- migracao-04.sql  ·  prospeccao igual ao agente de jantares
--
-- Rodar DEPOIS de correcoes-01.sql.
--
-- A primeira versao da aba Prospeccao ficou mais pobre que o agente
-- original. Faltavam: POSICAO GESTOR no ranking, cidade/faturamento/
-- funcionarios na base, abrangencia em texto livre, escolha de 1 ou 2
-- executivos por empresa e selecao de quais rodadas anteriores excluir.
-- =====================================================================

set search_path = gestao, public;

-- =====================================================================
-- 1. CAMPOS QUE FALTAVAM NO GESTOR
-- =====================================================================

alter table gestores add column if not exists posicao_gestor text;
alter table gestores add column if not exists cidade text;
alter table gestores add column if not exists faturamento text;
alter table gestores add column if not exists funcionarios text;

-- =====================================================================
-- 2. RANKING DE POSICAO
--
-- A planilha traz "POSIÇÃO GESTOR" com 1, 2, 3... indicando quem e o
-- contato principal da empresa. Isso vem ANTES do cargo no criterio:
-- o organizador ja decidiu quem e o titular, e essa decisao ganha do
-- que esta escrito no cargo.
-- =====================================================================

create or replace function _rank_pos(v text)
returns int language sql immutable as $$
  select case
    when v is null then 2
    when v like '%1%' then 0
    when v like '%2%' then 1
    else 2
  end;
$$;

-- =====================================================================
-- 3. LOCALIDADES DA BASE
--
-- A abrangencia e texto livre ("Grande Brasilia e entorno") e quem
-- interpreta e a IA. Para isso ela precisa da lista de cidade|UF que
-- existe de fato na base, nao de uma lista de UFs.
-- =====================================================================

create or replace function admin_localidades_base()
returns table (cidade text, estado text, empresas bigint)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select coalesce(nullif(trim(g.cidade),''), '—'),
           coalesce(nullif(trim(g.estado),''), '—'),
           count(distinct lower(trim(g.empresa)))
    from gestores g
    where g.ativo and coalesce(trim(g.empresa),'') <> ''
    group by 1, 2
    order by 3 desc, 1;
end;
$$;

-- =====================================================================
-- 4. RODADAS ANTERIORES
--
-- No agente, o organizador marcava quais jantares anteriores nao devem
-- repetir. Aqui as rodadas ficam salvas no banco, entao a lista e real
-- e nao depende do navegador.
-- =====================================================================

create or replace function admin_listar_rodadas()
returns table (rodada_id text, evento text, patrocinador text,
               quando timestamptz, empresas bigint)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select coalesce(pr.sessao_id::text, 'sem-sessao-' || pr.evento_id::text),
           e.nome,
           coalesce(p.empresa, '—'),
           max(pr.created_at),
           count(distinct lower(trim(pr.empresa)))
    from prospeccoes pr
    join eventos e on e.id = pr.evento_id
    left join patrocinadores p on p.id = pr.patrocinador_id
    where pr.status in ('aprovado','convidado')
    group by 1, 2, 3
    order by 4 desc;
end;
$$;

-- Empresas de uma rodada, para excluir da proxima.
create or replace function admin_empresas_da_rodada(p_rodada text)
returns table (empresa text)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select distinct pr.empresa
    from prospeccoes pr
    where coalesce(pr.sessao_id::text, 'sem-sessao-' || pr.evento_id::text) = p_rodada
      and pr.status in ('aprovado','convidado')
      and coalesce(trim(pr.empresa),'') <> '';
end;
$$;

-- =====================================================================
-- 5. BASE DE PROSPECCAO COMPLETA
--
-- Uma linha por empresa, com 1o e 2o executivo escolhidos por
-- POSICAO GESTOR e depois por cargo. Devolve cidade, faturamento e
-- funcionarios porque a IA usa esses dados para pontuar o porte.
-- =====================================================================

drop function if exists admin_prospeccao_base(text, text[], boolean, boolean, text, int);

create or replace function admin_prospeccao_base(
  p_evento_slug text,
  p_excluir_fornecedores boolean default true,
  p_excluir_empresas text[] default null,   -- vindas das rodadas marcadas
  p_excluir_convidados boolean default true,
  p_tipo_sessao text default 'jantar',
  p_limite int default 500
) returns table (
  empresa text, segmento text, faturamento text, funcionarios text,
  cidade text, estado text, cnpj text,
  exec1_id uuid, exec1_nome text, exec1_cargo text,
  exec1_email text, exec1_telefone text,
  exec2_id uuid, exec2_nome text, exec2_cargo text,
  exec2_email text, exec2_telefone text,
  contatos bigint, ja_convidado_em text
) language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();

  return query
  with
  ja as (
    select lower(trim(g.empresa)) as empresa,
           string_agg(distinct ev.nome, ', ') as eventos
    from sessao_convidados sc
    join sessoes s   on s.id = sc.sessao_id and s.tipo = p_tipo_sessao
    join eventos ev  on ev.id = s.evento_id
    join participantes pa on pa.id = sc.participante_id
    join gestores g  on g.id = pa.gestor_id
    where sc.status = 'confirmado'
      and coalesce(trim(g.empresa),'') <> ''
    group by lower(trim(g.empresa))
  ),
  bloqueadas as (
    select lower(trim(x)) as empresa
    from unnest(coalesce(p_excluir_empresas, '{}'::text[])) as x
  ),
  ranqueado as (
    select g.*,
           row_number() over (
             partition by lower(trim(g.empresa))
             -- POSICAO GESTOR primeiro, cargo como desempate
             order by _rank_pos(g.posicao_gestor), _rank_cargo(g.cargo), g.nome) as pos,
           count(*) over (partition by lower(trim(g.empresa))) as n
    from gestores g
    where g.ativo
      and coalesce(trim(g.empresa),'') <> ''
      and coalesce(trim(g.nome),'') <> ''
      and (not p_excluir_fornecedores
           or coalesce(upper(unaccent('unaccent', g.perfil)),'')
              not like '%FORNECEDOR%')
  )
  select
    a.empresa, a.segmento, a.faturamento, a.funcionarios,
    a.cidade, a.estado, a.cnpj,
    a.id, a.nome, a.cargo, a.email, a.telefone,
    b.id, b.nome, b.cargo, b.email, b.telefone,
    a.n,
    j.eventos
  from ranqueado a
  left join ranqueado b
    on lower(trim(b.empresa)) = lower(trim(a.empresa)) and b.pos = 2
  left join ja j on j.empresa = lower(trim(a.empresa))
  left join bloqueadas bl on bl.empresa = lower(trim(a.empresa))
  where a.pos = 1
    and bl.empresa is null
    and (not p_excluir_convidados or j.empresa is null)
  order by a.empresa
  limit p_limite;
end;
$$;

-- =====================================================================
-- 6. IMPORTACAO RECONHECE OS CAMPOS NOVOS
-- =====================================================================

create or replace function admin_importar_gestores(p_linhas jsonb)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_item jsonb;
  v_id uuid; v_empresa_ant text; v_cargo_ant text; v_empresa_nova text;
  v_criados int := 0; v_atualizados int := 0; v_erros int := 0;
  v_sugeridos int := 0;
  v_erros_det jsonb := '[]'::jsonb;
  v_imp uuid; v_linha int := 0;
begin
  perform _exige_admin();

  insert into importacoes (tipo, total_linhas, executado_por)
  values ('gestores', jsonb_array_length(coalesce(p_linhas,'[]'::jsonb)),
          auth.jwt() ->> 'email')
  returning id into v_imp;

  for v_item in select * from jsonb_array_elements(coalesce(p_linhas,'[]'::jsonb))
  loop
    v_linha := v_linha + 1;

    if coalesce(trim(v_item ->> 'email'),'') = ''
       or coalesce(trim(v_item ->> 'nome'),'') = '' then
      v_erros := v_erros + 1;
      v_erros_det := v_erros_det || jsonb_build_object(
        'linha', v_linha, 'motivo', 'nome ou e-mail vazio',
        'nome', v_item ->> 'nome');
      continue;
    end if;

    select g.id, g.empresa, g.cargo into v_id, v_empresa_ant, v_cargo_ant
    from gestores g where g.email_norm = norm_doc(v_item ->> 'email');

    if v_id is null then
      insert into gestores (nome, email, empresa, cargo, telefone, cnpj,
                            segmento, estado, perfil, origem,
                            posicao_gestor, cidade, faturamento, funcionarios)
      values (trim(v_item ->> 'nome'), lower(trim(v_item ->> 'email')),
              nullif(v_item ->> 'empresa',''), nullif(v_item ->> 'cargo',''),
              nullif(v_item ->> 'telefone',''), nullif(v_item ->> 'cnpj',''),
              nullif(v_item ->> 'segmento',''), nullif(v_item ->> 'estado',''),
              nullif(v_item ->> 'perfil',''), 'importacao',
              nullif(v_item ->> 'posicao',''), nullif(v_item ->> 'cidade',''),
              nullif(v_item ->> 'faturamento',''), nullif(v_item ->> 'funcionarios',''));
      v_criados := v_criados + 1;
      continue;
    end if;

    v_empresa_nova := nullif(trim(v_item ->> 'empresa'), '');

    if v_empresa_nova is not null
       and coalesce(trim(v_empresa_ant),'') <> ''
       and lower(unaccent('unaccent', v_empresa_ant))
           <> lower(unaccent('unaccent', v_empresa_nova)) then

      insert into sugestoes_ia (tipo, gestor_id, campo, valor_atual,
                                valor_sugerido, confianca, fonte,
                                justificativa, status)
      select 'troca_empresa', v_id, 'empresa', v_empresa_ant,
             v_empresa_nova, 100, 'importacao de planilha',
             'Linha ' || v_linha || ' da planilha traz empresa diferente da cadastrada',
             'pendente'
      where not exists (
        select 1 from sugestoes_ia s
        where s.gestor_id = v_id and s.campo = 'empresa'
          and s.valor_sugerido = v_empresa_nova and s.status = 'pendente');

      v_sugeridos := v_sugeridos + 1;
    end if;

    if nullif(v_item ->> 'cargo','') is not null
       and lower(coalesce(v_cargo_ant,'')) <> lower(v_item ->> 'cargo') then
      insert into gestores_historico (gestor_id, campo, valor_antigo,
                                      valor_novo, detectado_por)
      values (v_id, 'cargo', v_cargo_ant, v_item ->> 'cargo', 'importacao');
    end if;

    update gestores set
      nome     = coalesce(nullif(v_item ->> 'nome',''), nome),
      empresa  = case when coalesce(trim(empresa),'') = ''
                      then coalesce(v_empresa_nova, empresa) else empresa end,
      cargo    = coalesce(nullif(v_item ->> 'cargo',''), cargo),
      telefone = coalesce(nullif(v_item ->> 'telefone',''), telefone),
      cnpj     = coalesce(nullif(v_item ->> 'cnpj',''), cnpj),
      segmento = coalesce(nullif(v_item ->> 'segmento',''), segmento),
      estado   = coalesce(nullif(v_item ->> 'estado',''), estado),
      perfil   = coalesce(nullif(v_item ->> 'perfil',''), perfil),
      posicao_gestor = coalesce(nullif(v_item ->> 'posicao',''), posicao_gestor),
      cidade   = coalesce(nullif(v_item ->> 'cidade',''), cidade),
      faturamento  = coalesce(nullif(v_item ->> 'faturamento',''), faturamento),
      funcionarios = coalesce(nullif(v_item ->> 'funcionarios',''), funcionarios)
    where id = v_id;

    v_atualizados := v_atualizados + 1;
  end loop;

  update importacoes set criados = v_criados, atualizados = v_atualizados,
                         erros = v_erros
   where id = v_imp;

  return jsonb_build_object('ok', true, 'criados', v_criados,
    'atualizados', v_atualizados, 'erros', v_erros,
    'sugestoes', v_sugeridos, 'detalhe_erros', v_erros_det);
end;
$$;

grant execute on function
  _rank_pos(text),
  admin_localidades_base(),
  admin_listar_rodadas(),
  admin_empresas_da_rodada(text),
  admin_prospeccao_base(text, boolean, text[], boolean, text, int),
  admin_importar_gestores(jsonb)
to authenticated;
