-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Modulo de grupos de WhatsApp por jantar — Fase 2 (Fase 1 foi so
-- levantamento e proposta, aprovada em texto).
--
-- DESENHO (nao mexer sem reabrir a decisao com o organizador):
--
--   Numero 1, oficial (Cloud API da Meta) — unico que manda mensagem.
--   Ja tem toda a infraestrutura pronta desde o Bloco 5.8: fila
--   `notificacoes` com canal='whatsapp', Edge Function `enviar-whatsapp`
--   ja envia de verdade contra a Cloud API quando WHATSAPP_TOKEN/
--   WHATSAPP_PHONE_NUMBER_ID existirem. Esta migration so acrescenta
--   dois `tipo` novos de notificacao — nao mexe na fila em si.
--
--   Numero 2, operacional (Baileys, fora deste banco) — so cria o
--   grupo, vira admin, gera o link. NUNCA manda mensagem, NUNCA
--   adiciona ninguem por automacao — ingresso e sempre por link, via
--   numero 1. O daemon Node fica em gestao/whatsapp_operacional/.
--
-- FLUXO: organizador clica "Criar grupo" em jantares.html (so aparece
-- com >=1 convidado confirmado) -> jantar_grupo_solicitar grava
-- status='sincronizando_contatos' -> daemon Node poll'a essa tabela,
-- sincroniza contato no Google, cria o grupo vazio, grava o link
-- (jantar_grupo_daemon_avancar) -> enfileira jantar_link_grupo pra
-- cada confirmado (jantar_grupo_enfileirar_convites) -> enviar-whatsapp
-- (ja existente) entrega de verdade.
--
-- A confirmacao de inscricao (o AVISO de que o grupo vai ser criado) e
-- enfileirada na hora que o convidado vira 'confirmado', nao quando o
-- grupo e criado — por isso o hook fica em jantar_marcar_convidado e em
-- jantar_importar_convidados_sympla, nao aqui.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. Telefone normalizado — mesmo molde de norm_cpf/norm_doc
-- ---------------------------------------------------------------------

-- Trata 8 e 9 digitos (celular BR ganhou o 9 na frente em 2016; fixo
-- continua com 8) e DDD, sempre com o 55 do Brasil na frente. Numero
-- que nao bate em nenhum formato reconhecivel vira null em vez de
-- adivinhar — E.164 errado manda mensagem pro numero errado.
create or replace function norm_telefone_e164(v text) returns text
language sql immutable as $$
  select case
    when length(d) = 10 then '55' || substring(d,1,2) || '9' || substring(d,3)  -- DDD + 8 digitos, sem o 9
    when length(d) = 11 then '55' || d                                          -- DDD + 9 digitos
    when length(d) = 12 and left(d,2) = '55' then d                             -- ja tem 55 + 8 digitos
    when length(d) = 13 and left(d,2) = '55' then d                             -- ja tem 55 + 9 digitos
    else null
  end
  from (select regexp_replace(coalesce(v,''), '\D', '', 'g') as d) x;
$$;

alter table gestores add column if not exists telefone_e164 text
  generated always as (norm_telefone_e164(telefone)) stored;

comment on column gestores.telefone_e164 is
  'Telefone normalizado em E.164 (+55...), derivado de telefone. Null quando telefone nao bate em nenhum formato BR reconhecido.';

-- ---------------------------------------------------------------------
-- 2. Pipeline do grupo — 1:1 com jantar
-- ---------------------------------------------------------------------

create table if not exists jantar_grupos (
  id uuid primary key default gen_random_uuid(),
  jantar_id uuid not null unique references jantares(id),
  status text not null
    check (status in ('sincronizando_contatos','criando_grupo','criado','erro')),
  whatsapp_group_jid text,   -- ex: 1234567890-1234567890@g.us
  invite_link text,
  solicitado_por text,
  solicitado_em timestamptz,
  criado_em timestamptz,
  erro text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table jantar_grupos enable row level security;
-- sem policy de proposito: nenhum papel le tabela direto neste schema,
-- so via jantar_grupo_obter/_solicitar (SECURITY DEFINER). Mesmo padrao
-- de segmentos (deny-by-default, acesso so por funcao).

-- ---------------------------------------------------------------------
-- 3. Status de sincronizacao de contato — por convidado
-- ---------------------------------------------------------------------

alter table jantar_convidados add column if not exists
  contato_google_resource_name text;
alter table jantar_convidados add column if not exists
  contato_sincronizado_em timestamptz;

comment on column jantar_convidados.contato_google_resource_name is
  'resourceName do People API. Presente = contato ja existe/foi sincronizado na agenda Google — usado pra so criar os ausentes.';

-- ---------------------------------------------------------------------
-- 4. Log de toda acao do numero operacional
-- ---------------------------------------------------------------------

create table if not exists whatsapp_operacional_log (
  id uuid primary key default gen_random_uuid(),
  jantar_id uuid references jantares(id),   -- null pra evento de sessao (conectou/desconectou), sem jantar associado
  acao text not null,
  detalhe jsonb,
  created_at timestamptz not null default now()
);

alter table whatsapp_operacional_log enable row level security;
-- mesmo motivo de jantar_grupos: acesso so por funcao.

create index if not exists whatsapp_operacional_log_jantar_ix
  on whatsapp_operacional_log(jantar_id, created_at desc);

-- ---------------------------------------------------------------------
-- 5. Helper interno: enfileira a confirmacao de inscricao (numero 1,
--    Cloud API) — chamado so na TRANSICAO pra 'confirmado', nunca a
--    cada UPDATE (senao reconfirmar/reimportar manda de novo).
--    Sem _exige_*() porque e interna: so chamada de dentro de outra
--    SECURITY DEFINER do schema, nunca exposta direto (sem GRANT).
-- ---------------------------------------------------------------------

create or replace function _jantar_enfileirar_whatsapp_confirmacao(p_jantar_convidado_id uuid)
returns void language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_tel text; v_nome text; v_patro text; v_data date;
begin
  select g.telefone_e164, g.nome, j.patrocinador_nome, j.data
    into v_tel, v_nome, v_patro, v_data
    from jantar_convidados jc
    join gestores g on g.id = jc.gestor_id
    join jantares j on j.id = jc.jantar_id
   where jc.id = p_jantar_convidado_id;

  -- sem telefone reconhecivel, nao tem pra onde mandar — quem cadastrou
  -- ve isso faltando no proprio cadastro do gestor, nao e erro daqui
  if v_tel is null then
    return;
  end if;

  insert into notificacoes (destinatario, tipo, canal, template_nome, template_params, sujeito_id)
  values (
    v_tel, 'jantar_confirmacao_inscricao', 'whatsapp',
    -- [PREENCHER] nome exato do template aprovado no Meta Business Manager
    'cio_cerrado_confirmacao_jantar',
    jsonb_build_array(v_nome, coalesce(v_patro, 'o jantar'), to_char(v_data, 'DD/MM')),
    p_jantar_convidado_id
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Hooks: jantar_marcar_convidado e jantar_importar_convidados_sympla
--    ganham o enfileiramento na transicao pra 'confirmado'. Resto do
--    corpo identico ao que ja existia (ver 20260909130000 e
--    20260829090000) — so a linha do hook e nova.
-- ---------------------------------------------------------------------

create or replace function jantar_marcar_convidado(p_id uuid, p_status text, p_observacao text DEFAULT NULL::text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_jantar uuid; v_cap int; v_ocupados int; v_status_anterior text;
begin
  perform _exige_staff();

  if p_status not in ('sugerido','convidado','em_analise','confirmado','recusado','compareceu') then
    raise exception 'Status invalido: %', p_status using errcode='22023';
  end if;

  select jc.jantar_id, jc.status into v_jantar, v_status_anterior
    from jantar_convidados jc where jc.id = p_id;
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

  if p_status = 'confirmado' and v_status_anterior is distinct from 'confirmado' then
    perform _jantar_enfileirar_whatsapp_confirmacao(p_id);
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function jantar_importar_convidados_sympla(
  p_jantar_id uuid, p_linhas jsonb
) returns jsonb
    language plpgsql security definer
    set search_path to 'gestao', 'public'
    as $$
declare
  v_cap int;
  v_item jsonb;
  v_email text; v_nome text; v_pgto text;
  v_gestor uuid; v_linha int := 0;
  v_criados int := 0; v_atualizados int := 0; v_recusados int := 0; v_erros int := 0;
  v_gestores_novos int := 0;
  v_erros_det jsonb := '[]'::jsonb;
  v_imp uuid;
  v_existia boolean; v_status_atual text; v_jc_id uuid;
begin
  perform _exige_admin();

  select capacidade into v_cap from jantares where id = p_jantar_id;
  if v_cap is null then
    raise exception 'Jantar nao encontrado' using errcode='P0002';
  end if;

  insert into importacoes (tipo, total_linhas, executado_por)
  values ('jantar_convidados_sympla',
          jsonb_array_length(coalesce(p_linhas,'[]'::jsonb)),
          auth.jwt() ->> 'email')
  returning id into v_imp;

  for v_item in select * from jsonb_array_elements(coalesce(p_linhas,'[]'::jsonb))
  loop
    v_linha := v_linha + 1;

    v_nome := nullif(trim(coalesce(v_item ->> 'nome','')), '');
    v_email := nullif(lower(trim(coalesce(
                 nullif(trim(coalesce(v_item ->> 'email_corporativo','')),''),
                 v_item ->> 'email'))), '');
    v_pgto  := lower(trim(coalesce(v_item ->> 'estado_pagamento','')));

    if v_nome is null then
      v_erros := v_erros + 1;
      v_erros_det := v_erros_det || jsonb_build_object('linha', v_linha, 'motivo', 'linha sem nome');
      continue;
    end if;

    if v_email is null then
      v_erros := v_erros + 1;
      v_erros_det := v_erros_det || jsonb_build_object('linha', v_linha, 'motivo', 'sem e-mail', 'nome', v_nome);
      continue;
    end if;

    if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
      v_erros := v_erros + 1;
      v_erros_det := v_erros_det || jsonb_build_object(
        'linha', v_linha, 'motivo', 'e-mail invalido: ' || v_email, 'nome', v_nome);
      continue;
    end if;

    select g.id into v_gestor from gestores g where g.email_norm = norm_doc(v_email);

    if v_gestor is null then
      insert into gestores (nome, email, empresa, cargo, telefone, cnpj, cpf, origem)
      values (v_nome, v_email,
              nullif(trim(regexp_replace(coalesce(v_item ->> 'empresa',''), '^\d+\s*-\s*', '')), ''),
              nullif(trim(coalesce(v_item ->> 'cargo','')), ''),
              nullif(trim(coalesce(v_item ->> 'telefone','')), ''),
              nullif(trim(coalesce(v_item ->> 'cnpj','')), ''),
              nullif(trim(coalesce(v_item ->> 'cpf','')), ''),
              'importacao')
      returning id into v_gestor;
      v_gestores_novos := v_gestores_novos + 1;
    else
      update gestores set
        empresa  = coalesce(empresa,  nullif(trim(regexp_replace(coalesce(v_item ->> 'empresa',''), '^\d+\s*-\s*', '')), '')),
        cargo    = coalesce(cargo,    nullif(trim(coalesce(v_item ->> 'cargo','')), '')),
        telefone = coalesce(telefone, nullif(trim(coalesce(v_item ->> 'telefone','')), '')),
        cnpj     = coalesce(cnpj,     nullif(trim(coalesce(v_item ->> 'cnpj','')), '')),
        cpf      = coalesce(cpf,      nullif(trim(coalesce(v_item ->> 'cpf','')), ''))
      where id = v_gestor;
    end if;

    select exists(select 1 from jantar_convidados where jantar_id = p_jantar_id and gestor_id = v_gestor),
           status
      into v_existia, v_status_atual
      from jantar_convidados where jantar_id = p_jantar_id and gestor_id = v_gestor;

    if v_pgto = 'cancelado' then
      -- nao cria ninguem por cancelamento; so rebaixa quem ja estava,
      -- e nunca por cima de quem ja compareceu (fato mais forte)
      if v_existia and v_status_atual <> 'compareceu' then
        update jantar_convidados set status = 'recusado', sympla_id = coalesce(
             nullif(trim(coalesce(v_item ->> 'sympla_id','')), ''), sympla_id)
         where jantar_id = p_jantar_id and gestor_id = v_gestor;
        v_recusados := v_recusados + 1;
      end if;
      continue;
    end if;

    if v_pgto <> 'aprovado' then
      v_erros := v_erros + 1;
      v_erros_det := v_erros_det || jsonb_build_object(
        'linha', v_linha, 'nome', v_nome,
        'motivo', 'estado de pagamento nao reconhecido: ' ||
                  coalesce(nullif(v_pgto,''),'(vazio)'));
      continue;
    end if;

    if v_existia and v_status_atual = 'compareceu' then
      -- ja chegou no jantar; so atualiza o rastro do sympla_id, status fica
      update jantar_convidados set
        sympla_id = coalesce(nullif(trim(coalesce(v_item ->> 'sympla_id','')), ''), sympla_id)
      where jantar_id = p_jantar_id and gestor_id = v_gestor;
      v_atualizados := v_atualizados + 1;
      continue;
    end if;

    insert into jantar_convidados (jantar_id, gestor_id, empresa, origem, status, sympla_id)
    select p_jantar_id, v_gestor, g.empresa, 'sympla', 'confirmado',
           nullif(trim(coalesce(v_item ->> 'sympla_id','')), '')
      from gestores g where g.id = v_gestor
    on conflict (jantar_id, gestor_id) do update set
      status    = 'confirmado',
      sympla_id = coalesce(excluded.sympla_id, jantar_convidados.sympla_id)
    returning id into v_jc_id;

    -- so enfileira quando a linha REALMENTE entrou confirmada agora —
    -- v_existia+status ja lido antes do upsert acima, mesmo raciocinio
    -- do guard em jantar_marcar_convidado
    if not (v_existia and v_status_atual = 'confirmado') then
      perform _jantar_enfileirar_whatsapp_confirmacao(v_jc_id);
    end if;

    if v_existia then v_atualizados := v_atualizados + 1;
    else                 v_criados := v_criados + 1;
    end if;
  end loop;

  update importacoes set criados = v_criados, atualizados = v_atualizados,
                         erros = v_erros
   where id = v_imp;

  return jsonb_build_object(
    'ok', true,
    'criados', v_criados,
    'atualizados', v_atualizados,
    'recusados', v_recusados,
    'gestores_novos', v_gestores_novos,
    'erros', v_erros,
    'detalhe_erros', v_erros_det,
    'capacidade', v_cap,
    'ocupados_agora', (select count(*) from jantar_convidados
                        where jantar_id = p_jantar_id and status in ('confirmado','compareceu')));
end;
$$;

-- ---------------------------------------------------------------------
-- 7. RPCs do organizador (jantares.html)
-- ---------------------------------------------------------------------

create or replace function jantar_grupo_obter(p_jantar_id uuid)
returns table(
  status text, invite_link text, erro text,
  solicitado_em timestamptz, criado_em timestamptz, confirmados integer
) language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select g.status, g.invite_link, g.erro, g.solicitado_em, g.criado_em,
           (select count(*)::integer from jantar_convidados
             where jantar_id = p_jantar_id and status = 'confirmado')
      from jantar_grupos g where g.jantar_id = p_jantar_id
    union all
    select null::text, null::text, null::text, null::timestamptz, null::timestamptz,
           (select count(*)::integer from jantar_convidados
             where jantar_id = p_jantar_id and status = 'confirmado')
     where not exists (select 1 from jantar_grupos where jantar_id = p_jantar_id)
    limit 1;
end;
$$;

-- Acao com efeito externo real (cria grupo de WhatsApp de verdade) —
-- mesmo nivel de guarda de jantar_importar_convidados_sympla, nao o
-- nivel mais baixo de jantar_marcar_convidado.
create or replace function jantar_grupo_solicitar(p_jantar_id uuid)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_confirmados int; v_status_atual text;
begin
  perform _exige_admin();

  if not exists (select 1 from jantares where id = p_jantar_id) then
    raise exception 'Jantar nao encontrado' using errcode='P0002';
  end if;

  select count(*) into v_confirmados from jantar_convidados
   where jantar_id = p_jantar_id and status = 'confirmado';
  if v_confirmados = 0 then
    raise exception 'Nenhum convidado confirmado ainda — nada pra colocar no grupo' using errcode='22023';
  end if;

  select status into v_status_atual from jantar_grupos where jantar_id = p_jantar_id;
  if v_status_atual in ('sincronizando_contatos','criando_grupo') then
    raise exception 'Já tem uma criação em andamento pra este jantar' using errcode='22023';
  end if;
  if v_status_atual = 'criado' then
    raise exception 'O grupo deste jantar já foi criado' using errcode='22023';
  end if;

  insert into jantar_grupos (jantar_id, status, solicitado_por, solicitado_em, erro)
  values (p_jantar_id, 'sincronizando_contatos', auth.jwt() ->> 'email', now(), null)
  on conflict (jantar_id) do update set
    status = 'sincronizando_contatos', solicitado_por = excluded.solicitado_por,
    solicitado_em = excluded.solicitado_em, erro = null, updated_at = now();

  insert into whatsapp_operacional_log (jantar_id, acao, detalhe)
  values (p_jantar_id, 'solicitado', jsonb_build_object(
    'organizador', auth.jwt() ->> 'email', 'confirmados', v_confirmados));

  return jsonb_build_object('ok', true, 'confirmados', v_confirmados);
end;
$$;

-- ---------------------------------------------------------------------
-- 8. RPCs do daemon (gestao/whatsapp_operacional/, chave service_role —
--    is_admin()/is_staff() ja reconhecem service_role desde
--    20260909210000, entao _exige_admin() basta, mesmo padrao do resto
--    do schema)
-- ---------------------------------------------------------------------

create or replace function jantar_grupos_pendentes()
returns table(jantar_id uuid, status text, patrocinador_nome text, tentativa_em timestamptz)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_admin();
  return query
    select g.jantar_id, g.status, j.patrocinador_nome, g.updated_at
      from jantar_grupos g join jantares j on j.id = g.jantar_id
     where g.status in ('sincronizando_contatos','criando_grupo')
     order by g.solicitado_em;
end;
$$;

create or replace function jantar_grupo_convidados_para_sincronizar(p_jantar_id uuid)
returns table(jantar_convidado_id uuid, nome text, telefone_e164 text, ja_sincronizado boolean)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_admin();
  return query
    select jc.id, g.nome, g.telefone_e164, (jc.contato_sincronizado_em is not null)
      from jantar_convidados jc
      join gestores g on g.id = jc.gestor_id
     where jc.jantar_id = p_jantar_id and jc.status = 'confirmado';
end;
$$;

create or replace function jantar_convidado_marcar_contato_sincronizado(p_id uuid, p_resource_name text)
returns void language plpgsql security definer
set search_path = gestao, public as $$
begin
  perform _exige_admin();
  update jantar_convidados set
    contato_google_resource_name = p_resource_name,
    contato_sincronizado_em = now()
  where id = p_id;
end;
$$;

create or replace function jantar_grupo_daemon_avancar(
  p_jantar_id uuid, p_status text, p_group_jid text default null,
  p_invite_link text default null, p_erro text default null
) returns void language plpgsql security definer
set search_path = gestao, public as $$
begin
  perform _exige_admin();
  if p_status not in ('sincronizando_contatos','criando_grupo','criado','erro') then
    raise exception 'Status invalido: %', p_status using errcode='22023';
  end if;

  update jantar_grupos set
    status = p_status,
    whatsapp_group_jid = coalesce(p_group_jid, whatsapp_group_jid),
    invite_link = coalesce(p_invite_link, invite_link),
    erro = p_erro,
    criado_em = case when p_status = 'criado' then now() else criado_em end,
    updated_at = now()
  where jantar_id = p_jantar_id;
end;
$$;

create or replace function whatsapp_log_registrar(p_jantar_id uuid, p_acao text, p_detalhe jsonb default null)
returns void language plpgsql security definer
set search_path = gestao, public as $$
begin
  perform _exige_admin();
  insert into whatsapp_operacional_log (jantar_id, acao, detalhe)
  values (p_jantar_id, p_acao, p_detalhe);
end;
$$;

-- Enfileira a mensagem com o link do grupo (numero 1, Cloud API) pra
-- cada confirmado — chamada pelo daemon so depois do grupo criado.
create or replace function jantar_grupo_enfileirar_convites(p_jantar_id uuid)
returns integer language plpgsql security definer
set search_path = gestao, public as $$
declare v_link text; v_n int := 0; v_row record;
begin
  perform _exige_admin();

  select invite_link into v_link from jantar_grupos where jantar_id = p_jantar_id and status = 'criado';
  if v_link is null then
    raise exception 'Grupo deste jantar ainda nao foi criado' using errcode='22023';
  end if;

  for v_row in
    select g.telefone_e164 as tel, g.nome as nome, jc.id as jc_id
      from jantar_convidados jc join gestores g on g.id = jc.gestor_id
     where jc.jantar_id = p_jantar_id and jc.status = 'confirmado'
  loop
    if v_row.tel is null then continue; end if;

    insert into notificacoes (destinatario, tipo, canal, template_nome, template_params, sujeito_id)
    values (
      v_row.tel, 'jantar_link_grupo', 'whatsapp',
      -- [PREENCHER] nome exato do template aprovado no Meta Business Manager
      'cio_cerrado_link_grupo',
      jsonb_build_array(v_row.nome, v_link),
      v_row.jc_id
    );
    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Grants — mesmo padrao do resto do schema: nada pra public/anon,
--    authenticated + service_role em tudo que e RPC (a guarda de verdade
--    e o _exige_admin()/_exige_staff() dentro de cada funcao).
-- ---------------------------------------------------------------------

revoke all on function jantar_grupo_obter(uuid) from public, anon;
grant execute on function jantar_grupo_obter(uuid) to authenticated, service_role;

revoke all on function jantar_grupo_solicitar(uuid) from public, anon;
grant execute on function jantar_grupo_solicitar(uuid) to authenticated, service_role;

revoke all on function jantar_grupos_pendentes() from public, anon;
grant execute on function jantar_grupos_pendentes() to authenticated, service_role;

revoke all on function jantar_grupo_convidados_para_sincronizar(uuid) from public, anon;
grant execute on function jantar_grupo_convidados_para_sincronizar(uuid) to authenticated, service_role;

revoke all on function jantar_convidado_marcar_contato_sincronizado(uuid, text) from public, anon;
grant execute on function jantar_convidado_marcar_contato_sincronizado(uuid, text) to authenticated, service_role;

revoke all on function jantar_grupo_daemon_avancar(uuid, text, text, text, text) from public, anon;
grant execute on function jantar_grupo_daemon_avancar(uuid, text, text, text, text) to authenticated, service_role;

revoke all on function whatsapp_log_registrar(uuid, text, jsonb) from public, anon;
grant execute on function whatsapp_log_registrar(uuid, text, jsonb) to authenticated, service_role;

revoke all on function jantar_grupo_enfileirar_convites(uuid) from public, anon;
grant execute on function jantar_grupo_enfileirar_convites(uuid) to authenticated, service_role;

revoke all on function jantar_marcar_convidado(uuid, text, text) from public, anon;
grant execute on function jantar_marcar_convidado(uuid, text, text) to authenticated, service_role;

revoke all on function jantar_importar_convidados_sympla(uuid, jsonb) from public, anon;
grant execute on function jantar_importar_convidados_sympla(uuid, jsonb) to authenticated, service_role;

-- autoverificacao — mesmo padrao de 20260824120000_fecha_views_para_anon.sql:
-- confere o proprio invariante antes de considerar a migration aplicada.
do $$
declare v_expostas text;
begin
  select string_agg(p.proname, ', ' order by p.proname)
    into v_expostas
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    join pg_language l on l.oid = p.prolang
   where n.nspname = 'gestao'
     and l.lanname <> 'internal'
     and p.proname in (
       'jantar_grupo_obter','jantar_grupo_solicitar','jantar_grupos_pendentes',
       'jantar_grupo_convidados_para_sincronizar','jantar_convidado_marcar_contato_sincronizado',
       'jantar_grupo_daemon_avancar','whatsapp_log_registrar','jantar_grupo_enfileirar_convites'
     )
     and (has_function_privilege('anon', p.oid, 'execute')
          or has_function_privilege('public', p.oid, 'execute'));

  if v_expostas is not null then
    raise exception 'funcao de grupo de WhatsApp exposta a anon/public: %', v_expostas;
  end if;
end $$;
