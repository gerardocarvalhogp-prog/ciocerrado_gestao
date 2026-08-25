-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- migracao-05.sql  ·  convidado avulso e check-in de quem nao esta na lista
--
-- Rodar DEPOIS de migracao-04.sql.
--
-- Dois buracos do mesmo tipo: o sistema so conhecia quem passou pelo
-- Sympla. Ficavam de fora o staff do CIO Cerrado, a equipe do
-- patrocinador e as trocas de ultima hora — justamente quem mais
-- aparece no balcao no dia do evento.
-- =====================================================================

set search_path = gestao, public;

-- =====================================================================
-- 1. CONVIDADO AVULSO NOS JANTARES
-- =====================================================================

-- Marca de onde a pessoa veio, para o mailing sair identificado
-- ("CIO CERRADO", "Patrocinador — Lanlink") em vez de misturada com
-- os CIOs convidados.
alter table sessao_convidados add column if not exists rotulo text;

-- Cria a pessoa e ja coloca na sessao. Se o e-mail ja existe na base,
-- reaproveita o gestor em vez de duplicar.
create or replace function admin_convidado_avulso(
  p_sessao_id uuid,
  p_nome      text,
  p_empresa   text default null,
  p_email     text default null,
  p_telefone  text default null,
  p_cargo     text default null,
  p_rotulo    text default null      -- 'CIO CERRADO', 'PATROCINADOR'...
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid; v_gestor uuid; v_part uuid;
  v_vagas int; v_ocupadas int; v_reaproveitado boolean := false;
begin
  perform _exige_staff();

  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome' using errcode='22023';
  end if;

  select s.evento_id, s.vagas into v_evento, v_vagas
  from sessoes s where s.id = p_sessao_id;

  if v_evento is null then
    raise exception 'Sessao nao encontrada' using errcode='P0002';
  end if;

  select count(*) into v_ocupadas from sessao_convidados
   where sessao_id = p_sessao_id and status = 'confirmado';

  if v_ocupadas >= v_vagas then
    raise exception 'A sessao ja tem % de % vaga(s) ocupada(s)', v_ocupadas, v_vagas
      using errcode='22023';
  end if;

  -- gestor: reaproveita pelo e-mail; sem e-mail, cria sempre novo
  if coalesce(trim(p_email),'') <> '' then
    select g.id into v_gestor from gestores g
     where g.email_norm = norm_doc(p_email);
    v_reaproveitado := v_gestor is not null;
  end if;

  if v_gestor is null then
    insert into gestores (nome, email, empresa, cargo, telefone, perfil, origem)
    values (trim(p_nome),
            -- e-mail e chave unica; sem ele geramos um interno para nao
            -- colidir com outra pessoa sem e-mail
            coalesce(nullif(lower(trim(p_email)),''),
                     'avulso.' || replace(gen_random_uuid()::text,'-','')
                     || '@interno.ciocerrado.com.br'),
            p_empresa, p_cargo, p_telefone,
            coalesce(nullif(trim(p_rotulo),''), 'CONVIDADO'), 'manual')
    returning id into v_gestor;
  end if;

  -- participante do evento, ja aprovado: convidado avulso nao passa
  -- pela fila de aprovacao
  select pa.id into v_part from participantes pa
   where pa.evento_id = v_evento and pa.gestor_id = v_gestor;

  if v_part is null then
    insert into participantes (evento_id, gestor_id, status, origem, aprovado_em,
                               aprovado_por)
    values (v_evento, v_gestor, 'aprovado', 'manual', now(),
            auth.jwt() ->> 'email')
    returning id into v_part;
  else
    update participantes set status = 'aprovado'
     where id = v_part and status <> 'aprovado';
  end if;

  insert into sessao_convidados (sessao_id, participante_id, origem, rotulo)
  values (p_sessao_id, v_part, 'admin', nullif(trim(p_rotulo),''))
  on conflict do nothing;

  if v_ocupadas + 1 >= v_vagas then
    update sessoes set escolha_encerrada_em = now() where id = p_sessao_id;
  end if;

  return jsonb_build_object('ok', true, 'participante_id', v_part,
                            'gestor_reaproveitado', v_reaproveitado);
end;
$$;

-- A lista da sessao passa a mostrar o rotulo.
drop function if exists admin_convidados_sessao(uuid);

create or replace function admin_convidados_sessao(p_sessao_id uuid)
returns table (participante_id uuid, nome text, empresa text, cargo text,
               email text, origem text, rotulo text, aderencia numeric)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select sc.participante_id, g.nome, g.empresa, g.cargo, g.email,
           sc.origem, sc.rotulo, sc.aderencia
    from sessao_convidados sc
    join participantes pa on pa.id = sc.participante_id
    join gestores g on g.id = pa.gestor_id
    where sc.sessao_id = p_sessao_id and sc.status = 'confirmado'
    order by g.empresa, g.nome;
end;
$$;

-- Mailing por sessao, com o rotulo de quem nao veio pelo Sympla.
create or replace function admin_mailing_sessao(p_sessao_id uuid)
returns table (nome text, cargo text, empresa text, email text,
               telefone text, rotulo text)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select g.nome, g.cargo, g.empresa,
           -- e-mail interno gerado para quem nao tem: nao vai no mailing
           case when g.email like '%@interno.ciocerrado.com.br' then null
                else g.email end,
           g.telefone,
           coalesce(sc.rotulo, g.perfil)
    from sessao_convidados sc
    join participantes pa on pa.id = sc.participante_id
    join gestores g on g.id = pa.gestor_id
    where sc.sessao_id = p_sessao_id and sc.status = 'confirmado'
    order by g.empresa, g.nome;
end;
$$;

-- =====================================================================
-- 2. CHECK-IN DE QUEM NAO ESTA NA LISTA
--
-- Antes o check-in so enxergava ocupantes de quarto. Passa a enxergar
-- as mesmas tres fontes das etiquetas, mais quem for cadastrado na
-- hora pela recepcao.
-- =====================================================================

-- Chave generica da pessoa: evita tres colunas de FK e permite listar
-- fontes diferentes na mesma consulta.
alter table checkins add column if not exists pessoa_key text;

create index if not exists checkins_pessoa_ix on checkins(evento_id, pessoa_key)
  where desfeito_em is null;

-- Todo mundo que se espera no evento, venha de onde vier.
create or replace view v_esperados as

select r.evento_id,
       'ocupante:' || o.id::text            as pessoa_key,
       o.nome,
       coalesce(p.empresa, g.empresa)       as empresa,
       coalesce(o.categoria_cracha,
                case when r.patrocinador_id is not null then 'PATROCINADOR'
                     when o.tipo = 'titular' then 'PROTAGONISTA'
                     else 'ACOMPANHANTE' end) as categoria,
       q.numero                             as quarto,
       r.patrocinador_id,
       coalesce(o.email, g.email)           as email
from ocupantes o
join reservas r on r.id = o.reserva_id and r.status <> 'cancelado'
left join quartos q on q.id = r.quarto_id
left join patrocinadores p on p.id = r.patrocinador_id
left join participantes pa on pa.id = r.participante_id
left join gestores g on g.id = pa.gestor_id

union all

select pa.evento_id,
       'participante:' || pa.id::text,
       g.nome, g.empresa,
       coalesce(nullif(g.perfil,''), 'PROTAGONISTA'),
       null::text, null::uuid, g.email
from participantes pa
join gestores g on g.id = pa.gestor_id
where pa.status = 'aprovado'
  and not exists (select 1 from reservas r
                  where r.participante_id = pa.id and r.status <> 'cancelado')

union all

select p.evento_id,
       'usuario_patro:' || u.id::text,
       coalesce(u.nome, split_part(u.email,'@',1)), p.empresa,
       'PATROCINADOR', null::text, p.id, u.email
from usuarios_patrocinador u
join patrocinadores p on p.id = u.patrocinador_id
where u.ativo and p.status = 'ativo'
  and not exists (select 1 from reservas r
                  where r.patrocinador_id = p.id and r.status <> 'cancelado');

drop function if exists checkin_listar(text, text, boolean, int);

create or replace function checkin_listar(
  p_evento_slug text,
  p_termo text default null,
  p_so_pendentes boolean default false,
  p_limite int default 300
) returns table (
  pessoa_key text, nome text, empresa text, categoria text,
  quarto text, checkin_id uuid, registrado_em timestamptz
) language plpgsql stable security definer
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

drop function if exists checkin_registrar(uuid, text);

create or replace function checkin_registrar(
  p_evento_slug text,
  p_pessoa_key text,
  p_local text default null
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

-- Recepcao cadastra quem chegou e nao esta na lista, e ja da o check-in.
create or replace function checkin_cadastrar(
  p_evento_slug text,
  p_nome     text,
  p_empresa  text default null,
  p_email    text default null,
  p_telefone text default null,
  p_cargo    text default null,
  p_categoria text default 'PROTAGONISTA',
  p_local    text default null
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid; v_gestor uuid; v_part uuid;
  v_key text; v_reaproveitado boolean := false;
begin
  perform _exige_staff();

  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome' using errcode='22023';
  end if;

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;

  if coalesce(trim(p_email),'') <> '' then
    select g.id into v_gestor from gestores g
     where g.email_norm = norm_doc(p_email);
    v_reaproveitado := v_gestor is not null;
  end if;

  if v_gestor is null then
    insert into gestores (nome, email, empresa, cargo, telefone, perfil, origem)
    values (trim(p_nome),
            coalesce(nullif(lower(trim(p_email)),''),
                     'avulso.' || replace(gen_random_uuid()::text,'-','')
                     || '@interno.ciocerrado.com.br'),
            p_empresa, p_cargo, p_telefone,
            coalesce(nullif(trim(p_categoria),''), 'PROTAGONISTA'), 'manual')
    returning id into v_gestor;
  else
    -- completa o que faltava sem sobrescrever o que ja existia
    update gestores set
      empresa  = coalesce(empresa, p_empresa),
      telefone = coalesce(telefone, p_telefone),
      cargo    = coalesce(cargo, p_cargo)
    where id = v_gestor;
  end if;

  select pa.id into v_part from participantes pa
   where pa.evento_id = v_evento and pa.gestor_id = v_gestor;

  if v_part is null then
    insert into participantes (evento_id, gestor_id, status, origem,
                               aprovado_em, aprovado_por)
    values (v_evento, v_gestor, 'aprovado', 'manual', now(),
            auth.jwt() ->> 'email')
    returning id into v_part;
  else
    update participantes set status = 'aprovado'
     where id = v_part and status <> 'aprovado';
  end if;

  v_key := 'participante:' || v_part::text;

  -- registra o check-in na mesma chamada: a recepcao nao precisa
  -- cadastrar, procurar de novo e clicar outra vez
  return checkin_registrar(p_evento_slug, v_key, p_local)
         || jsonb_build_object('cadastrado', true,
                               'gestor_reaproveitado', v_reaproveitado);
end;
$$;

create or replace function checkin_resumo(p_evento_slug text)
returns jsonb language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_esperados int; v_feitos int;
begin
  perform _exige_staff();

  select count(*) into v_esperados
  from v_esperados v
  join eventos e on e.id = v.evento_id and e.slug = p_evento_slug;

  select count(*) into v_feitos
  from checkins c
  join eventos e on e.id = c.evento_id and e.slug = p_evento_slug
  where c.desfeito_em is null;

  return jsonb_build_object(
    'esperados', v_esperados,
    'feitos',    v_feitos,
    'pendentes', greatest(v_esperados - v_feitos, 0));
end;
$$;

grant execute on function
  admin_convidado_avulso(uuid, text, text, text, text, text, text),
  admin_convidados_sessao(uuid),
  admin_mailing_sessao(uuid),
  checkin_listar(text, text, boolean, int),
  checkin_registrar(text, text, text),
  checkin_cadastrar(text, text, text, text, text, text, text, text),
  checkin_resumo(text)
to authenticated;
