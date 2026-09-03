-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Atividade ganha tipo: geral (todos os participantes do evento sao
-- esperados, comportamento de hoje) ou exclusiva (so uma lista fechada
-- de CIOs escolhidos a dedo, tipo a lista de convidados de uma sessao
-- de mesa redonda). Achado real, reportado pelo Gerardo: "Na atividade
-- colocar se e geral (todos) ou exclusiva, no caso da exclusiva
-- escolher os cios que vao participar".
-- =====================================================================

set search_path = gestao, public;

alter table atividades add column if not exists tipo_presenca text not null default 'geral';
alter table atividades drop constraint if exists atividades_tipo_presenca_check;
alter table atividades add constraint atividades_tipo_presenca_check
  check (tipo_presenca in ('geral','exclusiva'));

create table if not exists atividade_convidados (
  atividade_id    uuid not null references atividades(id) on delete cascade,
  participante_id uuid not null references participantes(id) on delete cascade,
  created_at      timestamptz default now(),
  primary key (atividade_id, participante_id)
);

alter table atividade_convidados enable row level security;
drop policy if exists atividade_convidados_staff_all on atividade_convidados;
create policy atividade_convidados_staff_all on atividade_convidados using (is_staff());

-- ---------------------------------------------------------------------
-- admin_listar_atividades ganha tipo_presenca — muda o retorno, precisa
-- dropar antes (mesma regra de sempre: CREATE OR REPLACE nao troca
-- lista de coluna de retorno).
-- ---------------------------------------------------------------------
drop function if exists admin_listar_atividades(text);

create or replace function admin_listar_atividades(p_evento_slug text)
returns table(id uuid, nome text, data date, horario_inicio time, horario_fim time,
              local text, tipo_presenca text, esperados bigint, presentes bigint)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select a.id, a.nome, a.data, a.horario_inicio, a.horario_fim, a.local, a.tipo_presenca,
           case when a.tipo_presenca = 'exclusiva'
                then (select count(*) from atividade_convidados ac where ac.atividade_id = a.id)
                else (select count(*) from v_esperados v where v.evento_id = a.evento_id)
           end,
           (select count(*) from checkins c where c.atividade_id = a.id and c.desfeito_em is null)
    from atividades a
    join eventos e on e.id = a.evento_id and e.slug = p_evento_slug
    order by a.data nulls last, a.horario_inicio nulls last, a.nome;
end;
$$;

-- ganha p_tipo_presenca no fim, com default — nao muda a lista de
-- colunas que ja existia, CREATE OR REPLACE resolve sem DROP
create or replace function admin_salvar_atividade(
  p_id uuid, p_evento_slug text, p_nome text, p_data date,
  p_horario_inicio time, p_horario_fim time, p_local text,
  p_tipo_presenca text DEFAULT 'geral'::text
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_evento uuid; v_id uuid; v_tipo text;
begin
  perform _exige_admin();
  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome da atividade' using errcode = '22023';
  end if;
  v_tipo := case when p_tipo_presenca = 'exclusiva' then 'exclusiva' else 'geral' end;

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode = 'P0002';
  end if;

  if p_id is null then
    insert into atividades (evento_id, nome, data, horario_inicio, horario_fim, local, tipo_presenca)
    values (v_evento, trim(p_nome), p_data, p_horario_inicio, p_horario_fim, nullif(trim(p_local),''), v_tipo)
    returning id into v_id;
  else
    update atividades set
      nome = trim(p_nome), data = p_data,
      horario_inicio = p_horario_inicio, horario_fim = p_horario_fim,
      local = nullif(trim(p_local),''), tipo_presenca = v_tipo, updated_at = now()
    where id = p_id and evento_id = v_evento
    returning id into v_id;
    if v_id is null then
      raise exception 'Atividade nao encontrada' using errcode = 'P0002';
    end if;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- ---------------------------------------------------------------------
-- lista de participantes do evento pra escolher quem entra na
-- atividade exclusiva — mesmo espirito de patrocinadoresDaCota, so que
-- pra CIO em vez de patrocinador
-- ---------------------------------------------------------------------
create or replace function admin_listar_convidados_atividade(p_atividade_id uuid)
returns table(participante_id uuid, nome text, empresa text, marcado boolean)
language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_evento uuid;
begin
  perform _exige_staff_da_atividade(p_atividade_id);
  select evento_id into v_evento from atividades where id = p_atividade_id;
  if v_evento is null then
    raise exception 'Atividade nao encontrada' using errcode = 'P0002';
  end if;

  return query
    select v.participante_id, v.nome, v.empresa,
           exists(select 1 from atividade_convidados ac
                   where ac.atividade_id = p_atividade_id
                     and ac.participante_id = v.participante_id)
    from v_painel_participantes v
    where v.evento_id = v_evento
    order by v.nome;
end;
$$;

create or replace function admin_definir_convidados_atividade(p_atividade_id uuid, p_participantes uuid[])
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_evento uuid; v_dentro int; v_fora int;
begin
  perform _exige_staff_da_atividade(p_atividade_id);

  select evento_id into v_evento from atividades where id = p_atividade_id;
  if v_evento is null then
    raise exception 'Atividade nao encontrada' using errcode='P0002';
  end if;

  delete from atividade_convidados
   where atividade_id = p_atividade_id
     and not (participante_id = any(coalesce(p_participantes, '{}'::uuid[])));
  get diagnostics v_fora = row_count;

  insert into atividade_convidados (atividade_id, participante_id)
  select p_atividade_id, pid
  from unnest(coalesce(p_participantes, '{}'::uuid[])) as pid
  join participantes pa on pa.id = pid and pa.evento_id = v_evento
  on conflict do nothing;
  get diagnostics v_dentro = row_count;

  return jsonb_build_object('ok', true, 'na_lista', v_dentro, 'removidos', v_fora);
end;
$$;

-- ---------------------------------------------------------------------
-- atividade_checkin_listar/registrar passam a respeitar a lista
-- fechada quando a atividade e exclusiva — so quem esta em
-- atividade_convidados aparece/pode fazer check-in
-- ---------------------------------------------------------------------
create or replace function atividade_checkin_listar(
  p_atividade_id uuid, p_termo text default null,
  p_so_pendentes boolean default false, p_limite int default 300
) returns table(pessoa_key text, nome text, empresa text, categoria text,
                checkin_id uuid, registrado_em timestamptz)
language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_evento uuid; v_tipo text; v_termo text;
begin
  perform _exige_staff_da_atividade(p_atividade_id);
  select evento_id, tipo_presenca into v_evento, v_tipo from atividades where id = p_atividade_id;
  if v_evento is null then
    raise exception 'Atividade nao encontrada' using errcode = 'P0002';
  end if;
  v_termo := nullif(trim(coalesce(p_termo,'')), '');

  return query
    select v.pessoa_key, v.nome, v.empresa, v.categoria, c.id, c.registrado_em
    from v_esperados v
    left join checkins c on c.pessoa_key = v.pessoa_key
                         and c.atividade_id = p_atividade_id
                         and c.desfeito_em is null
    where v.evento_id = v_evento
      and (v_tipo <> 'exclusiva'
           or exists(select 1 from atividade_convidados ac
                      where ac.atividade_id = p_atividade_id
                        and v.pessoa_key = 'participante:' || ac.participante_id::text))
      and (v_termo is null
           or v.nome ilike '%'||v_termo||'%'
           or coalesce(v.empresa,'') ilike '%'||v_termo||'%')
      and (not p_so_pendentes or c.id is null)
    order by (c.id is not null), v.nome
    limit p_limite;
end;
$$;

create or replace function atividade_checkin_registrar(p_atividade_id uuid, p_pessoa_key text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid; v_tipo text; v_nome text; v_email text; v_patro uuid; v_ocupante uuid;
  v_ja timestamptz; v_id uuid;
begin
  perform _exige_staff_da_atividade(p_atividade_id);

  select evento_id, tipo_presenca into v_evento, v_tipo from atividades where id = p_atividade_id;
  if v_evento is null then
    raise exception 'Atividade nao encontrada' using errcode = 'P0002';
  end if;

  if v_tipo = 'exclusiva' and not exists(
    select 1 from atividade_convidados ac
     where ac.atividade_id = p_atividade_id
       and p_pessoa_key = 'participante:' || ac.participante_id::text
  ) then
    raise exception 'Essa pessoa nao esta na lista fechada desta atividade' using errcode = '22023';
  end if;

  select v.nome, v.email, v.patrocinador_id
    into v_nome, v_email, v_patro
  from v_esperados v
  where v.pessoa_key = p_pessoa_key and v.evento_id = v_evento;

  if v_nome is null then
    raise exception 'Pessoa nao encontrada neste evento' using errcode = 'P0002';
  end if;

  if p_pessoa_key like 'ocupante:%' then
    v_ocupante := substring(p_pessoa_key from 10)::uuid;
  end if;

  select c.registrado_em into v_ja from checkins c
   where c.pessoa_key = p_pessoa_key and c.atividade_id = p_atividade_id
     and c.desfeito_em is null
   limit 1;

  if v_ja is not null then
    return jsonb_build_object('ok', true, 'ja_estava', true,
                              'nome', v_nome, 'registrado_em', v_ja);
  end if;

  insert into checkins (evento_id, patrocinador_id, ocupante_id, pessoa_key,
                        nome, email, atividade_id, registrado_por)
  values (v_evento, v_patro, v_ocupante, p_pessoa_key, v_nome, v_email,
          p_atividade_id, auth.jwt() ->> 'email')
  returning id into v_id;

  return jsonb_build_object('ok', true, 'ja_estava', false, 'id', v_id, 'nome', v_nome);
end;
$$;

revoke execute on function admin_listar_atividades(text) from public, anon;
revoke execute on function admin_salvar_atividade(uuid,text,text,date,time,time,text,text) from public, anon;
revoke execute on function admin_listar_convidados_atividade(uuid) from public, anon;
revoke execute on function admin_definir_convidados_atividade(uuid,uuid[]) from public, anon;
revoke execute on function atividade_checkin_listar(uuid,text,boolean,int) from public, anon;
revoke execute on function atividade_checkin_registrar(uuid,text) from public, anon;
grant execute on function admin_listar_atividades(text) to authenticated, service_role;
grant execute on function admin_salvar_atividade(uuid,text,text,date,time,time,text,text) to authenticated, service_role;
grant execute on function admin_listar_convidados_atividade(uuid) to authenticated, service_role;
grant execute on function admin_definir_convidados_atividade(uuid,uuid[]) to authenticated, service_role;
grant execute on function atividade_checkin_listar(uuid,text,boolean,int) to authenticated, service_role;
grant execute on function atividade_checkin_registrar(uuid,text) to authenticated, service_role;
