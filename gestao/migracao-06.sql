-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- migracao-06.sql  ·  jantares como modulo separado
--
-- Rodar DEPOIS de migracao-05.sql.
--
-- Ate aqui, cadastrar um jantar exigia criar um "evento" e passar pela
-- estrutura inteira do Experience (cotas, quartos, contrato...). Com
-- 40+ jantares por ano, isso nao se sustenta.
--
-- Este arquivo cria jantares e jantar_convidados como entidades
-- proprias, sem depender de eventos. A base de gestores continua
-- compartilhada — e o que faz o historico de "ja foi convidado"
-- funcionar de verdade, em vez de virar planilha solta de novo.
-- =====================================================================

set search_path = gestao, public;

-- =====================================================================
-- 1. TABELAS
-- =====================================================================

create table jantares (
  id                 uuid primary key default gen_random_uuid(),
  data               date,
  horario            time,
  local              text,
  patrocinador_nome  text not null,
  patrocinador_site  text,
  perfil_convidado   text,     -- o que o patrocinador busca no convidado
  observacoes        text,
  abrangencia        text,     -- texto livre, mesmo campo do agente
  capacidade         int not null default 8,
  status             text not null default 'planejado'
                     check (status in ('planejado','confirmado','realizado','cancelado')),
  criado_por         text,
  created_at         timestamptz default now(),
  updated_at         timestamptz default now()
);
create index jantares_data_ix on jantares(data);

create trigger trg_jantares_upd before update on jantares
  for each row execute function touch_updated_at();

create table jantar_convidados (
  id             uuid primary key default gen_random_uuid(),
  jantar_id      uuid not null references jantares(id) on delete cascade,
  gestor_id      uuid not null references gestores(id) on delete cascade,
  empresa        text,          -- copia da empresa no momento do convite
  origem         text not null default 'prospeccao'
                 check (origem in ('prospeccao','avulso','manual')),
  rotulo         text,          -- CIO CERRADO, PATROCINADOR... (avulso)
  score          numeric(5,2),
  natureza       text,
  justificativa  text,
  status         text not null default 'sugerido'
                 check (status in ('sugerido','convidado','confirmado','recusado','compareceu')),
  observacao     text,
  created_at     timestamptz default now(),
  updated_at     timestamptz default now()
);
create unique index jantar_convidados_uk on jantar_convidados(jantar_id, gestor_id);
create index jantar_convidados_gestor_ix on jantar_convidados(gestor_id);

create trigger trg_jantar_conv_upd before update on jantar_convidados
  for each row execute function touch_updated_at();

alter table jantares          enable row level security;
alter table jantar_convidados enable row level security;

create policy jantares_staff_all on jantares
  for all using (is_staff()) with check (is_staff());
create policy jantar_convidados_staff_all on jantar_convidados
  for all using (is_staff()) with check (is_staff());

-- =====================================================================
-- 2. AGENDA
-- =====================================================================

create or replace function jantar_listar(p_status text default null)
returns table (
  id uuid, data date, horario time, local text,
  patrocinador text, capacidade int, status text,
  confirmados bigint, compareceram bigint
) language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select j.id, j.data, j.horario, j.local, j.patrocinador_nome,
           j.capacidade, j.status,
           (select count(*) from jantar_convidados c
             where c.jantar_id = j.id and c.status in ('confirmado','compareceu')),
           (select count(*) from jantar_convidados c
             where c.jantar_id = j.id and c.status = 'compareceu')
    from jantares j
    where p_status is null or j.status = p_status
    order by j.data desc nulls last, j.created_at desc;
end;
$$;

create or replace function jantar_obter(p_id uuid)
returns table (
  id uuid, data date, horario time, local text,
  patrocinador_nome text, patrocinador_site text, perfil_convidado text,
  observacoes text, abrangencia text, capacidade int, status text
) language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select j.id, j.data, j.horario, j.local, j.patrocinador_nome,
           j.patrocinador_site, j.perfil_convidado, j.observacoes,
           j.abrangencia, j.capacidade, j.status
    from jantares j where j.id = p_id;
end;
$$;

create or replace function jantar_salvar(
  p_patrocinador_nome text,
  p_id uuid default null,
  p_data date default null,
  p_horario time default null,
  p_local text default null,
  p_patrocinador_site text default null,
  p_perfil_convidado text default null,
  p_observacoes text default null,
  p_abrangencia text default null,
  p_capacidade int default 8,
  p_status text default 'planejado'
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_id uuid; v_ja int;
begin
  perform _exige_admin();

  if coalesce(trim(p_patrocinador_nome),'') = '' then
    raise exception 'Informe o patrocinador' using errcode='22023';
  end if;
  if p_status not in ('planejado','confirmado','realizado','cancelado') then
    raise exception 'Status invalido: %', p_status using errcode='22023';
  end if;

  if p_id is not null then
    -- capacidade nao pode ficar menor que quem ja esta confirmado
    select count(*) into v_ja from jantar_convidados
     where jantar_id = p_id and status in ('confirmado','compareceu');
    if coalesce(p_capacidade,8) < v_ja then
      raise exception 'Já há % confirmado(s); a capacidade não pode ser menor que isso', v_ja
        using errcode='22023';
    end if;

    update jantares set
      data = p_data, horario = p_horario, local = p_local,
      patrocinador_nome = trim(p_patrocinador_nome),
      patrocinador_site = p_patrocinador_site,
      perfil_convidado = p_perfil_convidado,
      observacoes = p_observacoes, abrangencia = p_abrangencia,
      capacidade = coalesce(p_capacidade,8), status = p_status
    where id = p_id
    returning id into v_id;
  else
    insert into jantares (data, horario, local, patrocinador_nome,
                          patrocinador_site, perfil_convidado, observacoes,
                          abrangencia, capacidade, status, criado_por)
    values (p_data, p_horario, p_local, trim(p_patrocinador_nome),
            p_patrocinador_site, p_perfil_convidado, p_observacoes,
            p_abrangencia, coalesce(p_capacidade,8), p_status,
            auth.jwt() ->> 'email')
    returning id into v_id;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function jantar_remover(p_id uuid)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_n int;
begin
  perform _exige_admin();
  select count(*) into v_n from jantar_convidados
   where jantar_id = p_id and status in ('confirmado','compareceu');
  if v_n > 0 then
    raise exception 'Há % convidado(s) confirmado(s) neste jantar', v_n
      using errcode='23503';
  end if;
  delete from jantares where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;

-- =====================================================================
-- 3. PROSPECCAO PARA O JANTAR
--
-- Mesma logica de admin_prospeccao_base, adaptada: o historico olha
-- jantar_convidados de TODOS os jantares (novo modulo) e tambem
-- sessao_convidados tipo='jantar' (jantares antigos, dentro do
-- Experience) — para nao perder a continuidade do que ja foi feito.
-- =====================================================================

create or replace function jantar_base(
  p_jantar_id uuid,
  p_excluir_fornecedores boolean default true,
  p_excluir_convidados boolean default true,
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
  ja_novo as (
    select lower(trim(g.empresa)) as empresa,
           string_agg(distinct to_char(j.data,'DD/MM/YYYY'), ', ') as quando
    from jantar_convidados jc
    join jantares j on j.id = jc.jantar_id
    join gestores g on g.id = jc.gestor_id
    where jc.status in ('confirmado','compareceu')
      and coalesce(trim(g.empresa),'') <> ''
    group by lower(trim(g.empresa))
  ),
  ja_antigo as (
    select lower(trim(g.empresa)) as empresa,
           string_agg(distinct ev.nome, ', ') as quando
    from sessao_convidados sc
    join sessoes s on s.id = sc.sessao_id and s.tipo = 'jantar'
    join eventos ev on ev.id = s.evento_id
    join participantes pa on pa.id = sc.participante_id
    join gestores g on g.id = pa.gestor_id
    where sc.status = 'confirmado'
      and coalesce(trim(g.empresa),'') <> ''
    group by lower(trim(g.empresa))
  ),
  ja as (
    -- concat_ws de dois nulos vira string vazia, nao nulo — e o filtro
    -- "j.empresa is null" la embaixo depende de null para funcionar.
    -- nullif fecha essa brecha.
    select coalesce(n.empresa, a.empresa) as empresa,
           nullif(concat_ws(', ', n.quando, a.quando), '') as quando
    from ja_novo n full outer join ja_antigo a on a.empresa = n.empresa
  ),
  neste as (
    -- ja tem linha neste jantar (qualquer status): nao sugere de novo
    select lower(trim(g.empresa)) as empresa
    from jantar_convidados jc
    join gestores g on g.id = jc.gestor_id
    where jc.jantar_id = p_jantar_id
  ),
  ranqueado as (
    select g.*,
           row_number() over (
             partition by lower(trim(g.empresa))
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
    j.quando
  from ranqueado a
  left join ranqueado b
    on lower(trim(b.empresa)) = lower(trim(a.empresa)) and b.pos = 2
  left join ja j on j.empresa = lower(trim(a.empresa))
  left join neste ne on ne.empresa = lower(trim(a.empresa))
  where a.pos = 1
    and ne.empresa is null
    and (not p_excluir_convidados or j.empresa is null)
  order by a.empresa
  limit p_limite;
end;
$$;

-- Localidades e ranking de posicao ja existem (migracao-04). Reaproveita.

-- =====================================================================
-- 4. CONVIDADOS DO JANTAR
-- =====================================================================

create or replace function jantar_convidados_listar(p_jantar_id uuid)
returns table (
  id uuid, gestor_id uuid, nome text, empresa text, cargo text,
  email text, telefone text, origem text, rotulo text,
  score numeric, natureza text, justificativa text, status text
) language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select jc.id, jc.gestor_id, g.nome, coalesce(jc.empresa, g.empresa),
           g.cargo, g.email, g.telefone, jc.origem, jc.rotulo,
           jc.score, jc.natureza, jc.justificativa, jc.status
    from jantar_convidados jc
    join gestores g on g.id = jc.gestor_id
    where jc.jantar_id = p_jantar_id
    order by
      case jc.status when 'compareceu' then 0 when 'confirmado' then 1
                     when 'convidado' then 2 when 'sugerido' then 3 else 4 end,
      g.empresa, g.nome;
end;
$$;

-- Salva a selecao da analise. Quem estiver marcado "manter" entra como
-- 'convidado' (a organizacao ja decidiu chamar); o resto nao entra.
create or replace function jantar_salvar_selecao(
  p_jantar_id uuid,
  p_itens jsonb
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_item jsonb; v_n int := 0;
begin
  perform _exige_admin();

  for v_item in select * from jsonb_array_elements(coalesce(p_itens,'[]'::jsonb))
  loop
    if not (v_item ->> 'manter')::boolean then continue; end if;

    insert into jantar_convidados (jantar_id, gestor_id, empresa, origem,
                                   score, natureza, justificativa, status)
    values (p_jantar_id, (v_item ->> 'gestor_id')::uuid,
            v_item ->> 'empresa', 'prospeccao',
            nullif(v_item ->> 'score','')::numeric,
            v_item ->> 'natureza', v_item ->> 'justificativa', 'convidado')
    on conflict (jantar_id, gestor_id) do update set
      score = excluded.score, natureza = excluded.natureza,
      justificativa = excluded.justificativa;

    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'salvos', v_n);
end;
$$;

-- Convidado que nao veio da prospeccao: staff, patrocinador, troca de
-- ultima hora. Mesmo padrao ja usado no check-in do Experience.
create or replace function jantar_avulso(
  p_jantar_id uuid,
  p_nome      text,
  p_empresa   text default null,
  p_email     text default null,
  p_telefone  text default null,
  p_cargo     text default null,
  p_rotulo    text default null
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_gestor uuid; v_cap int; v_ocupados int; v_reaproveitado boolean := false;
begin
  perform _exige_staff();

  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome' using errcode='22023';
  end if;

  select capacidade into v_cap from jantares where id = p_jantar_id;
  if v_cap is null then
    raise exception 'Jantar nao encontrado' using errcode='P0002';
  end if;

  select count(*) into v_ocupados from jantar_convidados
   where jantar_id = p_jantar_id and status in ('confirmado','compareceu');

  if v_ocupados >= v_cap then
    raise exception 'O jantar já tem % de % vaga(s) ocupada(s)', v_ocupados, v_cap
      using errcode='22023';
  end if;

  if coalesce(trim(p_email),'') <> '' then
    select g.id into v_gestor from gestores g where g.email_norm = norm_doc(p_email);
    v_reaproveitado := v_gestor is not null;
  end if;

  if v_gestor is null then
    insert into gestores (nome, email, empresa, cargo, telefone, perfil, origem)
    values (trim(p_nome),
            coalesce(nullif(lower(trim(p_email)),''),
                     'avulso.' || replace(gen_random_uuid()::text,'-','')
                     || '@interno.ciocerrado.com.br'),
            p_empresa, p_cargo, p_telefone,
            coalesce(nullif(trim(p_rotulo),''), 'CONVIDADO'), 'manual')
    returning id into v_gestor;
  end if;

  insert into jantar_convidados (jantar_id, gestor_id, empresa, origem,
                                 rotulo, status)
  values (p_jantar_id, v_gestor, p_empresa, 'avulso',
          nullif(trim(p_rotulo),''), 'confirmado')
  on conflict (jantar_id, gestor_id) do update set status = 'confirmado';

  return jsonb_build_object('ok', true, 'gestor_reaproveitado', v_reaproveitado);
end;
$$;

create or replace function jantar_marcar_convidado(
  p_id uuid, p_status text, p_observacao text default null
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_jantar uuid; v_cap int; v_ocupados int;
begin
  perform _exige_staff();

  if p_status not in ('sugerido','convidado','confirmado','recusado','compareceu') then
    raise exception 'Status invalido: %', p_status using errcode='22023';
  end if;

  select jc.jantar_id into v_jantar from jantar_convidados jc where jc.id = p_id;
  if v_jantar is null then
    raise exception 'Convidado nao encontrado' using errcode='P0002';
  end if;

  if p_status in ('confirmado','compareceu') then
    select capacidade into v_cap from jantares where id = v_jantar;
    select count(*) into v_ocupados from jantar_convidados
     where jantar_id = v_jantar and status in ('confirmado','compareceu')
       and id <> p_id;
    if v_ocupados >= v_cap then
      raise exception 'O jantar já está com todas as % vaga(s) ocupadas', v_cap
        using errcode='22023';
    end if;
  end if;

  update jantar_convidados set
    status = p_status,
    observacao = coalesce(p_observacao, observacao)
  where id = p_id;

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function jantar_remover_convidado(p_id uuid)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
begin
  perform _exige_admin();
  delete from jantar_convidados where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;

-- =====================================================================
-- 5. ESTATISTICAS
-- =====================================================================

-- Quantas vezes cada gestor ja foi convidado (novo modulo + jantares
-- antigos do Experience), e quando foi a ultima vez.
create or replace function jantar_estatisticas_gestores(p_limite int default 200)
returns table (nome text, empresa text, vezes int, ultima_vez date)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    with tudo as (
      select jc.gestor_id, j.data
      from jantar_convidados jc
      join jantares j on j.id = jc.jantar_id
      where jc.status in ('confirmado','compareceu')

      union all

      select pa.gestor_id, s.data
      from sessao_convidados sc
      join sessoes s on s.id = sc.sessao_id and s.tipo = 'jantar'
      join participantes pa on pa.id = sc.participante_id
      where sc.status = 'confirmado'
    )
    select g.nome, g.empresa, count(*)::int, max(t.data)
    from tudo t
    join gestores g on g.id = t.gestor_id
    group by g.id, g.nome, g.empresa
    order by count(*) desc, g.nome
    limit p_limite;
end;
$$;

-- Empresas ativas na base que nunca foram convidadas para jantar
-- nenhum — a lista oposta, para achar quem falta prospectar.
create or replace function jantar_empresas_sem_convite(p_limite int default 200)
returns table (empresa text, segmento text, contatos bigint)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    with convidadas as (
      select distinct lower(trim(g.empresa)) as empresa
      from jantar_convidados jc
      join gestores g on g.id = jc.gestor_id
      where jc.status in ('confirmado','compareceu')

      union

      select distinct lower(trim(g.empresa))
      from sessao_convidados sc
      join sessoes s on s.id = sc.sessao_id and s.tipo = 'jantar'
      join participantes pa on pa.id = sc.participante_id
      join gestores g on g.id = pa.gestor_id
      where sc.status = 'confirmado'
    )
    select g.empresa, min(g.segmento), count(*)
    from gestores g
    where g.ativo and coalesce(trim(g.empresa),'') <> ''
      and not exists (select 1 from convidadas c where c.empresa = lower(trim(g.empresa)))
    group by g.empresa
    order by count(*) desc, g.empresa
    limit p_limite;
end;
$$;

grant execute on function
  jantar_listar(text), jantar_obter(uuid),
  jantar_salvar(text, uuid, date, time, text, text, text, text, text, int, text),
  jantar_remover(uuid),
  jantar_base(uuid, boolean, boolean, int),
  jantar_convidados_listar(uuid),
  jantar_salvar_selecao(uuid, jsonb),
  jantar_avulso(uuid, text, text, text, text, text, text),
  jantar_marcar_convidado(uuid, text, text),
  jantar_remover_convidado(uuid),
  jantar_estatisticas_gestores(int),
  jantar_empresas_sem_convite(int)
to authenticated;
