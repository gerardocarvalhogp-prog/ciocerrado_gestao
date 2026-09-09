-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Preparo pro RPA de criacao de evento no Sympla.
--
-- A API publica do Sympla so' le (eventos, participantes, checkin) —
-- nao existe endpoint para criar evento, subir logo/banner ou lancar
-- convite/cortesia (pesquisado antes de propor isto; a biblioteca
-- cliente de referencia so' expoe metodos de leitura e checkin). Quem
-- faz esse papel e' um robo de navegador (Playwright), rodando FORA
-- deste ambiente — igual o integracao.py ja roda hoje —, nao uma RPC
-- daqui.
--
-- Este bloco so' prepara o lado do banco:
--   1. onde o organizador guarda a logo e a mensagem do jantar, aqui
--      na plataforma, antes do robo existir;
--   2. uma fila (jantar_listar_para_sympla) que diz pro robo o que
--      falta fazer;
--   3. como o robo confirma de volta o que ja fez
--      (jantar_marcar_sympla), sem esperar que alguem digite o link
--      manualmente.
--
-- GUARD PROPRIO EM VEZ DE _exige_admin()
--
-- _exige_admin() so' reconhece quem tem e-mail cadastrado em `admins`
-- (auth.jwt()->>'email') — funciona pra gente logada no navegador,
-- mas o token service_role (que o integracao.py ja usa, e que o robo
-- vai usar tambem) e' um JWT sem claim de e-mail nenhum. Testado local:
-- chamando is_admin() como service_role sem e-mail no JWT, day false —
-- _exige_admin() bloquearia o robo do mesmo jeito que bloqueia
-- qualquer estranho. As duas funcoes novas usam is_admin() OR
-- current_user = 'service_role' por isso — current_user reflete o
-- papel real da conexao (PostgREST troca de role conforme a chave),
-- nao depende de claim nenhuma.
-- =====================================================================

set search_path = gestao, public;

alter table jantares add column if not exists mensagem text;
alter table jantares add column if not exists logo_storage_path text;
alter table jantares add column if not exists sympla_status text not null default 'pendente'
  check (sympla_status in ('pendente','criado','convites_enviados'));
alter table jantares add column if not exists sympla_criado_em timestamptz;

comment on column jantares.sympla_status is
  'pendente = ainda nao criado no Sympla. criado = evento ja existe la (sympla_url preenchido), falta so mandar convite. convites_enviados = o robo ja importou/mandou os convidados confirmados para esse evento.';

-- ---------------------------------------------------------------------
-- 1. bucket de logo do jantar (so staff — nao e' area de patrocinador)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit)
values ('jantar-uploads', 'jantar-uploads', false, 20971520) -- 20MB, so logo
on conflict (id) do nothing;

drop policy if exists "jantar_uploads_staff_gerencia" on storage.objects;
create policy "jantar_uploads_staff_gerencia" on storage.objects
  for all to authenticated
  using (bucket_id = 'jantar-uploads' and is_staff())
  with check (bucket_id = 'jantar-uploads' and is_staff());

-- ---------------------------------------------------------------------
-- 2. jantar_salvar ganha mensagem (mesma mudanca de assinatura de
--    sempre: DROP antes, senao vira uma segunda funcao ao lado)
-- ---------------------------------------------------------------------
drop function if exists jantar_salvar(
  text,uuid,date,time without time zone,text,text,text,text,text,integer,text,text);

create or replace function jantar_salvar(
  p_patrocinador_nome text,
  p_id uuid DEFAULT NULL::uuid,
  p_data date DEFAULT NULL::date,
  p_horario time without time zone DEFAULT NULL::time without time zone,
  p_local text DEFAULT NULL::text,
  p_patrocinador_site text DEFAULT NULL::text,
  p_perfil_convidado text DEFAULT NULL::text,
  p_observacoes text DEFAULT NULL::text,
  p_abrangencia text DEFAULT NULL::text,
  p_capacidade integer DEFAULT 8,
  p_status text DEFAULT 'planejado'::text,
  p_sympla_url text DEFAULT NULL::text,
  p_mensagem text DEFAULT NULL::text
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
    select count(*) into v_ja from jantar_convidados
     where jantar_id = p_id and status in ('confirmado','compareceu');
    if coalesce(p_capacidade,8) < v_ja then
      raise exception 'Já há % confirmado(s); a capacidade não pode ser menor que isso', v_ja
        using errcode='22023';
    end if;

    -- link preenchido na mao (fora do robo) tambem conta como "criado" —
    -- e' assim que o fluxo funciona hoje, e ninguem deveria ficar
    -- "pendente" pra sempre so' porque colou o link direto aqui
    update jantares set
      data = p_data, horario = p_horario, local = p_local,
      patrocinador_nome = trim(p_patrocinador_nome),
      patrocinador_site = p_patrocinador_site,
      perfil_convidado = p_perfil_convidado,
      observacoes = p_observacoes, abrangencia = p_abrangencia,
      capacidade = coalesce(p_capacidade,8), status = p_status,
      sympla_url = nullif(trim(p_sympla_url),''),
      mensagem = p_mensagem,
      sympla_status = case
        when nullif(trim(p_sympla_url),'') is not null and sympla_status = 'pendente'
          then 'criado' else sympla_status end,
      sympla_criado_em = case
        when nullif(trim(p_sympla_url),'') is not null and sympla_status = 'pendente'
          then now() else sympla_criado_em end
    where id = p_id
    returning id into v_id;
  else
    insert into jantares (data, horario, local, patrocinador_nome,
                          patrocinador_site, perfil_convidado, observacoes,
                          abrangencia, capacidade, status, sympla_url, mensagem, criado_por)
    values (p_data, p_horario, p_local, trim(p_patrocinador_nome),
            p_patrocinador_site, p_perfil_convidado, p_observacoes,
            p_abrangencia, coalesce(p_capacidade,8), p_status,
            nullif(trim(p_sympla_url),''), p_mensagem, auth.jwt() ->> 'email')
    returning id into v_id;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

revoke execute on function jantar_salvar(text,uuid,date,time without time zone,text,text,text,text,text,integer,text,text,text) from public, anon;
grant execute on function jantar_salvar(text,uuid,date,time without time zone,text,text,text,text,text,integer,text,text,text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3. jantar_obter e jantar_listar ganham os campos novos (mudam o
--    formato de retorno, entao tambem exigem DROP)
-- ---------------------------------------------------------------------
drop function if exists jantar_obter(uuid);

create function jantar_obter(p_id uuid) returns table(
  id uuid, data date, horario time without time zone, local text,
  patrocinador_nome text, patrocinador_site text, perfil_convidado text,
  observacoes text, abrangencia text, capacidade integer, status text,
  sympla_url text, mensagem text, logo_storage_path text,
  sympla_status text, sympla_criado_em timestamptz
) language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select j.id, j.data, j.horario, j.local, j.patrocinador_nome,
           j.patrocinador_site, j.perfil_convidado, j.observacoes,
           j.abrangencia, j.capacidade, j.status, j.sympla_url,
           j.mensagem, j.logo_storage_path, j.sympla_status, j.sympla_criado_em
    from jantares j where j.id = p_id;
end;
$$;

revoke execute on function jantar_obter(uuid) from public, anon;
grant execute on function jantar_obter(uuid) to authenticated, service_role;

drop function if exists jantar_listar(text);

create function jantar_listar(p_status text DEFAULT NULL::text) returns table(
  id uuid, data date, horario time without time zone, local text,
  patrocinador text, capacidade integer, status text,
  confirmados bigint, compareceram bigint, sympla_status text
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
             where c.jantar_id = j.id and c.status = 'compareceu'),
           j.sympla_status
    from jantares j
    where p_status is null or j.status = p_status
    order by j.data desc nulls last, j.created_at desc;
end;
$$;

revoke execute on function jantar_listar(text) from public, anon;
grant execute on function jantar_listar(text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 4. registra a logo, depois do upload no storage feito pelo front
-- ---------------------------------------------------------------------
create or replace function jantar_definir_logo(p_id uuid, p_storage_path text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
begin
  perform _exige_admin();
  update jantares set logo_storage_path = nullif(trim(p_storage_path),'') where id = p_id;
  if not found then
    raise exception 'Jantar nao encontrado' using errcode='P0002';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function jantar_definir_logo(uuid,text) from public, anon;
grant execute on function jantar_definir_logo(uuid,text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 5. fila para o robo, e o jeito dele confirmar de volta.
--
-- Um jantar entra na fila de CRIACAO quando tem logo + mensagem + data
-- (o minimo pra montar a pagina de inscricao) e ainda esta pendente.
-- Depois de criado, some da fila de criacao e passa a aparecer so' pra
-- quem for mandar convite (usa jantar_convidados separadamente, ja
-- exposto por jantar_convidados_listar).
-- ---------------------------------------------------------------------
create or replace function jantar_listar_para_sympla()
returns table (
  id uuid, patrocinador_nome text, data date, horario time without time zone,
  local text, capacidade integer, mensagem text, logo_storage_path text,
  sympla_status text, sympla_url text
) language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  if not (is_admin() or current_user = 'service_role') then
    raise exception 'Acesso restrito a administradores' using errcode = '42501';
  end if;

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

revoke execute on function jantar_listar_para_sympla() from public, anon;
grant execute on function jantar_listar_para_sympla() to authenticated, service_role;

create or replace function jantar_marcar_sympla(p_id uuid, p_sympla_url text, p_status text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
begin
  if not (is_admin() or current_user = 'service_role') then
    raise exception 'Acesso restrito a administradores' using errcode = '42501';
  end if;

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

revoke execute on function jantar_marcar_sympla(uuid,text,text) from public, anon;
grant execute on function jantar_marcar_sympla(uuid,text,text) to authenticated, service_role;
