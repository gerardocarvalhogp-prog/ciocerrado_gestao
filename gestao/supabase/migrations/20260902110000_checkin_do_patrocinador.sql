-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Patrocinador faz check-in de CIO — dois casos, escolhidos pelo
-- Gerardo entre as opcoes levantadas:
--
--   1. VISITA AO LOUNGE (novo) — o patrocinador le o cracha (QR que o
--      CIO ja carrega, o mesmo de v_etiquetas) quando o CIO passa no
--      estande/lounge dele. Tabela nova: nao existia nenhum conceito
--      de visita ao lounge no banco. O CIO tambem pode se
--      autodeclarar (origem='cio'), pela propria area dele — daí o
--      relatorio pedido de "quem fez": ele (patrocinador) x CIO.
--
--   2. PRESENCA NA MESA REDONDA/REUNIAO — sessoes ja tem a lista de
--      convidados confirmados (sessao_convidados), so faltava marcar
--      quem realmente apareceu. Ganha presente/presente_em direto na
--      tabela, sem tabela nova.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. VISITA AO LOUNGE
-- ---------------------------------------------------------------------
create table if not exists lounge_visitas (
  id               uuid primary key default gen_random_uuid(),
  patrocinador_id  uuid not null references patrocinadores(id) on delete cascade,
  gestor_id        uuid not null references gestores(id) on delete cascade,
  origem           text not null check (origem in ('patrocinador','cio')),
  registrado_em    timestamptz not null default now(),
  registrado_por   text,
  unique (patrocinador_id, gestor_id)
);
comment on table lounge_visitas is
  'Um CIO visitou o lounge/estande de um patrocinador. origem diz quem registrou: o proprio patrocinador (leu o cracha) ou o CIO (se autodeclarou).';

alter table lounge_visitas enable row level security;
create policy lounge_visitas_staff_all on lounge_visitas
  for all to authenticated using (is_staff()) with check (is_staff());
revoke all on table lounge_visitas from anon, authenticated;

-- resolve pessoa_key (formato de v_etiquetas/v_esperados) pro gestor_id
-- por tras dela. Uso interno so desta migration — nao e a mesma coisa
-- que _meu_participante, que resolve o CALLER, nao um cracha lido.
create or replace function _gestor_do_pessoa_key(p_pessoa_key text)
returns uuid language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_gestor uuid;
begin
  if p_pessoa_key like 'ocupante:%' then
    select pa.gestor_id into v_gestor
    from ocupantes o
    join reservas r on r.id = o.reserva_id
    join participantes pa on pa.id = r.participante_id
    where o.id = substring(p_pessoa_key from 10)::uuid;
  elsif p_pessoa_key like 'participante:%' then
    select gestor_id into v_gestor from participantes
    where id = substring(p_pessoa_key from 14)::uuid;
  end if;
  return v_gestor;
end;
$$;

create or replace function patro_lounge_registrar(p_patrocinador_id uuid, p_pessoa_key text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_gestor uuid; v_nome text; v_id uuid; v_ja timestamptz;
begin
  perform _exige_patrocinador(p_patrocinador_id);

  v_gestor := _gestor_do_pessoa_key(p_pessoa_key);
  if v_gestor is null then
    raise exception 'Esse crachá não é de um CIO — não dá pra registrar visita ao lounge'
      using errcode = '22023';
  end if;

  select nome into v_nome from gestores where id = v_gestor;

  select registrado_em into v_ja from lounge_visitas
   where patrocinador_id = p_patrocinador_id and gestor_id = v_gestor;
  if v_ja is not null then
    return jsonb_build_object('ok', true, 'ja_estava', true, 'nome', v_nome, 'registrado_em', v_ja);
  end if;

  insert into lounge_visitas (patrocinador_id, gestor_id, origem, registrado_por)
  values (p_patrocinador_id, v_gestor, 'patrocinador', auth.jwt() ->> 'email')
  returning id into v_id;

  return jsonb_build_object('ok', true, 'ja_estava', false, 'id', v_id, 'nome', v_nome);
end;
$$;

-- o CIO se autodeclara, pela propria area dele — nao precisa do
-- patrocinador ler nada
create or replace function part_lounge_registrar(p_evento_slug text, p_patrocinador_id uuid)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_part uuid; v_gestor uuid; v_id uuid; v_ja timestamptz;
begin
  v_part := _meu_participante(p_evento_slug);
  if v_part is null then
    raise exception 'Inscricao nao encontrada' using errcode = 'P0002';
  end if;
  select gestor_id into v_gestor from participantes where id = v_part;

  if not exists (select 1 from patrocinadores where id = p_patrocinador_id and status = 'ativo') then
    raise exception 'Patrocinador não encontrado' using errcode = 'P0002';
  end if;

  select registrado_em into v_ja from lounge_visitas
   where patrocinador_id = p_patrocinador_id and gestor_id = v_gestor;
  if v_ja is not null then
    return jsonb_build_object('ok', true, 'ja_estava', true, 'registrado_em', v_ja);
  end if;

  insert into lounge_visitas (patrocinador_id, gestor_id, origem, registrado_por)
  values (p_patrocinador_id, v_gestor, 'cio', auth.jwt() ->> 'email')
  returning id into v_id;

  return jsonb_build_object('ok', true, 'ja_estava', false, 'id', v_id);
end;
$$;

create or replace function patro_lounge_listar(p_patrocinador_id uuid, p_origem text DEFAULT NULL::text)
returns table (id uuid, nome text, empresa text, origem text, registrado_em timestamptz)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_patrocinador(p_patrocinador_id);
  return query
    select lv.id, g.nome, g.empresa, lv.origem, lv.registrado_em
    from lounge_visitas lv
    join gestores g on g.id = lv.gestor_id
    where lv.patrocinador_id = p_patrocinador_id
      and (p_origem is null or lv.origem = p_origem)
    order by lv.registrado_em desc;
end;
$$;

create or replace function patro_lounge_desfazer(p_visita_id uuid)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_patro uuid;
begin
  select patrocinador_id into v_patro from lounge_visitas where id = p_visita_id;
  perform _exige_patrocinador(v_patro);
  delete from lounge_visitas where id = p_visita_id;
  return jsonb_build_object('ok', true);
end;
$$;

-- pro CIO escolher qual patrocinador ele esta autodeclarando visita —
-- so nome e id, nada sensivel, mas mesmo assim so authenticated
create or replace function part_listar_patrocinadores(p_evento_slug text)
returns table (id uuid, empresa text)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  if _meu_participante(p_evento_slug) is null then
    raise exception 'Inscricao nao encontrada' using errcode = 'P0002';
  end if;
  return query
    select p.id, p.empresa
    from patrocinadores p
    join eventos e on e.id = p.evento_id and e.slug = p_evento_slug
    where p.status = 'ativo'
    order by p.empresa;
end;
$$;

revoke execute on function _gestor_do_pessoa_key(text) from public, anon;
revoke execute on function patro_lounge_registrar(uuid,text) from public, anon;
revoke execute on function part_lounge_registrar(text,uuid) from public, anon;
revoke execute on function part_listar_patrocinadores(text) from public, anon;
revoke execute on function patro_lounge_listar(uuid,text) from public, anon;
revoke execute on function patro_lounge_desfazer(uuid) from public, anon;
grant execute on function patro_lounge_registrar(uuid,text) to authenticated, service_role;
grant execute on function part_lounge_registrar(text,uuid) to authenticated, service_role;
grant execute on function part_listar_patrocinadores(text) to authenticated, service_role;
grant execute on function patro_lounge_listar(uuid,text) to authenticated, service_role;
grant execute on function patro_lounge_desfazer(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2. PRESENCA NA MESA REDONDA / REUNIAO EXCLUSIVA
-- ---------------------------------------------------------------------
alter table sessao_convidados add column if not exists presente boolean not null default false;
alter table sessao_convidados add column if not exists presente_em timestamptz;
comment on column sessao_convidados.presente is
  'Marcado pelo patrocinador no dia — quem realmente apareceu na mesa/reuniao, distinto de quem so foi confirmado antes.';

-- patro_convidados_disponiveis e a lista de QUEM DA PRA ESCOLHER;
-- aqui e o oposto, quem JA foi escolhido — pra marcar presenca depois
-- que a sessao fechou. Nao existia nenhuma das duas ainda.
create or replace function patro_meus_escolhidos(p_sessao_id uuid)
returns table (convidado_id uuid, nome text, empresa text, presente boolean, presente_em timestamptz)
language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_patro uuid;
begin
  select patrocinador_id into v_patro from sessoes where id = p_sessao_id;
  perform _exige_patrocinador(v_patro);

  return query
    select sc.id, g.nome, g.empresa, sc.presente, sc.presente_em
    from sessao_convidados sc
    join participantes pa on pa.id = sc.participante_id
    join gestores g on g.id = pa.gestor_id
    where sc.sessao_id = p_sessao_id and sc.status = 'confirmado'
    order by g.nome;
end;
$$;

revoke execute on function patro_meus_escolhidos(uuid) from public, anon;
grant execute on function patro_meus_escolhidos(uuid) to authenticated, service_role;

create or replace function patro_sessao_marcar_presenca(p_sessao_id uuid, p_convidado_id uuid, p_presente boolean DEFAULT true)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_patro uuid;
begin
  select patrocinador_id into v_patro from sessoes where id = p_sessao_id;
  perform _exige_patrocinador(v_patro);

  update sessao_convidados set
    presente = p_presente,
    presente_em = case when p_presente then now() else null end
  where id = p_convidado_id and sessao_id = p_sessao_id and status = 'confirmado';

  if not found then
    raise exception 'Convidado não encontrado nessa sessão' using errcode = 'P0002';
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function patro_sessao_marcar_presenca(uuid,uuid,boolean) from public, anon;
grant execute on function patro_sessao_marcar_presenca(uuid,uuid,boolean) to authenticated, service_role;
