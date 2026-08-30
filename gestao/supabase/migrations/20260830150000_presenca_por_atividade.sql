-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Modulo de acompanhamento, presenca e cobranca — fase 3a: atividades
--
-- Reaproveita o que ja existe pro check-in geral (v_esperados,
-- pessoa_key no formato "ocupante:<uuid>"/"participante:<uuid>"/
-- "usuario_patro:<uuid>", checkin_desfazer) em vez de inventar um
-- esquema de identidade novo. A diferenca de atividade pro check-in
-- geral e so: pode repetir por pessoa (uma vez por atividade), e
-- fica ligado a atividade_id, nao a texto livre em "local".
--
-- usa_atividades fica desligado por padrao — a aba so aparece pro
-- evento que ligar. Isso e o mesmo mecanismo de prazos_evento.ativo,
-- aplicado aqui a nivel de evento inteiro em vez de etapa.
-- =====================================================================

set search_path = gestao, public;

alter table eventos add column if not exists usa_atividades boolean not null default false;

create table if not exists atividades (
  id              uuid primary key default gen_random_uuid(),
  evento_id       uuid not null references eventos(id) on delete cascade,
  nome            text not null,
  data            date,
  horario_inicio  time,
  horario_fim     time,
  local           text,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

alter table checkins add column if not exists atividade_id uuid references atividades(id) on delete cascade;
create index if not exists checkins_atividade_ix on checkins(atividade_id) where desfeito_em is null;

alter table atividades enable row level security;
create policy atividades_staff_all on atividades using (is_staff());

-- ---------------------------------------------------------------------
-- admin_listar_eventos ganha usa_atividades — o front decide mostrar
-- a aba com esse valor, sem precisar de outra consulta
-- ---------------------------------------------------------------------
-- ganha uma coluna nova (usa_atividades) — CREATE OR REPLACE nao muda
-- o conjunto de colunas de retorno, precisa dropar antes
drop function if exists admin_listar_eventos();

create or replace function admin_listar_eventos()
returns table(id uuid, slug text, nome text, local text, data_inicio date, data_fim date,
              status text, cota_unica boolean, prazo_contrato date, prazo_rooming date,
              prazo_cancelamento date, participantes bigint, escolha_abre_em timestamptz,
              sympla_url text, sympla_event_id text, usa_atividades boolean)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select e.id, e.slug, e.nome, e.local, e.data_inicio, e.data_fim,
           e.status, e.cota_unica,
           e.prazo_contrato, e.prazo_rooming, e.prazo_cancelamento,
           (select count(*) from participantes p where p.evento_id = e.id),
           e.escolha_abre_em,
           e.sympla_url, e.sympla_event_id, e.usa_atividades
    from eventos e
    order by e.data_inicio desc nulls last;
end;
$$;

-- DROP acima limpa os grants tambem — reaplica antes de mais nada
revoke all on function admin_listar_eventos() from public, anon;
grant all on function admin_listar_eventos() to authenticated, service_role;

create or replace function admin_definir_usa_atividades(p_evento_slug text, p_ligado boolean)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
begin
  perform _exige_admin();
  update eventos set usa_atividades = coalesce(p_ligado, false) where slug = p_evento_slug;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------
-- CRUD de atividades
-- ---------------------------------------------------------------------
create or replace function admin_listar_atividades(p_evento_slug text)
returns table(id uuid, nome text, data date, horario_inicio time, horario_fim time,
              local text, esperados bigint, presentes bigint)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select a.id, a.nome, a.data, a.horario_inicio, a.horario_fim, a.local,
           (select count(*) from v_esperados v where v.evento_id = a.evento_id),
           (select count(*) from checkins c where c.atividade_id = a.id and c.desfeito_em is null)
    from atividades a
    join eventos e on e.id = a.evento_id and e.slug = p_evento_slug
    order by a.data nulls last, a.horario_inicio nulls last, a.nome;
end;
$$;

create or replace function admin_salvar_atividade(
  p_id uuid, p_evento_slug text, p_nome text, p_data date,
  p_horario_inicio time, p_horario_fim time, p_local text
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_evento uuid; v_id uuid;
begin
  perform _exige_admin();
  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome da atividade' using errcode = '22023';
  end if;
  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode = 'P0002';
  end if;

  if p_id is null then
    insert into atividades (evento_id, nome, data, horario_inicio, horario_fim, local)
    values (v_evento, trim(p_nome), p_data, p_horario_inicio, p_horario_fim, nullif(trim(p_local),''))
    returning id into v_id;
  else
    update atividades set
      nome = trim(p_nome), data = p_data,
      horario_inicio = p_horario_inicio, horario_fim = p_horario_fim,
      local = nullif(trim(p_local),''), updated_at = now()
    where id = p_id and evento_id = v_evento
    returning id into v_id;
    if v_id is null then
      raise exception 'Atividade nao encontrada' using errcode = 'P0002';
    end if;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function admin_remover_atividade(p_atividade_id uuid)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
begin
  perform _exige_admin();
  delete from atividades where id = p_atividade_id;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------
-- presenca — mesmo par listar/registrar do check-in geral, so que
-- escopado por atividade_id em vez de "uma vez por evento"
-- ---------------------------------------------------------------------
create or replace function atividade_checkin_listar(
  p_atividade_id uuid, p_termo text default null,
  p_so_pendentes boolean default false, p_limite int default 300
) returns table(pessoa_key text, nome text, empresa text, categoria text,
                checkin_id uuid, registrado_em timestamptz)
language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_evento uuid; v_termo text;
begin
  perform _exige_staff();
  select evento_id into v_evento from atividades where id = p_atividade_id;
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
  v_evento uuid; v_nome text; v_email text; v_patro uuid; v_ocupante uuid;
  v_ja timestamptz; v_id uuid;
begin
  perform _exige_staff();

  select evento_id into v_evento from atividades where id = p_atividade_id;
  if v_evento is null then
    raise exception 'Atividade nao encontrada' using errcode = 'P0002';
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

-- ---------------------------------------------------------------------
-- checkin_registrar/checkin_listar (check-in GERAL do evento) casavam
-- por pessoa_key+evento_id sem excluir atividade_id — um check-in de
-- atividade contava como se fosse o check-in geral tambem, e
-- vice-versa. Sao coisas diferentes agora; cada um so enxerga o seu.
-- ---------------------------------------------------------------------
create or replace function checkin_listar(
  p_evento_slug text, p_termo text default null,
  p_so_pendentes boolean default false, p_limite integer default 300
) returns table(pessoa_key text, nome text, empresa text, categoria text,
                quarto text, checkin_id uuid, registrado_em timestamptz)
language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_termo text;
begin
  perform _exige_staff();
  v_termo := nullif(trim(coalesce(p_termo,'')), '');

  return query
    select v.pessoa_key, v.nome, v.empresa, v.categoria, v.quarto,
           c.id, c.registrado_em
    from v_esperados v
    join eventos e on e.id = v.evento_id and e.slug = p_evento_slug
    left join checkins c on c.pessoa_key = v.pessoa_key
                        and c.evento_id = v.evento_id
                        and c.atividade_id is null
                        and c.desfeito_em is null
    where (v_termo is null
           or v.nome ilike '%'||v_termo||'%'
           or coalesce(v.empresa,'') ilike '%'||v_termo||'%'
           or coalesce(v.email,'') ilike '%'||v_termo||'%')
      and (not p_so_pendentes or c.id is null)
    order by (c.id is not null), v.nome
    limit p_limite;
end;
$$;

create or replace function checkin_registrar(
  p_evento_slug text, p_pessoa_key text, p_local text default null
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid; v_nome text; v_email text; v_patro uuid;
  v_ocupante uuid; v_ja timestamptz; v_id uuid;
begin
  perform _exige_staff();

  select v.evento_id, v.nome, v.email, v.patrocinador_id
    into v_evento, v_nome, v_email, v_patro
  from v_esperados v
  join eventos e on e.id = v.evento_id and e.slug = p_evento_slug
  where v.pessoa_key = p_pessoa_key;

  if v_evento is null then
    raise exception 'Pessoa nao encontrada neste evento' using errcode='P0002';
  end if;

  if p_pessoa_key like 'ocupante:%' then
    v_ocupante := substring(p_pessoa_key from 10)::uuid;
  end if;

  select c.registrado_em into v_ja from checkins c
   where c.pessoa_key = p_pessoa_key and c.evento_id = v_evento
     and c.atividade_id is null
     and c.desfeito_em is null
   limit 1;

  if v_ja is not null then
    return jsonb_build_object('ok', true, 'ja_estava', true,
                              'nome', v_nome, 'registrado_em', v_ja);
  end if;

  insert into checkins (evento_id, patrocinador_id, ocupante_id, pessoa_key,
                        nome, email, local, registrado_por)
  values (v_evento, v_patro, v_ocupante, p_pessoa_key, v_nome, v_email,
          p_local, auth.jwt() ->> 'email')
  returning id into v_id;

  return jsonb_build_object('ok', true, 'ja_estava', false,
                            'id', v_id, 'nome', v_nome);
end;
$$;

revoke all on function checkin_listar(text,text,boolean,integer) from public, anon;
revoke all on function checkin_registrar(text,text,text) from public, anon;
grant all on function checkin_listar(text,text,boolean,integer) to authenticated, service_role;
grant all on function checkin_registrar(text,text,text) to authenticated, service_role;

revoke all on function admin_definir_usa_atividades(text,boolean) from public, anon;
revoke all on function admin_listar_atividades(text) from public, anon;
revoke all on function admin_salvar_atividade(uuid,text,text,date,time,time,text) from public, anon;
revoke all on function admin_remover_atividade(uuid) from public, anon;
revoke all on function atividade_checkin_listar(uuid,text,boolean,int) from public, anon;
revoke all on function atividade_checkin_registrar(uuid,text) from public, anon;
grant all on function admin_definir_usa_atividades(text,boolean) to authenticated, service_role;
grant all on function admin_listar_atividades(text) to authenticated, service_role;
grant all on function admin_salvar_atividade(uuid,text,text,date,time,time,text) to authenticated, service_role;
grant all on function admin_remover_atividade(uuid) to authenticated, service_role;
grant all on function atividade_checkin_listar(uuid,text,boolean,int) to authenticated, service_role;
grant all on function atividade_checkin_registrar(uuid,text) to authenticated, service_role;
