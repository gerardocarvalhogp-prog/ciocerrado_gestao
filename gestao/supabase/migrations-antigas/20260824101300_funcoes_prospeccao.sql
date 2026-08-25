-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- funcoes-prospeccao.sql  ·  quem convidar para os jantares
--
-- Rodar DEPOIS de migracao-02.sql.
--
-- Vem do agente de jantares, com duas diferencas:
--   1. a base e o banco, nao uma planilha enviada a cada uso
--   2. o historico de quem ja foi convidado e automatico, cruzando
--      todas as sessoes de todos os eventos
-- =====================================================================

set search_path = gestao, public;

-- =====================================================================
-- 1. RANKING DE CARGO
--
-- Empresa com tres pessoas cadastradas precisa de um criterio para
-- escolher quem convidar. Menor numero = mais senior.
-- =====================================================================

create or replace function _rank_cargo(v text)
returns int language sql immutable as $$
  select case
    when v is null then 9
    when upper(unaccent('unaccent', v)) ~ '(CIO|CTO|CHIEF|DIRETOR|DIRECTOR|PRESIDENTE|VP|VICE)' then 1
    when upper(unaccent('unaccent', v)) ~ '(SUPERINTENDENTE|HEAD)' then 2
    when upper(unaccent('unaccent', v)) ~ '(GERENTE|MANAGER)'      then 3
    when upper(unaccent('unaccent', v)) ~ '(COORDENADOR|COORD)'    then 4
    when upper(unaccent('unaccent', v)) ~ '(SUPERVISOR)'           then 5
    when upper(unaccent('unaccent', v)) ~ '(ANALISTA|ESPECIALISTA)' then 6
    else 9
  end;
$$;

-- =====================================================================
-- 2. BASE DE PROSPECCAO
--
-- Uma linha por EMPRESA, com o executivo mais senior e o segundo.
-- Ja exclui quem foi convidado antes e quem e fornecedor.
-- =====================================================================

create or replace function admin_prospeccao_base(
  p_evento_slug text,
  p_estados text[] default null,       -- {'GO','DF'}; null = todos
  p_excluir_fornecedores boolean default true,
  p_excluir_convidados boolean default true,
  p_tipo_sessao text default 'jantar',
  p_limite int default 300
) returns table (
  empresa text, segmento text, estado text, cnpj text,
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
  -- empresas que ja participaram de sessao deste tipo, em qualquer
  -- edicao. E o que o agente pedia por checkbox; aqui e automatico.
  -- Agrupado, nao window: DISTINCT dentro de window function nao
  -- existe no Postgres e o comando falharia em tempo de execucao.
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
  -- ordena os contatos de cada empresa por senioridade
  ranqueado as (
    select g.*,
           row_number() over (
             partition by lower(trim(g.empresa))
             order by _rank_cargo(g.cargo), g.nome) as pos,
           count(*) over (partition by lower(trim(g.empresa))) as n
    from gestores g
    where g.ativo
      and coalesce(trim(g.empresa),'') <> ''
      and coalesce(trim(g.nome),'') <> ''
      and (p_estados is null or g.estado = any(p_estados))
      and (not p_excluir_fornecedores
           or coalesce(upper(unaccent('unaccent', g.perfil)),'')
              not like '%FORNECEDOR%')
  )
  select
    a.empresa, a.segmento, a.estado, a.cnpj,
    a.id, a.nome, a.cargo, a.email, a.telefone,
    b.id, b.nome, b.cargo, b.email, b.telefone,
    a.n,
    j.eventos
  from ranqueado a
  left join ranqueado b
    on lower(trim(b.empresa)) = lower(trim(a.empresa)) and b.pos = 2
  left join ja j on j.empresa = lower(trim(a.empresa))
  where a.pos = 1
    and (not p_excluir_convidados or j.empresa is null)
  order by a.empresa
  limit p_limite;
end;
$$;

-- Estados presentes na base, para montar o filtro sem digitar UF na mao.
create or replace function admin_estados_base()
returns table (estado text, empresas bigint)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select g.estado, count(distinct lower(trim(g.empresa)))
    from gestores g
    where g.ativo and coalesce(trim(g.estado),'') <> ''
    group by g.estado
    order by 2 desc;
end;
$$;

-- =====================================================================
-- 3. GRAVAR A PROSPECCAO
-- =====================================================================

create table if not exists prospeccoes (
  id              uuid primary key default gen_random_uuid(),
  evento_id       uuid references eventos(id) on delete cascade,
  sessao_id       uuid references sessoes(id) on delete set null,
  patrocinador_id uuid references patrocinadores(id) on delete set null,
  gestor_id       uuid references gestores(id) on delete cascade,
  empresa         text,
  score           numeric(5,2),
  natureza        text,
  justificativa   text,
  status          text not null default 'sugerido'
                  check (status in ('sugerido','aprovado','descartado','convidado')),
  criado_por      text,
  created_at      timestamptz default now()
);
create index if not exists prospeccoes_ix on prospeccoes(evento_id, sessao_id, status);

alter table prospeccoes enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies
                 where schemaname='gestao' and tablename='prospeccoes') then
    create policy prospeccoes_staff_all on prospeccoes
      for all using (is_staff()) with check (is_staff());
  end if;
end $$;

-- Salva a rodada inteira de uma vez. p_itens:
--   [{gestor_id, empresa, score, natureza, justificativa, aprovado}]
create or replace function admin_salvar_prospeccao(
  p_evento_slug text,
  p_sessao_id uuid,
  p_itens jsonb
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid; v_patro uuid; v_item jsonb; v_n int := 0;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;

  if p_sessao_id is not null then
    select patrocinador_id into v_patro from sessoes where id = p_sessao_id;
  end if;

  -- substitui a rodada anterior da mesma sessao: a tela mostra uma
  -- lista de cada vez, e acumular geraria duplicata a cada reanalise
  delete from prospeccoes
   where evento_id = v_evento
     and sessao_id is not distinct from p_sessao_id
     and status = 'sugerido';

  for v_item in select * from jsonb_array_elements(coalesce(p_itens,'[]'::jsonb))
  loop
    insert into prospeccoes (evento_id, sessao_id, patrocinador_id,
                             gestor_id, empresa, score, natureza,
                             justificativa, status, criado_por)
    values (v_evento, p_sessao_id, v_patro,
            nullif(v_item ->> 'gestor_id','')::uuid,
            v_item ->> 'empresa',
            nullif(v_item ->> 'score','')::numeric,
            nullif(v_item ->> 'natureza',''),
            nullif(v_item ->> 'justificativa',''),
            case when (v_item ->> 'aprovado')::boolean then 'aprovado'
                 else 'sugerido' end,
            auth.jwt() ->> 'email');
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'salvos', v_n);
end;
$$;

create or replace function admin_listar_prospeccao(
  p_evento_slug text,
  p_sessao_id uuid default null
) returns table (id uuid, empresa text, nome text, cargo text,
                 email text, telefone text, score numeric,
                 natureza text, justificativa text, status text)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select pr.id, pr.empresa, g.nome, g.cargo, g.email, g.telefone,
           pr.score, pr.natureza, pr.justificativa, pr.status
    from prospeccoes pr
    left join gestores g on g.id = pr.gestor_id
    join eventos e on e.id = pr.evento_id and e.slug = p_evento_slug
    where (p_sessao_id is null or pr.sessao_id = p_sessao_id)
    order by pr.score desc nulls last, pr.empresa;
end;
$$;

create or replace function admin_marcar_prospeccao(
  p_id uuid,
  p_status text
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
begin
  perform _exige_admin();
  if p_status not in ('sugerido','aprovado','descartado','convidado') then
    raise exception 'Status invalido' using errcode='22023';
  end if;
  update prospeccoes set status = p_status where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function
  admin_prospeccao_base(text, text[], boolean, boolean, text, int),
  admin_estados_base(),
  admin_salvar_prospeccao(text, uuid, jsonb),
  admin_listar_prospeccao(text, uuid),
  admin_marcar_prospeccao(uuid, text),
  _rank_cargo(text)
to authenticated;
