-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Bloco 5.3 — pre-cadastro de patrocinador por link.
--
-- MODELO
--
-- O organizador gera um link com token para UM prospect especifico
-- (nao e formulario aberto ao publico em geral) — mesmo espirito de
-- convite curado que o resto do sistema ja usa (indicacao de CIO,
-- convite de jantar). O prospect preenche os PROPRIOS dados nesse
-- link; nada entra no cadastro de verdade sem o organizador aprovar.
--
-- Os campos sao os MESMOS do cadastro manual em admin.html (aba
-- Patrocinadores) — unifica os dois, como pedido: nao existe um
-- segundo formulario com campos diferentes.
--
-- pre_cadastros.status: aberto (link gerado, ninguem preencheu ainda)
-- -> enviado (prospect submeteu, aguardando decisao) -> aprovado
-- (virou patrocinador de verdade) ou reprovado (com motivo).
-- =====================================================================

set search_path = gestao, public;

create table if not exists pre_cadastros (
  id uuid primary key default gen_random_uuid(),
  evento_id uuid not null references eventos(id) on delete cascade,
  token text not null unique,
  status text not null default 'aberto' check (status in ('aberto','enviado','aprovado','reprovado')),

  -- mesmos campos do cadastro manual (admin_salvar_patrocinador)
  empresa text, cnpj text, segmento text, o_que_vende text,
  site text, resumo text, cidade text, estado text, natureza text,

  -- quem preencheu, pra organizacao conseguir responder
  nome_contato text, email_contato text, telefone_contato text,

  motivo_reprovacao text,
  patrocinador_id uuid references patrocinadores(id),

  criado_em timestamptz not null default now(),
  criado_por text,
  enviado_em timestamptz,
  decidido_em timestamptz,
  decidido_por text
);

alter table pre_cadastros enable row level security;
create policy pre_cadastros_staff_all on pre_cadastros
  for all to authenticated using (is_staff()) with check (is_staff());
revoke all on table pre_cadastros from anon, authenticated;

create index if not exists pre_cadastros_evento_status_idx on pre_cadastros(evento_id, status);

-- ---------------------------------------------------------------------
-- 1. ORGANIZADOR GERA O LINK
-- ---------------------------------------------------------------------
create or replace function admin_criar_convite_pre_cadastro(p_evento_slug text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_evento uuid; v_id uuid; v_token text;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode = 'P0002';
  end if;

  v_token := encode(gen_random_bytes(16), 'hex');

  insert into pre_cadastros (evento_id, token, criado_por)
  values (v_evento, v_token, auth.jwt() ->> 'email')
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id, 'token', v_token);
end;
$$;

revoke execute on function admin_criar_convite_pre_cadastro(text) from public, anon;
grant execute on function admin_criar_convite_pre_cadastro(text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2. O PROSPECT ABRE O LINK — sem login, so o token protege
-- ---------------------------------------------------------------------
create or replace function pre_cadastro_obter(p_token text)
returns jsonb language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_row pre_cadastros%rowtype; v_evento_nome text;
begin
  select * into v_row from pre_cadastros where token = p_token;
  if v_row.id is null then
    return jsonb_build_object('ok', false, 'motivo', 'nao_encontrado');
  end if;

  select nome into v_evento_nome from eventos where id = v_row.evento_id;

  return jsonb_build_object(
    'ok', true, 'status', v_row.status, 'evento_nome', v_evento_nome,
    'empresa', v_row.empresa, 'cnpj', v_row.cnpj, 'segmento', v_row.segmento,
    'o_que_vende', v_row.o_que_vende, 'site', v_row.site, 'resumo', v_row.resumo,
    'cidade', v_row.cidade, 'estado', v_row.estado, 'natureza', v_row.natureza,
    'nome_contato', v_row.nome_contato, 'email_contato', v_row.email_contato,
    'telefone_contato', v_row.telefone_contato,
    'motivo_reprovacao', v_row.motivo_reprovacao
  );
end;
$$;

revoke execute on function pre_cadastro_obter(text) from public;
grant execute on function pre_cadastro_obter(text) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3. O PROSPECT ENVIA — pode reenviar e corrigir enquanto nao foi
-- decidido (aberto ou enviado); depois de aprovado/reprovado, o link
-- fica so-leitura (reprovado mostra o motivo; pedir de novo e' o
-- organizador gerar outro convite)
-- ---------------------------------------------------------------------
create or replace function pre_cadastro_enviar(
  p_token text, p_empresa text,
  p_cnpj text DEFAULT NULL::text, p_segmento text DEFAULT NULL::text,
  p_o_que_vende text DEFAULT NULL::text, p_site text DEFAULT NULL::text,
  p_resumo text DEFAULT NULL::text, p_cidade text DEFAULT NULL::text,
  p_estado text DEFAULT NULL::text, p_natureza text DEFAULT NULL::text,
  p_nome_contato text DEFAULT NULL::text, p_email_contato text DEFAULT NULL::text,
  p_telefone_contato text DEFAULT NULL::text
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_id uuid; v_status text;
begin
  select id, status into v_id, v_status from pre_cadastros where token = p_token;
  if v_id is null then
    raise exception 'Convite nao encontrado' using errcode = 'P0002';
  end if;
  if v_status not in ('aberto','enviado') then
    raise exception 'Este convite ja foi % — fale com a organizacao', v_status
      using errcode = '55000';
  end if;
  if coalesce(trim(p_empresa),'') = '' then
    raise exception 'Informe o nome da empresa' using errcode = '22023';
  end if;
  if coalesce(trim(p_nome_contato),'') = '' or coalesce(trim(p_email_contato),'') = '' then
    raise exception 'Informe nome e e-mail de contato' using errcode = '22023';
  end if;
  if p_natureza is not null and p_natureza not in ('privada','hibrida','publica') then
    raise exception 'Natureza invalida: %', p_natureza using errcode = '22023';
  end if;

  update pre_cadastros set
    empresa = trim(p_empresa), cnpj = p_cnpj, segmento = p_segmento,
    o_que_vende = p_o_que_vende, site = p_site, resumo = p_resumo,
    cidade = p_cidade, estado = p_estado, natureza = p_natureza,
    nome_contato = trim(p_nome_contato),
    email_contato = lower(trim(p_email_contato)),
    telefone_contato = p_telefone_contato,
    status = 'enviado',
    enviado_em = now()
  where id = v_id;

  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function pre_cadastro_enviar(text,text,text,text,text,text,text,text,text,text,text,text,text) from public;
grant execute on function pre_cadastro_enviar(text,text,text,text,text,text,text,text,text,text,text,text,text) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 4. ORGANIZADOR REVISA
-- ---------------------------------------------------------------------
create or replace function admin_listar_pre_cadastros(p_evento_slug text, p_status text DEFAULT NULL::text)
returns table (
  id uuid, token text, status text, empresa text, cnpj text, segmento text,
  o_que_vende text, site text, resumo text, cidade text, estado text, natureza text,
  nome_contato text, email_contato text, telefone_contato text,
  motivo_reprovacao text, criado_em timestamptz, enviado_em timestamptz
)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select pc.id, pc.token, pc.status, pc.empresa, pc.cnpj, pc.segmento,
           pc.o_que_vende, pc.site, pc.resumo, pc.cidade, pc.estado, pc.natureza,
           pc.nome_contato, pc.email_contato, pc.telefone_contato,
           pc.motivo_reprovacao, pc.criado_em, pc.enviado_em
    from pre_cadastros pc
    join eventos e on e.id = pc.evento_id and e.slug = p_evento_slug
    where p_status is null or pc.status = p_status
    order by pc.criado_em desc;
end;
$$;

revoke execute on function admin_listar_pre_cadastros(text,text) from public, anon;
grant execute on function admin_listar_pre_cadastros(text,text) to authenticated, service_role;

create or replace function admin_aprovar_pre_cadastro(p_id uuid)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_row pre_cadastros%rowtype; v_evento_slug text; v_patro jsonb; v_patro_id uuid;
begin
  perform _exige_admin();

  select * into v_row from pre_cadastros where id = p_id;
  if v_row.id is null then
    raise exception 'Pre-cadastro nao encontrado' using errcode = 'P0002';
  end if;
  if v_row.status <> 'enviado' then
    raise exception 'So da pra aprovar quem esta com status "enviado" (atual: %)', v_row.status
      using errcode = '55000';
  end if;

  select slug into v_evento_slug from eventos where id = v_row.evento_id;

  v_patro := admin_salvar_patrocinador(
    v_evento_slug, v_row.empresa, null, v_row.cnpj, v_row.segmento,
    v_row.o_que_vende, 0, null, 'ativo', v_row.site, v_row.resumo,
    v_row.natureza, v_row.cidade, v_row.estado, null);
  v_patro_id := (v_patro ->> 'id')::uuid;

  update pre_cadastros set
    status = 'aprovado', patrocinador_id = v_patro_id,
    decidido_em = now(), decidido_por = auth.jwt() ->> 'email'
  where id = p_id;

  return jsonb_build_object('ok', true, 'patrocinador_id', v_patro_id);
end;
$$;

revoke execute on function admin_aprovar_pre_cadastro(uuid) from public, anon;
grant execute on function admin_aprovar_pre_cadastro(uuid) to authenticated, service_role;

create or replace function admin_reprovar_pre_cadastro(p_id uuid, p_motivo text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
begin
  perform _exige_admin();

  if coalesce(trim(p_motivo),'') = '' then
    raise exception 'Informe o motivo da reprovacao' using errcode = '22023';
  end if;

  update pre_cadastros set
    status = 'reprovado', motivo_reprovacao = p_motivo,
    decidido_em = now(), decidido_por = auth.jwt() ->> 'email'
  where id = p_id and status = 'enviado';

  if not found then
    raise exception 'Pre-cadastro nao encontrado ou nao esta com status "enviado"' using errcode = 'P0002';
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function admin_reprovar_pre_cadastro(uuid,text) from public, anon;
grant execute on function admin_reprovar_pre_cadastro(uuid,text) to authenticated, service_role;

create or replace function admin_remover_convite_pre_cadastro(p_id uuid)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
begin
  perform _exige_admin();
  delete from pre_cadastros where id = p_id and status in ('aberto','enviado');
  if not found then
    raise exception 'So da pra remover convite ainda nao decidido' using errcode = 'P0002';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function admin_remover_convite_pre_cadastro(uuid) from public, anon;
grant execute on function admin_remover_convite_pre_cadastro(uuid) to authenticated, service_role;
